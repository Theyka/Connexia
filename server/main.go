// Connexia sync server.
//
// Zero-knowledge design: the server only stores an encrypted blob per user
// plus an scrypt password hash used to verify logins. It never sees the
// snapshot plaintext; the client encrypts with a key derived from the
// user's password (PBKDF2).
//
// Drop-in replacement for the original Node.js server: same endpoints and
// the same environment variables, so an existing data directory keeps
// working (and is migrated to the database on first boot).
//
// Usage:
//   PORT=8047 ./syncserver
//
// Storage (see store.go):
//   - PostgreSQL when DATABASE_URL is set (PgBouncer works via the same URL)
//   - SQLite (<DATA_DIR>/sync.db) otherwise
//
// Legacy JSON data (<DATA_DIR>/users.json + blobs/) is imported into the
// database automatically on first boot.

package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/subtle"
	"crypto/tls"
	"encoding/base32"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/smtp"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/scrypt"
)

const (
	sessionTTL        = 30 * 24 * time.Hour // 30 days
	maxBodyBytes      = 16 * 1024 * 1024    // 16 MB
	blobLimitBytes    = 6 * 1024 * 1024     // 6 MB
	verifyCodeTTL     = 10 * time.Minute
	verifyResendDelay = time.Minute
	totpChallengeTTL  = 5 * time.Minute
	scryptN           = 16384 // matches Node's default scryptSync params
	scryptR           = 8
	scryptP           = 1
	scryptKeyLen      = 64

	// Per-IP rate limits (in-memory, fixed window).
	rateRegisterLimit  = 10               // account creations
	rateRegisterWindow = time.Hour
	rateLoginLimit     = 10               // password attempts
	rateLoginWindow    = time.Minute
	rateCodeLimit      = 10               // verify/2FA code checks
	rateCodeWindow     = time.Minute
	rateResendLimit    = 5                // resend-verification requests
	rateResendWindow   = time.Minute
	rateSyncLimit      = 120              // blob uploads
	rateSyncWindow     = time.Minute
	rateSweepThreshold = 10000            // sweep expired buckets when the map grows this big
)

var (
	port      = envInt("PORT", 8047)
	dataDir   = envStr("DATA_DIR", filepath.Join(".", "data"))
	smtpCfg   = smtpConfig()
	emailRe   = regexp.MustCompile(`^[^\s@]+@[^\s@]+\.[^\s@]+$`)
	usersFile string
	blobsDir  string
)

// ---------- SMTP configuration ----------

type smtpConfigT struct {
	host   string
	port   int
	secure bool
	user   string
	pass   string
	from   string
}

func smtpConfig() smtpConfigT {
	secure := envStr("SMTP_SECURE", "") == "true"
	port := envInt("SMTP_PORT", 587)
	if secure {
		port = 465
	}
	return smtpConfigT{
		host:   envStr("SMTP_HOST", ""),
		port:   port,
		secure: secure,
		user:   envStr("SMTP_USER", ""),
		pass:   envStr("SMTP_PASS", ""),
		from:   envStr("SMTP_FROM", "Connexia <noreply@connexia.local>"),
	}
}

func envStr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		var n int
		if _, err := fmt.Sscanf(v, "%d", &n); err == nil {
			return n
		}
	}
	return def
}

// ---------- Storage ----------

type verifyCode struct {
	Code      string `json:"code"`
	ExpiresAt string `json:"expiresAt"`
}

type totpPending struct {
	Secret    string `json:"secret"`
	CreatedAt string `json:"createdAt"`
}

type challenge struct {
	Token     string `json:"token"`
	ExpiresAt string `json:"expiresAt"`
}

type user struct {
	Email          string            `json:"email"`
	Salt           string            `json:"salt"`
	Hash           string            `json:"hash"`
	CreatedAt      string            `json:"createdAt"`
	EmailVerified  *bool             `json:"emailVerified"`
	VerifyCode     *verifyCode       `json:"verifyCode,omitempty"`
	LastVerifySent string            `json:"lastVerifySentAt,omitempty"`
	Sessions       map[string]string `json:"sessions"`
	TotpSecret     string            `json:"totpSecret,omitempty"`
	TotpPending    *totpPending      `json:"totpPending,omitempty"`
	Challenge      *challenge        `json:"challenge,omitempty"`
	IsAdmin        bool              `json:"isAdmin,omitempty"`
}

