package main

import (
	"embed"
	"encoding/base64"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	texttemplate "text/template"
	"time"
)

//go:embed templates/*
var templateFS embed.FS

// Dashboard configuration.
//
// The web UI is served from the same binary: a public, SEO-friendly landing
// page at / (stats are rendered server-side so crawlers see them), an admin
// view at /admin and robots.txt / sitemap.xml. Templates live in templates/
// and are embedded into the binary so the container has no runtime file
// dependency.
//
// /admin is protected by the admin *account*: on a fresh server (no admin
// yet) it shows a first-run registration form; afterwards it requires
// signing in as the admin account.
var (
	serverName    = envStr("SERVER_NAME", "Connexia Sync Server")
	serverVersion = "1.0.0"
	startTime     = time.Now()

	adminHTML   = mustTemplateFile("templates/admin.html")
	accountHTML = mustTemplateFile("templates/account.html")
	robotsTxt   = mustTemplateFile("templates/robots.txt")
	sitemapTmpl = texttemplate.Must(texttemplate.New("sitemap").Parse(mustTemplateFile("templates/sitemap.xml")))
)

func mustTemplateFile(path string) string {
	b, err := templateFS.ReadFile(path)
	if err != nil {
		panic(err)
	}
	return string(b)
}

// ---------- Stats ----------

type dashboardStats struct {
	Name       string
	Version      string
	Uptime       string
	Users        int
	Verified     int
	Snapshots    int
	BlobBytes    int64
	BlobBytesFmt string
	LastActive   string
}

func collectStats() dashboardStats {
	st.mu.RLock()
	defer st.mu.RUnlock()
	var s dashboardStats
	for id, u := range st.users {
		if u == nil {
			continue
		}
		s.Users++
		if u.EmailVerified == nil || *u.EmailVerified {
			s.Verified++
		}
		if b := st.blobs[id]; b != nil && b.Blob != nil && *b.Blob != "" {
			s.Snapshots++
			s.BlobBytes += int64(base64.StdEncoding.DecodedLen(len(*b.Blob)))
			if b.UpdatedAt != nil && (s.LastActive == "" || *b.UpdatedAt > s.LastActive) {
				s.LastActive = *b.UpdatedAt
			}
		}
	}
	s.Name = serverName
	s.Version = serverVersion
	s.Uptime = formatDuration(time.Since(startTime))
	s.BlobBytesFmt = formatBytes(s.BlobBytes)
	if s.LastActive != "" {
		s.LastActive = s.LastActive[:10] + " " + s.LastActive[11:19]
	}
	return s
}

func formatBytes(n int64) string {
	switch {
	case n >= 1<<30:
		return itoa(int(n>>20)/1024) + " GiB"
	case n >= 1<<20:
		return itoa(int(n>>10)/1024) + " MiB"
	case n >= 1<<10:
		return itoa(int(n)/1024) + " KiB"
	default:
		return itoa(int(n)) + " B"
	}
}

func formatDuration(d time.Duration) string {
	d = d.Round(time.Second)
	h := d / time.Hour
	d -= h * time.Hour
	m := d / time.Minute
	d -= m * time.Minute
	sec := d / time.Second
	var parts []string
	if h > 0 {
		parts = append(parts, itoa(int(h))+"h")
	}
	if m > 0 {
		parts = append(parts, itoa(int(m))+"m")
	}
	if sec > 0 || len(parts) == 0 {
		parts = append(parts, itoa(int(sec))+"s")
	}
	return strings.Join(parts, " ")
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}

// ---------- Handlers ----------

func handlePublicStats(w http.ResponseWriter, r *http.Request) {
	s := collectStats()
	sendJSON(w, 200, map[string]any{
		"name":       s.Name,
		"version":    s.Version,
		"uptime":     s.Uptime,
		"users":      s.Users,
		"verified":   s.Verified,
		"snapshots":  s.Snapshots,
		"blobBytes":  s.BlobBytes,
		"lastActive": s.LastActive,
		"serverUrl":  r.Host,
	})
}

// handleSetupStatus reports whether an admin account exists yet, so the
// client can offer a first-run "create admin" flow.
func handleSetupStatus(w http.ResponseWriter, r *http.Request) {
	hasAdmin, err := store.HasAdmin()
	if err != nil {
		sendError(w, 500, "storage error")
		return
	}
	sendJSON(w, 200, map[string]any{"adminExists": hasAdmin})
}

// adminAllowed reports whether the request carries a valid session token
// belonging to an admin account.
func adminAllowed(r *http.Request) bool {
	id := auth(r)
	if id == "" {
		return false
	}
	st.mu.RLock()
	defer st.mu.RUnlock()
	u := st.users[id]
	return u != nil && u.IsAdmin
}

