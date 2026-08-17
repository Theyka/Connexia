package main

import (
	"crypto/subtle"
	"embed"
	"encoding/base64"
	"html/template"
	"net/http"
	"sort"
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
// view at /admin (guarded by ADMIN_TOKEN) and robots.txt / sitemap.xml.
// Templates live in templates/ and are embedded into the binary so the
// container has no runtime file dependency.
var (
	serverName    = envStr("SERVER_NAME", "Connexia Sync Server")
	adminToken    = envStr("ADMIN_TOKEN", "")
	serverVersion = "1.0.0"
	startTime     = time.Now()

	dashboardTmpl = template.Must(template.New("dashboard").Parse(mustTemplateFile("templates/dashboard.html")))
	adminHTML     = mustTemplateFile("templates/admin.html")
	robotsTxt     = mustTemplateFile("templates/robots.txt")
	sitemapTmpl   = texttemplate.Must(texttemplate.New("sitemap").Parse(mustTemplateFile("templates/sitemap.xml")))
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
	Version    string
	Uptime     string
	Users      int
	Verified   int
	Snapshots  int
	BlobBytes  int64
	LastActive string
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
		if u.EmailVerified != nil && *u.EmailVerified {
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
	if s.LastActive != "" {
		s.LastActive = s.LastActive[:10] + " " + s.LastActive[11:19]
	}
	return s
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

func adminAllowed(r *http.Request) bool {
	if adminToken == "" {
		return false
	}
	token := r.URL.Query().Get("token")
	if token == "" {
		h := r.Header.Get("Authorization")
		if strings.HasPrefix(h, "Bearer ") {
			token = strings.TrimPrefix(h, "Bearer ")
		}
	}
	return subtle.ConstantTimeCompare([]byte(token), []byte(adminToken)) == 1
}

func handleAdminUsers(w http.ResponseWriter, r *http.Request) {
	if !adminAllowed(r) {
		sendError(w, 401, "admin token required")
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
			"emailVerified": u.EmailVerified != nil && *u.EmailVerified,
			"totpEnabled":   u.TotpSecret != "",
			"sessions":      len(u.Sessions),
			"blobBytes":     blobBytes,
		})
	}
	sort.Slice(users, func(i, j int) bool {
		return users[i]["createdAt"].(string) < users[j]["createdAt"].(string)
	})
	sendJSON(w, 200, map[string]any{"users": users})
}

// ---------- Page handlers ----------

func serveDashboard(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = dashboardTmpl.Execute(w, collectStats())
}

func serveAdmin(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(adminHTML))
}

func serveRobots(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte(robotsTxt))
}

func serveSitemap(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/xml; charset=utf-8")
	_ = sitemapTmpl.Execute(w, map[string]string{"Host": r.Host})
}