type blob struct {
	Revision  int     `json:"revision"`
	Blob      *string `json:"blob"`
	UpdatedAt *string `json:"updatedAt"`
}

type state struct {
	mu    sync.RWMutex
	users map[string]*user // id -> user
	blobs map[string]*blob // id -> blob
	// requireEmailVerification is a server-wide setting (default true)
	// controlling whether new registrations must verify their email.
	requireEmailVerification bool
}

var st = &state{users: map[string]*user{}, blobs: map[string]*blob{}}

func load() error {
	users, blobs, err := store.LoadAll()
	if err != nil {
		return err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	st.users = users
	st.blobs = blobs
	st.requireEmailVerification = true
	if v, ok, err := store.GetSetting("require_email_verification"); err == nil && ok && v == "false" {
		st.requireEmailVerification = false
	}
	if st.users == nil {
		st.users = map[string]*user{}
	}
	if st.blobs == nil {
		st.blobs = map[string]*blob{}
	}
	for id, account := range st.users {
		if account == nil {
			continue
		}
		// Accounts created before email verification existed are treated as
		// verified; only new registrations must verify.
		if account.EmailVerified == nil {
			v := true
			account.EmailVerified = &v
		}
		if account.Sessions == nil {
			account.Sessions = map[string]string{}
		}
		if st.blobs[id] == nil {
			st.blobs[id] = &blob{Revision: 0}
		}
	}
	return nil
}

func blobFile(id string) string {
	return filepath.Join(blobsDir, id+".json")
}

// persistUserID writes one user to the store. Callers must hold st.mu
// (write lock).
func persistUserID(id string) {
	if err := store.SaveUser(id, st.users[id]); err != nil {
		log.Printf("error saving user %s: %v", id, err)
	}
}

// persistUser resolves the id for an account already in the map.
func persistUser(account *user) {
	id := accountIDOf(account)
	if id == "" {
		log.Printf("error persisting user: account not found in map")
		return
	}
	persistUserID(id)
}

// persistBlobID writes one blob to the store. Callers must hold st.mu
// (write lock).
func persistBlobID(id string) {
	if err := store.SaveBlob(id, st.blobs[id]); err != nil {
		log.Printf("error saving blob %s: %v", id, err)
	}
}

// ---------- Crypto ----------

func scryptHash(password string, salt []byte) []byte {
	// Parameters match Node's crypto.scryptSync defaults, so hashes written
	// by the original Node server verify correctly (and vice versa).
	hash, err := scrypt.Key([]byte(password), salt, scryptN, scryptR, scryptP, scryptKeyLen)
	if err != nil {
		log.Printf("scrypt error: %v", err)
		return make([]byte, scryptKeyLen)
	}
	return hash
}

func newSalt() string {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		log.Printf("rand error: %v", err)
	}
	return hex.EncodeToString(buf)
}

func newUUID() string {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		log.Printf("rand error: %v", err)
	}
	buf[6] = (buf[6] & 0x0f) | 0x40 // version 4
	buf[8] = (buf[8] & 0x3f) | 0x80 // variant 10
	return fmt.Sprintf("%x-%x-%x-%x-%x", buf[0:4], buf[4:6], buf[6:8], buf[8:10], buf[10:16])
}

func randomHex(n int) string {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		log.Printf("rand error: %v", err)
	}
	return hex.EncodeToString(buf)
}

func nowISO() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
}

func parseISO(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}
	}
	return t
}

// ---------- TOTP (RFC 6238) ----------

func base32Decode(s string) ([]byte, error) {
	return base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(
		strings.ToUpper(strings.Map(func(r rune) rune {
			switch {
			case r >= 'A' && r <= 'Z':
				return r
			case r >= '2' && r <= '7':
				return r
			default:
				return -1
			}
		}, s)),
	)
}

func base32Encode(buf []byte) string {
	return base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(buf)
}