func handleAdminUsers(w http.ResponseWriter, r *http.Request) {
	if !adminAllowed(r) {
		sendError(w, 401, "admin account required")
		return
	}
	st.mu.RLock()
	defer st.mu.RUnlock()
	users := []map[string]any{}
	for id, u := range st.users {
		if u == nil {
			continue
		}
		var blobBytes int64
		if b := st.blobs[id]; b != nil && b.Blob != nil {
			blobBytes = int64(base64.StdEncoding.DecodedLen(len(*b.Blob)))
		}
		users = append(users, map[string]any{
			"id":            id,
			"email":         u.Email,
			"createdAt":     u.CreatedAt,
			"emailVerified": u.EmailVerified == nil || *u.EmailVerified,
			"totpEnabled":   u.TotpSecret != "",
			"sessions":      len(u.Sessions),
			"blobBytes":     blobBytes,
			"isAdmin":       u.IsAdmin,
		})
	}
	sort.Slice(users, func(i, j int) bool {
		return users[i]["createdAt"].(string) < users[j]["createdAt"].(string)
	})
	sendJSON(w, 200, map[string]any{"users": users})
}

// isLastAdmin reports whether id is the only admin account left. Callers
// must hold st.mu (read or write lock).
func isLastAdmin(id string) bool {
	admins := 0
	for _, u := range st.users {
		if u != nil && u.IsAdmin {
			admins++
			if admins > 1 {
				return false
			}
		}
	}
	if u := st.users[id]; u != nil && u.IsAdmin && admins <= 1 {
		return true
	}
	return false
}

// handleAdminDeleteUser permanently removes any account (admin action).
func handleAdminDeleteUser(w http.ResponseWriter, r *http.Request) {
	if !adminAllowed(r) {
		sendError(w, 401, "admin account required")
		return
	}
	var body struct {
		Id string `json:"id"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	actor := adminEmailOf(r)
	st.mu.Lock()
	defer st.mu.Unlock()
	account := st.users[body.Id]
	if account == nil {
		sendError(w, 404, "unknown account")
		return
	}
	if isLastAdmin(body.Id) {
		sendError(w, 400, "cannot delete the last admin")
		return
	}
	delete(st.users, body.Id)
	delete(st.blobs, body.Id)
	if err := store.DeleteUser(body.Id); err != nil {
		log.Printf("error deleting user %s: %v", body.Id, err)
	}
	if err := store.DeleteBlob(body.Id); err != nil {
		log.Printf("error deleting blob %s: %v", body.Id, err)
	}
	log.Printf("[%s] admin %s deleted account %s (%s)", nowISO(), actor, account.Email, body.Id)
	sendJSON(w, 200, map[string]any{"deleted": true})
}

// handleAdminSetRole promotes or demotes an account (admin action).
func handleAdminSetRole(w http.ResponseWriter, r *http.Request) {
	if !adminAllowed(r) {
		sendError(w, 401, "admin account required")
		return
	}
	var body struct {
		Id      string `json:"id"`
		IsAdmin bool   `json:"isAdmin"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	actor := adminEmailOf(r)
	st.mu.Lock()
	defer st.mu.Unlock()
	account := st.users[body.Id]
	if account == nil {
		sendError(w, 404, "unknown account")
		return
	}
	if account.IsAdmin && !body.IsAdmin && isLastAdmin(body.Id) {
		sendError(w, 400, "cannot demote the last admin")
		return
	}
	account.IsAdmin = body.IsAdmin
	persistUserID(body.Id)
	log.Printf("[%s] admin %s set isAdmin=%v for %s (%s)", nowISO(), actor, body.IsAdmin, account.Email, body.Id)
	sendJSON(w, 200, map[string]any{"isAdmin": account.IsAdmin})
}

// adminEmailOf resolves the acting admin's email for audit logs.
func adminEmailOf(r *http.Request) string {
	if id := auth(r); id != "" {
		st.mu.RLock()
		defer st.mu.RUnlock()
		if u := st.users[id]; u != nil {
			return u.Email
		}
	}
	return "?"
}

// handleAdminSettings reads or updates server-wide settings (admin action).
func handleAdminSettings(w http.ResponseWriter, r *http.Request) {
	if !adminAllowed(r) {
		sendError(w, 401, "admin account required")
		return
	}
	if r.Method == http.MethodGet {
		st.mu.RLock()
		req := st.requireEmailVerification
		st.mu.RUnlock()
		sendJSON(w, 200, map[string]any{"requireEmailVerification": req})
		return
	}
	if r.Method != http.MethodPost {
		sendError(w, 404, "not found")
		return
	}
	var body struct {
		RequireEmailVerification *bool `json:"requireEmailVerification"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	if body.RequireEmailVerification == nil {
		sendError(w, 400, "missing requireEmailVerification")
		return
	}
	val := *body.RequireEmailVerification
	st.mu.Lock()
	st.requireEmailVerification = val
	st.mu.Unlock()
	if err := store.SetSetting("require_email_verification", strconv.FormatBool(val)); err != nil {
		log.Printf("error saving setting require_email_verification: %v", err)
		sendError(w, 500, "storage error")
		return
	}
	log.Printf("[%s] admin %s set requireEmailVerification=%v", nowISO(), adminEmailOf(r), val)
	sendJSON(w, 200, map[string]any{"requireEmailVerification": val})
}

// ---------- Page handlers ----------

func serveAdmin(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(adminHTML))
}

func serveAccount(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(accountHTML))
}

func serveRobots(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte(robotsTxt))
}

func serveSitemap(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/xml; charset=utf-8")
	_ = sitemapTmpl.Execute(w, map[string]string{"Host": r.Host})
}
