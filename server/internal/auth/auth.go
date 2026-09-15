package auth

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"log"
	"net/http"
	"strings"
	"time"

	"connexia/syncserver/internal/config"
	"connexia/syncserver/internal/cryptoutil"
	"connexia/syncserver/internal/email"
	"connexia/syncserver/internal/httpx"
	"connexia/syncserver/internal/model"
	"connexia/syncserver/internal/state"
	"connexia/syncserver/internal/store"
	"connexia/syncserver/internal/teams"
)

func HandleRegister(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	emailAddr := strings.ToLower(strings.TrimSpace(body.Email))
	password := body.Password
	if !config.EmailRe.MatchString(emailAddr) {
		httpx.SendError(w, 400, "invalid email")
		return
	}
	if len(password) < 8 {
		httpx.SendError(w, 400, "password must be at least 8 characters")
		return
	}

	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	for _, u := range state.St.Users {
		if u != nil && u.Email == emailAddr {
			httpx.SendError(w, 409, "an account with this email already exists")
			return
		}
	}

	id := cryptoutil.NewUUID()
	salt := cryptoutil.NewSalt()
	account := &model.User{
		Email:     emailAddr,
		Salt:      salt,
		Hash:      hex.EncodeToString(cryptoutil.ScryptHash(password, cryptoutil.MustHex(salt))),
		CreatedAt: cryptoutil.NowISO(),
		Sessions:  map[string]string{},
	}

	if hasAdmin, err := store.DB.HasAdmin(); err == nil && !hasAdmin {
		account.IsAdmin = true
		log.Printf("[%s] promoted %s to admin (first account)", cryptoutil.NowISO(), emailAddr)
	} else if state.St.RequireEmailVerification {
		verified := false
		vc := email.NewVerifyCode()
		account.EmailVerified = &verified
		account.VerifyCode = &vc
		account.LastVerifySent = cryptoutil.NowISO()
	} else {

		verified := true
		account.EmailVerified = &verified
	}
	state.St.Users[id] = account
	state.St.Blobs[id] = &model.Blob{Revision: 0}
	state.PersistUserID(id)
	state.PersistBlobID(id)
	verified := account.EmailVerified == nil || *account.EmailVerified
	if !verified && account.VerifyCode != nil {
		email.SendVerificationEmail(emailAddr, account.VerifyCode.Code)
	}
	log.Printf("[%s] registered %s (%s)", cryptoutil.NowISO(), emailAddr, id)
	httpx.SendJSON(w, 201, map[string]any{"userId": id, "emailVerified": verified, "isAdmin": account.IsAdmin})
}

func HandleLogin(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	emailAddr := strings.ToLower(strings.TrimSpace(body.Email))
	password := body.Password

	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	var account *model.User
	for _, u := range state.St.Users {
		if u != nil && u.Email == emailAddr {
			account = u
			break
		}
	}

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
	expected := make([]byte, config.ScryptKeyLen)
	if account != nil {
		expected, _ = hex.DecodeString(account.Hash)
	}
	actual := cryptoutil.ScryptHash(password, salt)
	if account == nil || subtle.ConstantTimeCompare(expected, actual) != 1 {
		httpx.SendError(w, 401, "invalid email or password")
		return
	}
	if account.EmailVerified != nil && !*account.EmailVerified {

		if email.CanResend(account) {
			vc := email.NewVerifyCode()
			account.VerifyCode = &vc
			account.LastVerifySent = cryptoutil.NowISO()
			state.PersistUser(account)
			email.SendVerificationEmail(account.Email, vc.Code)
		}
		httpx.SendError(w, 403, "emailNotVerified")
		return
	}
	if account.TotpSecret != "" {
		account.Challenge = &model.Challenge{
			Token:     cryptoutil.RandomHex(32),
			ExpiresAt: time.Now().Add(config.TotpChallengeTTL).UTC().Format("2006-01-02T15:04:05.000Z"),
		}
		state.PersistUser(account)
		httpx.SendJSON(w, 200, map[string]any{"needsTotp": true, "challengeToken": account.Challenge.Token})
		return
	}
	token := state.IssueSession(account)
	state.PersistUser(account)
	log.Printf("[%s] login %s", cryptoutil.NowISO(), emailAddr)
	httpx.SendJSON(w, 200, map[string]any{"token": token, "userId": state.AccountIDOf(account)})
}

func HandleVerifyEmail(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Email string `json:"email"`
		Code  string `json:"code"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	emailAddr := strings.ToLower(strings.TrimSpace(body.Email))

	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	var account *model.User
	for _, u := range state.St.Users {
		if u != nil && u.Email == emailAddr {
			account = u
			break
		}
	}
	if account == nil || (account.EmailVerified != nil && *account.EmailVerified) {
		httpx.SendError(w, 404, "no pending verification for this email")
		return
	}
	if !email.VerifyCodeValid(account, body.Code) {
		httpx.SendError(w, 400, "invalid or expired code")
		return
	}
	verified := true
	account.EmailVerified = &verified
	account.VerifyCode = nil
	account.LastVerifySent = ""
	state.PersistUser(account)
	log.Printf("[%s] verified %s", cryptoutil.NowISO(), emailAddr)
	httpx.SendJSON(w, 200, map[string]any{"verified": true})
}

func HandleResendVerification(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Email string `json:"email"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	emailAddr := strings.ToLower(strings.TrimSpace(body.Email))

	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	var account *model.User
	for _, u := range state.St.Users {
		if u != nil && u.Email == emailAddr {
			account = u
			break
		}
	}
	if account == nil || (account.EmailVerified != nil && *account.EmailVerified) {
		httpx.SendError(w, 404, "no pending verification for this email")
		return
	}
	if !email.CanResend(account) {
		httpx.SendError(w, 429, "wait a minute before requesting another code")
		return
	}
	vc := email.NewVerifyCode()
	account.VerifyCode = &vc
	account.LastVerifySent = cryptoutil.NowISO()
	state.PersistUser(account)
	email.SendVerificationEmail(account.Email, vc.Code)
	httpx.SendJSON(w, 200, map[string]any{"resent": true})
}