func totpAt(secretB32 string, timeSec int64) string {
	key, err := base32Decode(secretB32)
	if err != nil {
		return ""
	}
	counter := timeSec / 30
	var msg [8]byte
	for i := 7; i >= 0; i-- {
		msg[i] = byte(counter & 0xff)
		counter >>= 8
	}
	mac := hmac.New(sha1.New, key)
	mac.Write(msg[:])
	sum := mac.Sum(nil)
	offset := sum[len(sum)-1] & 0x0f
	code := ((int(sum[offset]) & 0x7f) << 24) |
		(int(sum[offset+1]) << 16) |
		(int(sum[offset+2]) << 8) |
		int(sum[offset+3])
	return fmt.Sprintf("%06d", code%1000000)
}

func verifyTotp(secretB32, code string) bool {
	now := time.Now().Unix()
	for i := int64(-1); i <= 1; i++ {
		if totpAt(secretB32, now+i*30) == code {
			return true
		}
	}
	return false
}

func newTotpSecret() string {
	buf := make([]byte, 20)
	if _, err := rand.Read(buf); err != nil {
		log.Printf("rand error: %v", err)
	}
	return base32Encode(buf)
}

func otpauthURL(email, secret string) string {
	return "otpauth://totp/Connexia:" + url.QueryEscape(email) +
		"?secret=" + secret + "&issuer=Connexia&digits=6&period=30"
}

// ---------- Email delivery ----------

// sendEmail delivers one plain-text message. Supports implicit TLS (465)
// and STARTTLS (587), authenticated with AUTH PLAIN when credentials are
// configured. Without SMTP_HOST it logs the would-be message to the console
// instead, which is handy for local testing.
func sendEmail(to, subject, text string) error {
	if smtpCfg.host == "" {
		log.Printf("[smtp] no SMTP_HOST configured; would email %s:", to)
		log.Printf("[smtp] subject: %s", subject)
		log.Printf("[smtp] body:\n%s", text)
		return nil
	}
	addr := fmt.Sprintf("%s:%d", smtpCfg.host, smtpCfg.port)

	var client *smtp.Client
	var err error
	if smtpCfg.secure {
		conn, cerr := tls.Dial("tcp", addr, &tls.Config{ServerName: smtpCfg.host})
		if cerr != nil {
			return cerr
		}
		client, err = smtp.NewClient(conn, smtpCfg.host)
	} else {
		client, err = smtp.Dial(addr)
	}
	if err != nil {
		return err
	}
	defer client.Close()

	if !smtpCfg.secure {
		if ok, _ := client.Extension("STARTTLS"); ok {
			if err := client.StartTLS(&tls.Config{ServerName: smtpCfg.host}); err != nil {
				return err
			}
		}
	}
	if smtpCfg.user != "" {
		auth := smtp.PlainAuth("", smtpCfg.user, smtpCfg.pass, smtpCfg.host)
		if err := client.Auth(auth); err != nil {
			return err
		}
	}
	// MAIL FROM must be a bare address; the optional display name
	// ("Connexia <noreply@...>") belongs only in the From header.
	if err := client.Mail(envelopeFrom(smtpCfg.from)); err != nil {
		return err
	}
	if err := client.Rcpt(to); err != nil {
		return err
	}
	w, err := client.Data()
	if err != nil {
		return err
	}
	body := "From: " + smtpCfg.from + "\r\n" +
		"To: " + to + "\r\n" +
		"Subject: " + subject + "\r\n" +
		"MIME-Version: 1.0\r\n" +
		"Content-Type: text/plain; charset=utf-8\r\n" +
		"Content-Transfer-Encoding: 8bit\r\n" +
		"\r\n" +
		text
	if _, err := w.Write([]byte(body)); err != nil {
		return err
	}
	return w.Close()
}

// envelopeFrom returns the bare email address from a From value that may
// include a display name, e.g. "Connexia <noreply@connexia.run>" ->
// "noreply@connexia.run". Used for the SMTP MAIL FROM command.
func envelopeFrom(from string) string {
	if i := strings.LastIndex(from, "<"); i >= 0 {
		if j := strings.Index(from[i:], ">"); j > 0 {
			return from[i+1 : i+j]
		}
	}
	return from
}

