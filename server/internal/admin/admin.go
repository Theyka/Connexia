// Package admin implements the admin-only endpoints (user list, delete,
// role changes, server settings) plus the public stats endpoint.
package admin

import (
	"encoding/base64"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"connexia/syncserver/internal/config"
	"connexia/syncserver/internal/cryptoutil"
	"connexia/syncserver/internal/httpx"
	"connexia/syncserver/internal/state"
	"connexia/syncserver/internal/store"
	"connexia/syncserver/internal/teams"
)

var (
	ServerName    = config.EnvStr("SERVER_NAME", "Connexia Sync Server")
	serverVersion = "1.0.0"
	startTime     = time.Now()
)

// Stats is the server-usage summary shown on the landing page and the
// admin view.
type Stats struct {
	Name         string
	Version      string
	Uptime       string
	Users        int
	Verified     int
	Snapshots    int
	BlobBytes    int64
	BlobBytesFmt string
	LastActive   string
}

// CollectStats computes the usage summary from the hot state.
func CollectStats() Stats {
	state.St.Mu.RLock()
	defer state.St.Mu.RUnlock()
	var s Stats
	for id, u := range state.St.Users {
		if u == nil {
			continue
		}
		s.Users++
		if u.EmailVerified == nil || *u.EmailVerified {
			s.Verified++
		}
		if b := state.St.Blobs[id]; b != nil && b.Blob != nil && *b.Blob != "" {
			s.Snapshots++
			s.BlobBytes += int64(base64.StdEncoding.DecodedLen(len(*b.Blob)))
			if b.UpdatedAt != nil && (s.LastActive == "" || *b.UpdatedAt > s.LastActive) {
				s.LastActive = *b.UpdatedAt
			}
		}
	}
	s.Name = ServerName
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

func HandlePublicStats(w http.ResponseWriter, r *http.Request) {
	s := CollectStats()
	httpx.SendJSON(w, 200, map[string]any{
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

// HandleSetupStatus reports whether an admin account exists yet, so the
// client can offer a first-run "create admin" flow.
func HandleSetupStatus(w http.ResponseWriter, r *http.Request) {
	hasAdmin, err := store.DB.HasAdmin()
	if err != nil {
		httpx.SendError(w, 500, "storage error")
		return
	}
	httpx.SendJSON(w, 200, map[string]any{"adminExists": hasAdmin})
}

// adminAllowed reports whether the request carries a valid session token
// belonging to an admin account.
func adminAllowed(r *http.Request) bool {
	id := state.Auth(r)
	if id == "" {
		return false
	}
	state.St.Mu.RLock()
	defer state.St.Mu.RUnlock()
	u := state.St.Users[id]
	return u != nil && u.IsAdmin
}

func HandleUsers(w http.ResponseWriter, r *http.Request) {
	if !adminAllowed(r) {
		httpx.SendError(w, 401, "admin account required")
		return
	}
	state.St.Mu.RLock()
	defer state.St.Mu.RUnlock()
	users := []map[string]any{}
	for id, u := range state.St.Users {
		if u == nil {
			continue
		}
		var blobBytes int64
		if b := state.St.Blobs[id]; b != nil && b.Blob != nil {
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
	httpx.SendJSON(w, 200, map[string]any{"users": users})
}

// isLastAdmin reports whether id is the only admin account left. Callers
// must hold state.St.Mu (read or write lock).
func isLastAdmin(id string) bool {
	admins := 0
	for _, u := range state.St.Users {
		if u != nil && u.IsAdmin {
			admins++
			if admins > 1 {
				return false
			}
		}
	}
	if u := state.St.Users[id]; u != nil && u.IsAdmin && admins <= 1 {
		return true
	}
	return false
}

// HandleDeleteUser permanently removes any account (admin action).
func HandleDeleteUser(w http.ResponseWriter, r *http.Request) {
	if !adminAllowed(r) {
		httpx.SendError(w, 401, "admin account required")
		return
	}
	var body struct {
		Id string `json:"id"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	actor := adminEmailOf(r)
	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	account := state.St.Users[body.Id]
	if account == nil {
		httpx.SendError(w, 404, "unknown account")
		return
	}
	if isLastAdmin(body.Id) {
		httpx.SendError(w, 400, "cannot delete the last admin")
		return
	}
	delete(state.St.Users, body.Id)
	delete(state.St.Blobs, body.Id)
	delete(state.St.UserKeys, body.Id)
	teams.RemoveFromAll(body.Id)
	if err := store.DB.DeleteUser(body.Id); err != nil {
		log.Printf("error deleting user %s: %v", body.Id, err)
	}
	if err := store.DB.DeleteBlob(body.Id); err != nil {
		log.Printf("error deleting blob %s: %v", body.Id, err)
	}
	if err := store.DB.DeleteUserKey(body.Id); err != nil {
		log.Printf("error deleting user key %s: %v", body.Id, err)
	}
	log.Printf("[%s] admin %s deleted account %s (%s)", cryptoutil.NowISO(), actor, account.Email, body.Id)
	httpx.SendJSON(w, 200, map[string]any{"deleted": true})
}

// HandleSetRole promotes or demotes an account (admin action).
func HandleSetRole(w http.ResponseWriter, r *http.Request) {
	if !adminAllowed(r) {
		httpx.SendError(w, 401, "admin account required")
		return
	}
	var body struct {
		Id      string `json:"id"`
		IsAdmin bool   `json:"isAdmin"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	actor := adminEmailOf(r)
	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	account := state.St.Users[body.Id]
	if account == nil {
		httpx.SendError(w, 404, "unknown account")
		return
	}
	if account.IsAdmin && !body.IsAdmin && isLastAdmin(body.Id) {
		httpx.SendError(w, 400, "cannot demote the last admin")
		return
	}
	account.IsAdmin = body.IsAdmin
	state.PersistUserID(body.Id)
	log.Printf("[%s] admin %s set isAdmin=%v for %s (%s)", cryptoutil.NowISO(), actor, body.IsAdmin, account.Email, body.Id)
	httpx.SendJSON(w, 200, map[string]any{"isAdmin": account.IsAdmin})
}

// adminEmailOf resolves the acting admin's email for audit logs.
func adminEmailOf(r *http.Request) string {
	if id := state.Auth(r); id != "" {
		state.St.Mu.RLock()
		defer state.St.Mu.RUnlock()
		if u := state.St.Users[id]; u != nil {
			return u.Email
		}
	}
	return "?"
}

// HandleSettings reads or updates server-wide settings (admin action).
func HandleSettings(w http.ResponseWriter, r *http.Request) {
	if !adminAllowed(r) {
		httpx.SendError(w, 401, "admin account required")
		return
	}
	if r.Method == http.MethodGet {
		state.St.Mu.RLock()
		req := state.St.RequireEmailVerification
		state.St.Mu.RUnlock()
		httpx.SendJSON(w, 200, map[string]any{"requireEmailVerification": req})
		return
	}
	if r.Method != http.MethodPost {
		httpx.SendError(w, 404, "not found")
		return
	}
	var body struct {
		RequireEmailVerification *bool `json:"requireEmailVerification"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	if body.RequireEmailVerification == nil {
		httpx.SendError(w, 400, "missing requireEmailVerification")
		return
	}
	val := *body.RequireEmailVerification
	state.St.Mu.Lock()
	state.St.RequireEmailVerification = val
	state.St.Mu.Unlock()
	if err := store.DB.SetSetting("require_email_verification", strconv.FormatBool(val)); err != nil {
		log.Printf("error saving setting require_email_verification: %v", err)
		httpx.SendError(w, 500, "storage error")
		return
	}
	log.Printf("[%s] admin %s set requireEmailVerification=%v", cryptoutil.NowISO(), adminEmailOf(r), val)
	httpx.SendJSON(w, 200, map[string]any{"requireEmailVerification": val})
}