func HandleLogin2FA(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ChallengeToken string `json:"challengeToken"`
		Code           string `json:"code"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}

	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	var account *model.User
	for _, u := range state.St.Users {
		if u != nil && u.Challenge != nil && u.Challenge.Token == body.ChallengeToken {
			account = u
			break
		}
	}
	if account == nil {
		httpx.SendError(w, 400, "invalid or expired challenge")
		return
	}
	if time.Now().After(cryptoutil.ParseISO(account.Challenge.ExpiresAt)) {
		account.Challenge = nil
		state.PersistUser(account)
		httpx.SendError(w, 400, "invalid or expired challenge")
		return
	}
	if account.TotpSecret == "" || !cryptoutil.VerifyTotp(account.TotpSecret, body.Code) {
		httpx.SendError(w, 401, "invalid code")
		return
	}
	account.Challenge = nil
	token := state.IssueSession(account)
	state.PersistUser(account)
	log.Printf("[%s] login %s (2fa)", cryptoutil.NowISO(), account.Email)
	httpx.SendJSON(w, 200, map[string]any{"token": token, "userId": state.AccountIDOf(account)})
}

func HandleAccount(w http.ResponseWriter, account *model.User) {
	verified := account.EmailVerified == nil || *account.EmailVerified
	webSSH, _ := state.WebSSH()
	httpx.SendJSON(w, 200, map[string]any{
		"webSSH":        webSSH,
		"email":         account.Email,
		"userId":        state.AccountIDOf(account),
		"isAdmin":       account.IsAdmin,
		"emailVerified": verified,
		"totpEnabled":   account.TotpSecret != "",
	})
}

func HandleEnable2FA(w http.ResponseWriter, account *model.User) {
	secret := cryptoutil.NewTotpSecret()
	account.TotpPending = &model.TotpPending{Secret: secret, CreatedAt: cryptoutil.NowISO()}
	state.PersistUser(account)
	httpx.SendJSON(w, 200, map[string]any{"secret": secret, "otpauthUrl": cryptoutil.OtpauthURL(account.Email, secret)})
}

func HandleConfirm2FA(w http.ResponseWriter, account *model.User, r *http.Request) {
	var body struct {
		Code string `json:"code"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	if account.TotpPending == nil {
		httpx.SendError(w, 400, "no pending 2FA setup")
		return
	}
	if !cryptoutil.VerifyTotp(account.TotpPending.Secret, body.Code) {
		httpx.SendError(w, 400, "invalid code")
		return
	}
	account.TotpSecret = account.TotpPending.Secret
	account.TotpPending = nil
	state.PersistUser(account)
	log.Printf("[%s] 2FA enabled for %s", cryptoutil.NowISO(), account.Email)
	httpx.SendJSON(w, 200, map[string]any{"enabled": true})
}

func HandleDisable2FA(w http.ResponseWriter, account *model.User, r *http.Request) {
	var body struct {
		Code string `json:"code"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	if account.TotpSecret == "" {
		httpx.SendError(w, 400, "2FA is not enabled")
		return
	}
	if !cryptoutil.VerifyTotp(account.TotpSecret, body.Code) {
		httpx.SendError(w, 400, "invalid code")
		return
	}
	account.TotpSecret = ""
	state.PersistUser(account)
	log.Printf("[%s] 2FA disabled for %s", cryptoutil.NowISO(), account.Email)
	httpx.SendJSON(w, 200, map[string]any{"disabled": true})
}

func HandleDeleteAccount(w http.ResponseWriter, userId string) {
	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	account := state.St.Users[userId]
	if account == nil {
		httpx.SendError(w, 404, "unknown account")
		return
	}
	delete(state.St.Users, userId)
	delete(state.St.Blobs, userId)
	delete(state.St.UserKeys, userId)
	teams.RemoveFromAll(userId)
	if err := store.DB.DeleteUser(userId); err != nil {
		log.Printf("error deleting user %s: %v", userId, err)
	}
	if err := store.DB.DeleteBlob(userId); err != nil {
		log.Printf("error deleting blob %s: %v", userId, err)
	}
	if err := store.DB.DeleteUserKey(userId); err != nil {
		log.Printf("error deleting user key %s: %v", userId, err)
	}
	log.Printf("[%s] deleted account %s (%s)", cryptoutil.NowISO(), account.Email, userId)
	httpx.SendJSON(w, 200, map[string]any{"deleted": true})
}