func sendVerificationEmail(email, code string) {
	err := sendEmail(email, "Your Connexia verification code",
		"Your Connexia verification code is: "+code+
			"\n\nEnter it in the app to verify your email. "+
			"The code expires in 10 minutes.\n\nIf you did not create a "+
			"Connexia account, you can ignore this email.")
	if err != nil {
		log.Printf("[smtp] %v", err)
	}
}

func newVerifyCode() verifyCode {
	buf := make([]byte, 3)
	if _, err := rand.Read(buf); err != nil {
		log.Printf("rand error: %v", err)
	}
	n := (int(buf[0])<<16 | int(buf[1])<<8 | int(buf[2])) % 1000000
	return verifyCode{Code: fmt.Sprintf("%06d", n), ExpiresAt: time.Now().Add(verifyCodeTTL).UTC().Format("2006-01-02T15:04:05.000Z")}
}

func verifyCodeValid(account *user, code string) bool {
	if account.VerifyCode == nil {
		return false
	}
	return account.VerifyCode.Code == code &&
		time.Now().Before(parseISO(account.VerifyCode.ExpiresAt))
}

func canResend(account *user) bool {
	if account.LastVerifySent == "" {
		return true
	}
	return time.Since(parseISO(account.LastVerifySent)) >= verifyResendDelay
}

// ---------- Sessions ----------

func issueSession(account *user) string {
	token := randomHex(32)
	expires := time.Now().Add(sessionTTL).UTC().Format("2006-01-02T15:04:05.000Z")
	account.Sessions[token] = expires
	// Keep the session map small.
	for t, e := range account.Sessions {
		if time.Now().After(parseISO(e)) {
			delete(account.Sessions, t)
		}
	}
	return token
}

// ---------- Rate limiting ----------

type rateBucket struct {
	count   int
	resetAt time.Time
}

type rateLimiter struct {
	mu      sync.Mutex
	buckets map[string]*rateBucket
}

func newRateLimiter() *rateLimiter {
	return &rateLimiter{buckets: map[string]*rateBucket{}}
}

// allow records one attempt from key and reports whether it is within the
// fixed window (limit attempts per window). Sweeps expired buckets once the
// map grows large to bound memory.
func (rl *rateLimiter) allow(key string, limit int, window time.Duration) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	now := time.Now()
	if len(rl.buckets) >= rateSweepThreshold {
		for k, b := range rl.buckets {
			if now.After(b.resetAt) {
				delete(rl.buckets, k)
			}
		}
	}
	b := rl.buckets[key]
	if b == nil || now.After(b.resetAt) {
		rl.buckets[key] = &rateBucket{count: 1, resetAt: now.Add(window)}
		return true
	}
	if b.count >= limit {
		return false
	}
	b.count++
	return true
}

// clientIP best-effort extracts the caller's IP, honoring X-Forwarded-For
// when the server sits behind a reverse proxy.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if i := strings.IndexByte(xff, ','); i >= 0 {
			return strings.TrimSpace(xff[:i])
		}
		return strings.TrimSpace(xff)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// withRateLimit wraps a handler with a per-IP fixed-window limit.
func withRateLimit(rl *rateLimiter, key string, limit int, window time.Duration, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !rl.allow(key+":"+clientIP(r), limit, window) {
			sendError(w, 429, "too many requests")
			return
		}
		h(w, r)
	}
}

// ---------- HTTP helpers ----------

func sendJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func sendError(w http.ResponseWriter, status int, message string) {
	sendJSON(w, status, map[string]string{"error": message})
}

func readJSON(w http.ResponseWriter, r *http.Request, out any) bool {
	if r.ContentLength > maxBodyBytes {
		sendError(w, 400, "invalid body")
		return false
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	if err := dec.Decode(out); err != nil {
		sendError(w, 400, "invalid JSON")
		return false
	}
	return true
}

// auth extracts the bearer-token session and returns the account id, or ""
// when no session is valid.
func auth(r *http.Request) string {
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, "Bearer ") {
		return ""
	}
	token := strings.TrimPrefix(header, "Bearer ")
	now := time.Now()
	st.mu.RLock()
	defer st.mu.RUnlock()
	for id, account := range st.users {
		if account == nil {
			continue
		}
		if expires, ok := account.Sessions[token]; ok && now.Before(parseISO(expires)) {
			return id
		}
	}
	return ""
}

func accountIDOf(account *user) string {
	for id, a := range st.users {
		if a == account {
			return id
		}
	}
	return ""
}

// ---------- Handlers ----------

func handleRegister(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	email := strings.ToLower(strings.TrimSpace(body.Email))
	password := body.Password
	if !emailRe.MatchString(email) {
		sendError(w, 400, "invalid email")
		return
	}
	if len(password) < 8 {
		sendError(w, 400, "password must be at least 8 characters")
		return
	}

	st.mu.Lock()
	defer st.mu.Unlock()
	for _, u := range st.users {
		if u != nil && u.Email == email {
			sendError(w, 409, "an account with this email already exists")
			return
		}
	}

	id := newUUID()
	salt := newSalt()
	account := &user{
		Email:     email,
		Salt:      salt,
		Hash:      hex.EncodeToString(scryptHash(password, mustHex(salt))),
		CreatedAt: nowISO(),
		Sessions:  map[string]string{},
	}
	// First registered account on a fresh server becomes the admin. Admin
	// accounts are trusted by definition, so they skip email verification.
	if hasAdmin, err := store.HasAdmin(); err == nil && !hasAdmin {
		account.IsAdmin = true
		log.Printf("[%s] promoted %s to admin (first account)", nowISO(), email)
	} else if st.requireEmailVerification {
		verified := false
		vc := newVerifyCode()
		account.EmailVerified = &verified
		account.VerifyCode = &vc
		account.LastVerifySent = nowISO()
	} else {
		// Email verification disabled by the server admin: sign up is
		// immediate, exactly like an admin account.
		verified := true
		account.EmailVerified = &verified
	}
	st.users[id] = account
	st.blobs[id] = &blob{Revision: 0}
	persistUserID(id)
	persistBlobID(id)
	verified := account.EmailVerified == nil || *account.EmailVerified
	if !verified && account.VerifyCode != nil {
		sendVerificationEmail(email, account.VerifyCode.Code)
	}
	log.Printf("[%s] registered %s (%s)", nowISO(), email, id)
	sendJSON(w, 201, map[string]any{"userId": id, "emailVerified": verified, "isAdmin": account.IsAdmin})
}

func handleLogin(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	email := strings.ToLower(strings.TrimSpace(body.Email))
	password := body.Password

	st.mu.Lock()
	defer st.mu.Unlock()
	var account *user
	for _, u := range st.users {
		if u != nil && u.Email == email {
			account = u
			break
		}
	}
	// Timing-safe comparison: compute scrypt against a random salt even for
	// unknown emails so response time does not leak which emails exist.
	var salt []byte
	if account != nil {
		var err error
		if salt, err = hex.DecodeString(account.Salt); err != nil {
			salt = []byte(account.Salt)
		}
	} else {
		salt = make([]byte, 16)
		_, _ = rand.Read(salt)
	}
	expected := make([]byte, scryptKeyLen)
	if account != nil {
		expected, _ = hex.DecodeString(account.Hash)
	}
	actual := scryptHash(password, salt)
	if account == nil || subtle.ConstantTimeCompare(expected, actual) != 1 {
		sendError(w, 401, "invalid email or password")
		return
	}
	if account.EmailVerified != nil && !*account.EmailVerified {
		// Resend the code so the user can complete verification right away
		// (rate-limited, so repeated sign-ins cannot spam the inbox).
		if canResend(account) {
			vc := newVerifyCode()
			account.VerifyCode = &vc
			account.LastVerifySent = nowISO()
			persistUser(account)
			sendVerificationEmail(account.Email, vc.Code)
		}
		sendError(w, 403, "emailNotVerified")
		return
	}
	if account.TotpSecret != "" {
		account.Challenge = &challenge{
			Token:     randomHex(32),
			ExpiresAt: time.Now().Add(totpChallengeTTL).UTC().Format("2006-01-02T15:04:05.000Z"),
		}
		persistUser(account)
		sendJSON(w, 200, map[string]any{"needsTotp": true, "challengeToken": account.Challenge.Token})
		return
	}
	token := issueSession(account)
	persistUser(account)
	log.Printf("[%s] login %s", nowISO(), email)
	sendJSON(w, 200, map[string]any{"token": token, "userId": accountIDOf(account)})
}

func handleVerifyEmail(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Email string `json:"email"`
		Code  string `json:"code"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	email := strings.ToLower(strings.TrimSpace(body.Email))

	st.mu.Lock()
	defer st.mu.Unlock()
	var account *user
	for _, u := range st.users {
		if u != nil && u.Email == email {
			account = u
			break
		}
	}
	if account == nil || (account.EmailVerified != nil && *account.EmailVerified) {
		sendError(w, 404, "no pending verification for this email")
		return
	}
	if !verifyCodeValid(account, body.Code) {
		sendError(w, 400, "invalid or expired code")
		return
	}
	verified := true
	account.EmailVerified = &verified
	account.VerifyCode = nil
	account.LastVerifySent = ""
	persistUser(account)
	log.Printf("[%s] verified %s", nowISO(), email)
	sendJSON(w, 200, map[string]any{"verified": true})
}

func handleResendVerification(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Email string `json:"email"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	email := strings.ToLower(strings.TrimSpace(body.Email))

	st.mu.Lock()
	defer st.mu.Unlock()
	var account *user
	for _, u := range st.users {
		if u != nil && u.Email == email {
			account = u
			break
		}
	}
	if account == nil || (account.EmailVerified != nil && *account.EmailVerified) {
		sendError(w, 404, "no pending verification for this email")
		return
	}
	if !canResend(account) {
		sendError(w, 429, "wait a minute before requesting another code")
		return
	}
	vc := newVerifyCode()
	account.VerifyCode = &vc
	account.LastVerifySent = nowISO()
	persistUser(account)
	sendVerificationEmail(account.Email, vc.Code)
	sendJSON(w, 200, map[string]any{"resent": true})
}

func handleLogin2FA(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ChallengeToken string `json:"challengeToken"`
		Code           string `json:"code"`
	}
	if !readJSON(w, r, &body) {
		return
	}

	st.mu.Lock()
	defer st.mu.Unlock()
	var account *user
	for _, u := range st.users {
		if u != nil && u.Challenge != nil && u.Challenge.Token == body.ChallengeToken {
			account = u
			break
		}
	}
	if account == nil {
		sendError(w, 400, "invalid or expired challenge")
		return
	}
	if time.Now().After(parseISO(account.Challenge.ExpiresAt)) {
		account.Challenge = nil
		persistUser(account)
		sendError(w, 400, "invalid or expired challenge")
		return
	}
	if account.TotpSecret == "" || !verifyTotp(account.TotpSecret, body.Code) {
		sendError(w, 401, "invalid code")
		return
	}
	account.Challenge = nil
	token := issueSession(account)
	persistUser(account)
	log.Printf("[%s] login %s (2fa)", nowISO(), account.Email)
	sendJSON(w, 200, map[string]any{"token": token, "userId": accountIDOf(account)})
}

func handleAccount(w http.ResponseWriter, account *user) {
	verified := account.EmailVerified == nil || *account.EmailVerified
	sendJSON(w, 200, map[string]any{
		"email":         account.Email,
		"userId":        accountIDOf(account),
		"isAdmin":       account.IsAdmin,
		"emailVerified": verified,
		"totpEnabled":   account.TotpSecret != "",
	})
}

func handleEnable2FA(w http.ResponseWriter, account *user) {
	secret := newTotpSecret()
	account.TotpPending = &totpPending{Secret: secret, CreatedAt: nowISO()}
	persistUser(account)
	sendJSON(w, 200, map[string]any{"secret": secret, "otpauthUrl": otpauthURL(account.Email, secret)})
}

func handleConfirm2FA(w http.ResponseWriter, account *user, r *http.Request) {
	var body struct {
		Code string `json:"code"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	if account.TotpPending == nil {
		sendError(w, 400, "no pending 2FA setup")
		return
	}
	if !verifyTotp(account.TotpPending.Secret, body.Code) {
		sendError(w, 400, "invalid code")
		return
	}
	account.TotpSecret = account.TotpPending.Secret
	account.TotpPending = nil
	persistUser(account)
	log.Printf("[%s] 2FA enabled for %s", nowISO(), account.Email)
	sendJSON(w, 200, map[string]any{"enabled": true})
}

func handleDisable2FA(w http.ResponseWriter, account *user, r *http.Request) {
	var body struct {
		Code string `json:"code"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	if account.TotpSecret == "" {
		sendError(w, 400, "2FA is not enabled")
		return
	}
	if !verifyTotp(account.TotpSecret, body.Code) {
		sendError(w, 400, "invalid code")
		return
	}
	account.TotpSecret = ""
	persistUser(account)
	log.Printf("[%s] 2FA disabled for %s", nowISO(), account.Email)
	sendJSON(w, 200, map[string]any{"disabled": true})
}

// handleDeleteAccount permanently removes the account, its sessions and its
// encrypted snapshot (both the in-memory entry and the on-disk blob file).
func handleDeleteAccount(w http.ResponseWriter, userId string) {
	st.mu.Lock()
	defer st.mu.Unlock()
	account := st.users[userId]
	if account == nil {
		sendError(w, 404, "unknown account")
		return
	}
	delete(st.users, userId)
	delete(st.blobs, userId)
	if err := store.DeleteUser(userId); err != nil {
		log.Printf("error deleting user %s: %v", userId, err)
	}
	if err := store.DeleteBlob(userId); err != nil {
		log.Printf("error deleting blob %s: %v", userId, err)
	}
	log.Printf("[%s] deleted account %s (%s)", nowISO(), account.Email, userId)
	sendJSON(w, 200, map[string]any{"deleted": true})
}

func handleSyncGet(w http.ResponseWriter, r *http.Request, userId string) {
	st.mu.RLock()
	b := st.blobs[userId]
	st.mu.RUnlock()
	if b == nil {
		b = &blob{Revision: 0}
	}
	sendJSON(w, 200, map[string]any{
		"revision":  b.Revision,
		"blob":      b.Blob,
		"updatedAt": b.UpdatedAt,
	})
}

func handleSyncPost(w http.ResponseWriter, r *http.Request, userId string) {
	var body struct {
		Revision int    `json:"revision"`
		Blob     string `json:"blob"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	if body.Revision < 0 {
		sendError(w, 400, "invalid revision")
		return
	}
	// Approximate decoded byte size like Node's Buffer.byteLength(blob, 'base64').
	decodedLen := base64.StdEncoding.DecodedLen(len(body.Blob))
	if decodedLen > blobLimitBytes {
		sendError(w, 413, "blob too large")
		return
	}

	st.mu.Lock()
	defer st.mu.Unlock()
	current := st.blobs[userId]
	if current == nil {
		current = &blob{Revision: 0}
	}
	if body.Revision != current.Revision {
		sendError(w, 409, "revision conflict")
		return
	}
	blobStr := body.Blob
	ts := nowISO()
	next := &blob{Revision: current.Revision + 1, Blob: &blobStr, UpdatedAt: &ts}
	st.blobs[userId] = next
	persistBlobID(userId)
	log.Printf("[%s] sync %s -> revision %d", nowISO(), st.users[userId].Email, next.Revision)
	sendJSON(w, 200, map[string]any{"revision": next.Revision})
}

func mustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		log.Printf("hex decode error for salt %q", s)
		return []byte(s)
	}
	return b
}

func main() {
	usersFile = filepath.Join(dataDir, "users.json")
	blobsDir = filepath.Join(dataDir, "blobs")

	var err error
	store, err = openStore()
	if err != nil {
		log.Fatalf("failed to open storage: %v", err)
	}
	defer store.Close()
	log.Printf("Storage backend: %s", storeBackendName())

	migrateFromJSON(store)

	if err := load(); err != nil {
		log.Fatalf("failed to load data: %v", err)
	}

	mux := http.NewServeMux()

	withCORS := func(h http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if r.Method == http.MethodOptions {
				w.Header().Set("Access-Control-Allow-Origin", "*")
				w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
				w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
				w.WriteHeader(http.StatusNoContent)
				return
			}
			h(w, r)
		}
	}

	rl := newRateLimiter()

	// Public endpoints.
	mux.HandleFunc("/api/health", withCORS(func(w http.ResponseWriter, r *http.Request) {
		sendJSON(w, 200, map[string]any{"ok": true, "time": nowISO()})
	}))
	mux.HandleFunc("/api/register", withCORS(withRateLimit(rl, "register", rateRegisterLimit, rateRegisterWindow, handleRegister)))
	mux.HandleFunc("/api/login", withCORS(withRateLimit(rl, "login", rateLoginLimit, rateLoginWindow, handleLogin)))
	mux.HandleFunc("/api/verify-email", withCORS(withRateLimit(rl, "verify", rateCodeLimit, rateCodeWindow, handleVerifyEmail)))
	mux.HandleFunc("/api/resend-verification", withCORS(withRateLimit(rl, "resend", rateResendLimit, rateResendWindow, handleResendVerification)))
	mux.HandleFunc("/api/login/2fa", withCORS(withRateLimit(rl, "login2fa", rateCodeLimit, rateCodeWindow, handleLogin2FA)))
	mux.HandleFunc("/api/public/stats", withCORS(withRateLimit(rl, "stats", rateSyncLimit, rateSyncWindow, handlePublicStats)))
	mux.HandleFunc("/api/setup/status", withCORS(withRateLimit(rl, "setup", rateSyncLimit, rateSyncWindow, handleSetupStatus)))
	mux.HandleFunc("/api/admin/users", withCORS(handleAdminUsers))
	mux.HandleFunc("/api/admin/users/delete", withCORS(handleAdminDeleteUser))
	mux.HandleFunc("/api/admin/users/role", withCORS(handleAdminSetRole))
	mux.HandleFunc("/api/admin/settings", withCORS(handleAdminSettings))
	mux.HandleFunc("/admin", withCORS(serveAdmin))
	mux.HandleFunc("/robots.txt", withCORS(serveRobots))
	mux.HandleFunc("/sitemap.xml", withCORS(serveSitemap))
	mux.HandleFunc("/assets/", withCORS(serveAsset))

	// Public marketing / auth pages.
	mux.HandleFunc("/docs", withCORS(serveDocs))
	mux.HandleFunc("/dashboard", withCORS(serveDashboard))
	mux.HandleFunc("/login", withCORS(serveLogin))
	mux.HandleFunc("/register", withCORS(serveRegister))
	mux.HandleFunc("/account", withCORS(serveAccount))

	// Authenticated endpoints.
	mux.HandleFunc("/", withCORS(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/":
			serveHome(w, r)
			return
		}
		switch r.URL.Path {
		case "/api/account", "/api/enable-2fa", "/api/confirm-2fa", "/api/disable-2fa",
			"/api/account/delete", "/api/sync":
		default:
			sendError(w, 404, "not found")
			return
		}
		userId := auth(r)
		if userId == "" {
			sendError(w, 401, "missing or invalid session token")
			return
		}
		st.mu.RLock()
		account := st.users[userId]
		st.mu.RUnlock()
		if account == nil {
			sendError(w, 401, "unknown account")
			return
		}
		if account.EmailVerified != nil && !*account.EmailVerified {
			sendError(w, 403, "email not verified")
			return
		}
		switch r.URL.Path {
		case "/api/account":
			handleAccount(w, account)
		case "/api/account/delete":
			handleDeleteAccount(w, userId)
		case "/api/enable-2fa":
			handleEnable2FA(w, account)
		case "/api/confirm-2fa":
			handleConfirm2FA(w, account, r)
		case "/api/disable-2fa":
			handleDisable2FA(w, account, r)
		case "/api/sync":
			if r.Method == http.MethodGet {
				handleSyncGet(w, r, userId)
			} else if r.Method == http.MethodPost {
				if !rl.allow("sync:"+clientIP(r), rateSyncLimit, rateSyncWindow) {
					sendError(w, 429, "too many requests")
					return
				}
				handleSyncPost(w, r, userId)
			} else {
				sendError(w, 404, "not found")
			}
		}
	}))

	addr := fmt.Sprintf(":%d", port)
	log.Printf("Connexia sync server listening on http://0.0.0.0:%d", port)
	log.Printf("Data directory: %s", dataDir)
	server := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	if err := server.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
