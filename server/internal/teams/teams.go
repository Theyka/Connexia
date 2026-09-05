// Package teams implements the workspace (team) API: membership, encrypted
// workspace blobs, key rotation and the audit log.
package teams

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
	"connexia/syncserver/internal/model"
	"connexia/syncserver/internal/ratelimit"
	"connexia/syncserver/internal/state"
	"connexia/syncserver/internal/store"
)

// Rate limiters for team endpoints.
var (
	teamRL     = ratelimit.New()
	teamSyncRL = ratelimit.New()
)

const (
	teamMutateLimit  = 60
	teamMutateWindow = time.Minute
)

// ---------- Helpers ----------

func validRole(role string) bool {
	switch role {
	case "owner", "admin", "member":
		return true
	}
	return false
}

func memberOf(t *model.Team, userID string) *model.TeamMember {
	for i := range t.Members {
		if t.Members[i].UserID == userID {
			return &t.Members[i]
		}
	}
	return nil
}

func isAdminOrOwner(m *model.TeamMember) bool {
	return m != nil && (m.Role == "admin" || m.Role == "owner")
}

func isOwner(m *model.TeamMember) bool {
	return m != nil && m.Role == "owner"
}

func teamMutateAllowed(r *http.Request) bool {
	return teamRL.Allow("team:"+ratelimit.ClientIP(r), teamMutateLimit, teamMutateWindow)
}

// auditLog appends a single event to the store. Callers need not hold
// state.St.Mu.
func auditLog(wsID, actorID, action, target, ip string, revision int, source string) {
	e := &model.AuditEvent{
		ID: cryptoutil.NewUUID(), WorkspaceID: wsID, ActorID: actorID,
		Action: action, Target: target, Revision: revision,
		IP: ip, Source: source, CreatedAt: cryptoutil.NowISO(),
	}
	if err := store.DB.AppendAudit(e); err != nil {
		log.Printf("error appending audit event for workspace %s: %v", wsID, err)
	}
}

// RemoveFromAll drops userID from every workspace membership.
// Callers must hold state.St.Mu (write lock).
func RemoveFromAll(userID string) {
	for id, t := range state.St.Teams {
		idx := -1
		for i := range t.Members {
			if t.Members[i].UserID == userID {
				idx = i
				break
			}
		}
		if idx < 0 {
			continue
		}
		t.Members = append(t.Members[:idx], t.Members[idx+1:]...)
		persistTeamID(id)
		auditLog(id, "system", "member.remove", userID, "", 0, "server")
		log.Printf("removed %s from workspace %s", userID, id)
	}
}

func persistTeamID(id string) {
	if err := store.DB.SaveTeam(id, state.St.Teams[id]); err != nil {
		log.Printf("error saving team %s: %v", id, err)
	}
}

func persistTeamBlobID(id string) {
	if err := store.DB.SaveTeamBlob(id, state.St.TeamBlobs[id]); err != nil {
		log.Printf("error saving team blob %s: %v", id, err)
	}
}

func persistUserKeyID(id string) {
	if err := store.DB.SaveUserKey(id, state.St.UserKeys[id]); err != nil {
		log.Printf("error saving user key %s: %v", id, err)
	}
}

// ---------- Dispatch ----------

// HandleRequest dispatches to the appropriate handler based on the path.
// It is called from the authenticated route catch-all in main.go.
func HandleRequest(w http.ResponseWriter, r *http.Request, account *model.User, userId string) {
	path := r.URL.Path

	if path == "/api/me/key" {
		switch r.Method {
		case http.MethodGet:
			handleGetUserKey(w, userId)
		case http.MethodPost:
			handleSetUserKey(w, r, userId)
		default:
			httpx.SendError(w, 404, "not found")
		}
		return
	}
	if path == "/api/workspaces" {
		switch r.Method {
		case http.MethodGet:
			handleListTeams(w, userId)
		case http.MethodPost:
			handleCreateTeam(w, r, account, userId)
		default:
			httpx.SendError(w, 404, "not found")
		}
		return
	}
	if !strings.HasPrefix(path, "/api/workspaces/") {
		httpx.SendError(w, 404, "not found")
		return
	}
	rest := strings.TrimPrefix(path, "/api/workspaces/")
	wsID, sub, hasSub := strings.Cut(rest, "/")
	if wsID == "" {
		httpx.SendError(w, 404, "not found")
		return
	}
	if !hasSub {
		switch r.Method {
		case http.MethodGet:
			handleGetTeam(w, wsID, userId)
		case http.MethodPatch:
			handleRenameTeam(w, r, wsID, account, userId)
		case http.MethodDelete:
			handleDeleteTeam(w, r, wsID, account, userId)
		default:
			httpx.SendError(w, 404, "not found")
		}
		return
	}
	switch sub {
	case "sync":
		switch r.Method {
		case http.MethodGet:
			handleTeamSyncGet(w, wsID, userId)
		case http.MethodPost:
			handleTeamSyncPost(w, r, wsID, account, userId)
		default:
			httpx.SendError(w, 404, "not found")
		}
	case "audit":
		if r.Method != http.MethodGet {
			httpx.SendError(w, 404, "not found")
			return
		}
		handleAuditList(w, r, wsID, userId)
	case "invites":
		if r.Method != http.MethodPost {
			httpx.SendError(w, 404, "not found")
			return
		}
		handleInvite(w, r, wsID, account, userId)
	case "key-rotate":
		if r.Method != http.MethodPost {
			httpx.SendError(w, 404, "not found")
			return
		}
		handleKeyRotate(w, r, wsID, account, userId)
	default:
		if strings.HasPrefix(sub, "members/") {
			uid := strings.TrimPrefix(sub, "members/")
			switch r.Method {
			case http.MethodPut:
				handleAddMember(w, r, wsID, uid, account, userId)
			case http.MethodPatch:
				handleSetMemberRole(w, r, wsID, uid, account, userId)
			case http.MethodDelete:
				handleRemoveMember(w, r, wsID, uid, account, userId)
			default:
				httpx.SendError(w, 404, "not found")
			}
			return
		}
		httpx.SendError(w, 404, "not found")
	}
}

// ---------- User key endpoints ----------

func handleGetUserKey(w http.ResponseWriter, userId string) {
	state.St.Mu.RLock()
	uk := state.St.UserKeys[userId]
	state.St.Mu.RUnlock()
	if uk == nil || uk.PublicKey == "" {
		httpx.SendJSON(w, 200, map[string]any{"hasKey": false})
		return
	}
	httpx.SendJSON(w, 200, map[string]any{"hasKey": true, "publicKey": uk.PublicKey})
}

func handleSetUserKey(w http.ResponseWriter, r *http.Request, userId string) {
	var body struct {
		PublicKey         string `json:"publicKey"`
		WrappedPrivateKey string `json:"wrappedPrivateKey"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	body.PublicKey = strings.TrimSpace(body.PublicKey)
	body.WrappedPrivateKey = strings.TrimSpace(body.WrappedPrivateKey)
	if body.PublicKey == "" || body.WrappedPrivateKey == "" {
		httpx.SendError(w, 400, "missing publicKey or wrappedPrivateKey")
		return
	}
	if len(body.PublicKey) > 4096 || len(body.WrappedPrivateKey) > 8192 {
		httpx.SendError(w, 400, "key too large")
		return
	}
	uk := &model.UserKey{UserID: userId, PublicKey: body.PublicKey, WrappedPrivateKey: body.WrappedPrivateKey}
	state.St.Mu.Lock()
	state.St.UserKeys[userId] = uk
	state.St.Mu.Unlock()
	persistUserKeyID(userId)
	httpx.SendJSON(w, 200, map[string]any{"saved": true})
}

// ---------- Workspace CRUD ----------

func handleCreateTeam(w http.ResponseWriter, r *http.Request, account *model.User, userId string) {
	var body struct {
		Name       string `json:"name"`
		WrappedKey string `json:"wrappedKey"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	name := strings.TrimSpace(body.Name)
	if name == "" || len(name) > 100 {
		httpx.SendError(w, 400, "invalid workspace name")
		return
	}
	if strings.TrimSpace(body.WrappedKey) == "" {
		httpx.SendError(w, 400, "missing wrappedKey")
		return
	}
	if !teamMutateAllowed(r) {
		httpx.SendError(w, 429, "too many requests")
		return
	}
	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	id := cryptoutil.NewUUID()
	t := &model.Team{
		ID: id, Name: name, CreatedBy: userId, CreatedAt: cryptoutil.NowISO(),
		Members: []model.TeamMember{{
			UserID: userId, Email: account.Email, Role: "owner",
			WrappedKey: body.WrappedKey, JoinedAt: cryptoutil.NowISO(),
		}},
		KeyVersion: 1,
	}
	state.St.Teams[id] = t
	state.St.TeamBlobs[id] = &model.Blob{Revision: 0}
	persistTeamID(id)
	persistTeamBlobID(id)
	auditLog(id, userId, "workspace.create", name, ratelimit.ClientIP(r), 0, "server")
	log.Printf("[%s] %s created workspace %s (%s)", cryptoutil.NowISO(), account.Email, name, id)
	httpx.SendJSON(w, 201, map[string]any{"id": id, "name": name, "role": "owner", "keyVersion": 1})
}

func handleListTeams(w http.ResponseWriter, userId string) {
	state.St.Mu.RLock()
	defer state.St.Mu.RUnlock()
	out := []map[string]any{}
	for id, t := range state.St.Teams {
		m := memberOf(t, userId)
		if m == nil {
			continue
		}
		out = append(out, map[string]any{
			"id":          id,
			"name":        t.Name,
			"role":        m.Role,
			"memberCount": len(t.Members),
			"keyVersion":  t.KeyVersion,
			"createdAt":   t.CreatedAt,
			"createdBy":   t.CreatedBy,
		})
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i]["name"].(string) < out[j]["name"].(string)
	})
	httpx.SendJSON(w, 200, map[string]any{"workspaces": out})
}

func handleGetTeam(w http.ResponseWriter, wsID, userId string) {
	state.St.Mu.RLock()
	defer state.St.Mu.RUnlock()
	t := state.St.Teams[wsID]
	if t == nil {
		httpx.SendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		httpx.SendError(w, 403, "not a member")
		return
	}
	members := []map[string]any{}
	for _, tm := range t.Members {
		entry := map[string]any{
			"userId":   tm.UserID,
			"email":    tm.Email,
			"role":     tm.Role,
			"joinedAt": tm.JoinedAt,
		}
		if tm.UserID == userId {
			entry["wrappedKey"] = tm.WrappedKey
		}
		if uk := state.St.UserKeys[tm.UserID]; uk != nil {
			entry["publicKey"] = uk.PublicKey
		}
		members = append(members, entry)
	}
	httpx.SendJSON(w, 200, map[string]any{
		"id": wsID, "name": t.Name, "createdBy": t.CreatedBy, "createdAt": t.CreatedAt,
		"keyVersion": t.KeyVersion, "myRole": m.Role, "members": members,
	})
}

func handleRenameTeam(w http.ResponseWriter, r *http.Request, wsID string, account *model.User, userId string) {
	var body struct {
		Name string `json:"name"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	name := strings.TrimSpace(body.Name)
	if name == "" || len(name) > 100 {
		httpx.SendError(w, 400, "invalid workspace name")
		return
	}
	if !teamMutateAllowed(r) {
		httpx.SendError(w, 429, "too many requests")
		return
	}
	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	t := state.St.Teams[wsID]
	if t == nil {
		httpx.SendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		httpx.SendError(w, 403, "not a member")
		return
	}
	if !isAdminOrOwner(m) {
		httpx.SendError(w, 403, "owner or admin required")
		return
	}
	oldName := t.Name
	t.Name = name
	persistTeamID(wsID)
	auditLog(wsID, userId, "workspace.rename", oldName+" -> "+name, ratelimit.ClientIP(r), t.KeyVersion, "server")
	log.Printf("[%s] %s renamed workspace %s to %s", cryptoutil.NowISO(), account.Email, wsID, name)
	httpx.SendJSON(w, 200, map[string]any{"name": name})
}

func handleDeleteTeam(w http.ResponseWriter, r *http.Request, wsID string, account *model.User, userId string) {
	if !teamMutateAllowed(r) {
		httpx.SendError(w, 429, "too many requests")
		return
	}
	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	t := state.St.Teams[wsID]
	if t == nil {
		httpx.SendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		httpx.SendError(w, 403, "not a member")
		return
	}
	if !isOwner(m) {
		httpx.SendError(w, 403, "only the owner can delete the workspace")
		return
	}
	name := t.Name
	delete(state.St.Teams, wsID)
	delete(state.St.TeamBlobs, wsID)
	if err := store.DB.DeleteTeam(wsID); err != nil {
		log.Printf("error deleting team %s: %v", wsID, err)
	}
	if err := store.DB.DeleteTeamBlob(wsID); err != nil {
		log.Printf("error deleting team blob %s: %v", wsID, err)
	}
	auditLog(wsID, userId, "workspace.delete", name, ratelimit.ClientIP(r), 0, "server")
	log.Printf("[%s] %s deleted workspace %s (%s)", cryptoutil.NowISO(), account.Email, name, wsID)
	httpx.SendJSON(w, 200, map[string]any{"deleted": true})
}

// ---------- Membership ----------

func handleInvite(w http.ResponseWriter, r *http.Request, wsID string, account *model.User, userId string) {
	var body struct {
		Email string `json:"email"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	email := strings.ToLower(strings.TrimSpace(body.Email))
	if !config.EmailRe.MatchString(email) {
		httpx.SendError(w, 400, "invalid email")
		return
	}
	if !teamMutateAllowed(r) {
		httpx.SendError(w, 429, "too many requests")
		return
	}
	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	t := state.St.Teams[wsID]
	if t == nil {
		httpx.SendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		httpx.SendError(w, 403, "not a member")
		return
	}
	if !isAdminOrOwner(m) {
		httpx.SendError(w, 403, "owner or admin required")
		return
	}
	var targetID string
	var target *model.User
	for id, u := range state.St.Users {
		if u != nil && u.Email == email {
			targetID = id
			target = u
			break
		}
	}
	if target == nil {
		httpx.SendError(w, 404, "no Connexia account with that email")
		return
	}
	if memberOf(t, targetID) != nil {
		httpx.SendError(w, 409, "already a member")
		return
	}
	if target.EmailVerified != nil && !*target.EmailVerified {
		httpx.SendError(w, 409, "that account has not verified its email")
		return
	}
	uk := state.St.UserKeys[targetID]
	if uk == nil || uk.PublicKey == "" {
		httpx.SendError(w, 409, "that account has not set up a key yet")
		return
	}
	httpx.SendJSON(w, 200, map[string]any{"userId": targetID, "publicKey": uk.PublicKey, "email": target.Email})
}

func handleAddMember(w http.ResponseWriter, r *http.Request, wsID, uid string, account *model.User, userId string) {
	var body struct {
		Role       string `json:"role"`
		WrappedKey string `json:"wrappedKey"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	role := body.Role
	if role != "admin" && role != "member" {
		httpx.SendError(w, 400, "invalid role: must be admin or member")
		return
	}
	if strings.TrimSpace(body.WrappedKey) == "" {
		httpx.SendError(w, 400, "missing wrappedKey")
		return
	}
	if !teamMutateAllowed(r) {
		httpx.SendError(w, 429, "too many requests")
		return
	}
	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	t := state.St.Teams[wsID]
	if t == nil {
		httpx.SendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		httpx.SendError(w, 403, "not a member")
		return
	}
	if !isAdminOrOwner(m) {
		httpx.SendError(w, 403, "owner or admin required")
		return
	}
	if uid == userId {
		httpx.SendError(w, 400, "cannot add yourself")
		return
	}
	if state.St.Users[uid] == nil {
		httpx.SendError(w, 404, "unknown account")
		return
	}
	uk := state.St.UserKeys[uid]
	if uk == nil || uk.PublicKey == "" {
		httpx.SendError(w, 409, "that account has no key")
		return
	}
	if existing := memberOf(t, uid); existing != nil {
		existing.Role = role
		existing.WrappedKey = body.WrappedKey
	} else {
		acct := state.St.Users[uid]
		t.Members = append(t.Members, model.TeamMember{
			UserID: uid, Email: acct.Email, Role: role,
			WrappedKey: body.WrappedKey, JoinedAt: cryptoutil.NowISO(),
		})
	}
	persistTeamID(wsID)
	auditLog(wsID, userId, "member.add", uid, ratelimit.ClientIP(r), t.KeyVersion, "server")
	log.Printf("[%s] %s added %s (%s) to workspace %s", cryptoutil.NowISO(), account.Email, state.St.Users[uid].Email, uid, wsID)
	httpx.SendJSON(w, 200, map[string]any{"ok": true})
}

func handleSetMemberRole(w http.ResponseWriter, r *http.Request, wsID, uid string, account *model.User, userId string) {
	var body struct {
		Role string `json:"role"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	role := body.Role
	if role != "admin" && role != "member" {
		httpx.SendError(w, 400, "invalid role: must be admin or member")
		return
	}
	if !teamMutateAllowed(r) {
		httpx.SendError(w, 429, "too many requests")
		return
	}
	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	t := state.St.Teams[wsID]
	if t == nil {
		httpx.SendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		httpx.SendError(w, 403, "not a member")
		return
	}
	if !isOwner(m) {
		httpx.SendError(w, 403, "only the owner can change roles")
		return
	}
	tm := memberOf(t, uid)
	if tm == nil {
		httpx.SendError(w, 404, "not a member of this workspace")
		return
	}
	if tm.Role == "owner" {
		httpx.SendError(w, 400, "cannot change the owner's role through this endpoint")
		return
	}
	tm.Role = role
	persistTeamID(wsID)
	auditLog(wsID, userId, "member.role", uid+":"+role, ratelimit.ClientIP(r), t.KeyVersion, "server")
	log.Printf("[%s] %s set role of %s to %s in workspace %s", cryptoutil.NowISO(), account.Email, uid, role, wsID)
	httpx.SendJSON(w, 200, map[string]any{"ok": true})
}

func handleRemoveMember(w http.ResponseWriter, r *http.Request, wsID, uid string, account *model.User, userId string) {
	if !teamMutateAllowed(r) {
		httpx.SendError(w, 429, "too many requests")
		return
	}
	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	t := state.St.Teams[wsID]
	if t == nil {
		httpx.SendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		httpx.SendError(w, 403, "not a member")
		return
	}
	tm := memberOf(t, uid)
	if tm == nil {
		httpx.SendError(w, 404, "not a member of this workspace")
		return
	}
	if uid == userId {
		// Leaving workspace.
		if tm.Role == "owner" {
			httpx.SendError(w, 400, "owner cannot leave; delete the workspace instead")
			return
		}
	} else {
		// Removing someone else.
		if !isAdminOrOwner(m) {
			httpx.SendError(w, 403, "owner or admin required")
			return
		}
		if tm.Role == "owner" && !isOwner(m) {
			httpx.SendError(w, 403, "only the owner can remove the owner")
			return
		}
	}
	idx := -1
	for i := range t.Members {
		if t.Members[i].UserID == uid {
			idx = i
			break
		}
	}
	if idx >= 0 {
		t.Members = append(t.Members[:idx], t.Members[idx+1:]...)
	}
	persistTeamID(wsID)
	auditLog(wsID, userId, "member.remove", uid, ratelimit.ClientIP(r), t.KeyVersion, "server")
	log.Printf("[%s] %s removed %s from workspace %s", cryptoutil.NowISO(), account.Email, uid, wsID)
	httpx.SendJSON(w, 200, map[string]any{"ok": true})
}

// ---------- Key rotation ----------

func handleKeyRotate(w http.ResponseWriter, r *http.Request, wsID string, account *model.User, userId string) {
	var body struct {
		Members []struct {
			UserID     string `json:"userId"`
			Role       string `json:"role"`
			WrappedKey string `json:"wrappedKey"`
		} `json:"members"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	if len(body.Members) == 0 {
		httpx.SendError(w, 400, "members list cannot be empty")
		return
	}
	if !teamMutateAllowed(r) {
		httpx.SendError(w, 429, "too many requests")
		return
	}
	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	t := state.St.Teams[wsID]
	if t == nil {
		httpx.SendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		httpx.SendError(w, 403, "not a member")
		return
	}
	if !isAdminOrOwner(m) {
		httpx.SendError(w, 403, "owner or admin required")
		return
	}
	newMembers := []model.TeamMember{}
	actorIncluded := false
	for _, item := range body.Members {
		uid := item.UserID
		acct := state.St.Users[uid]
		if acct == nil {
			httpx.SendError(w, 400, "unknown user: "+uid)
			return
		}
		role := item.Role
		if !validRole(role) {
			httpx.SendError(w, 400, "invalid role for user "+uid)
			return
		}
		if strings.TrimSpace(item.WrappedKey) == "" {
			httpx.SendError(w, 400, "missing wrappedKey for user "+uid)
			return
		}
		uk := state.St.UserKeys[uid]
		if uk == nil || uk.PublicKey == "" {
			httpx.SendError(w, 400, "user "+uid+" has no key")
			return
		}
		joinedAt := cryptoutil.NowISO()
		if old := memberOf(t, uid); old != nil {
			joinedAt = old.JoinedAt
		}
		newMembers = append(newMembers, model.TeamMember{
			UserID: uid, Email: acct.Email, Role: role,
			WrappedKey: item.WrappedKey, JoinedAt: joinedAt,
		})
		if uid == userId {
			actorIncluded = true
		}
	}
	if !actorIncluded {
		httpx.SendError(w, 400, "you must remain a member after rotation")
		return
	}
	t.Members = newMembers
	t.KeyVersion++
	persistTeamID(wsID)
	auditLog(wsID, userId, "workspace.key-rotate", strconv.Itoa(t.KeyVersion), ratelimit.ClientIP(r), t.KeyVersion, "server")
	log.Printf("[%s] %s rotated key for workspace %s (v%d)", cryptoutil.NowISO(), account.Email, wsID, t.KeyVersion)
	httpx.SendJSON(w, 200, map[string]any{"keyVersion": t.KeyVersion})
}

// ---------- Sync ----------

func handleTeamSyncGet(w http.ResponseWriter, wsID, userId string) {
	state.St.Mu.RLock()
	t := state.St.Teams[wsID]
	if t == nil {
		state.St.Mu.RUnlock()
		httpx.SendError(w, 404, "unknown workspace")
		return
	}
	if memberOf(t, userId) == nil {
		state.St.Mu.RUnlock()
		httpx.SendError(w, 403, "not a member")
		return
	}
	b := state.St.TeamBlobs[wsID]
	state.St.Mu.RUnlock()
	if b == nil {
		b = &model.Blob{Revision: 0}
	}
	httpx.SendJSON(w, 200, map[string]any{
		"revision":  b.Revision,
		"blob":      b.Blob,
		"updatedAt": b.UpdatedAt,
	})
}

func handleTeamSyncPost(w http.ResponseWriter, r *http.Request, wsID string, account *model.User, userId string) {
	var body struct {
		Revision int    `json:"revision"`
		Blob     string `json:"blob"`
		Actions  []struct {
			Action string `json:"action"`
			Target string `json:"target"`
		} `json:"actions"`
	}
	if !httpx.ReadJSON(w, r, &body) {
		return
	}
	if body.Revision < 0 {
		httpx.SendError(w, 400, "invalid revision")
		return
	}
	decodedLen := base64.StdEncoding.DecodedLen(len(body.Blob))
	if decodedLen > config.BlobLimitBytes {
		httpx.SendError(w, 413, "blob too large")
		return
	}
	if len(body.Actions) > 200 {
		httpx.SendError(w, 400, "too many actions")
		return
	}
	if !teamSyncRL.Allow("ws-sync:"+ratelimit.ClientIP(r), config.RateSyncLimit, config.RateSyncWindow) {
		httpx.SendError(w, 429, "too many requests")
		return
	}
	state.St.Mu.Lock()
	defer state.St.Mu.Unlock()
	t := state.St.Teams[wsID]
	if t == nil {
		httpx.SendError(w, 404, "unknown workspace")
		return
	}
	if memberOf(t, userId) == nil {
		httpx.SendError(w, 403, "not a member")
		return
	}
	current := state.St.TeamBlobs[wsID]
	if current == nil {
		current = &model.Blob{Revision: 0}
	}
	if body.Revision != current.Revision {
		httpx.SendError(w, 409, "revision conflict")
		return
	}
	blobStr := body.Blob
	ts := cryptoutil.NowISO()
	next := &model.Blob{Revision: current.Revision + 1, Blob: &blobStr, UpdatedAt: &ts}
	state.St.TeamBlobs[wsID] = next
	persistTeamBlobID(wsID)
	ip := ratelimit.ClientIP(r)
	auditLog(wsID, userId, "workspace.sync", strconv.Itoa(next.Revision), ip, next.Revision, "server")
	for _, a := range body.Actions {
		action := a.Action
		target := a.Target
		if action == "" {
			continue
		}
		if len(action) > 64 {
			action = action[:64]
		}
		if len(target) > 128 {
			target = target[:128]
		}
		auditLog(wsID, userId, action, target, ip, next.Revision, "client")
	}
	log.Printf("[%s] %s synced workspace %s -> revision %d", cryptoutil.NowISO(), account.Email, wsID, next.Revision)
	httpx.SendJSON(w, 200, map[string]any{"revision": next.Revision})
}

// ---------- Audit ----------

func handleAuditList(w http.ResponseWriter, r *http.Request, wsID, userId string) {
	q := model.AuditQuery{Limit: 100, Offset: 0}
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 500 {
			q.Limit = n
		}
	}
	if v := r.URL.Query().Get("offset"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			q.Offset = n
		}
	}
	if v := r.URL.Query().Get("actor"); v != "" {
		q.Actor = v
	}
	if v := r.URL.Query().Get("action"); v != "" {
		q.Action = v
	}

	state.St.Mu.RLock()
	t := state.St.Teams[wsID]
	if t == nil {
		state.St.Mu.RUnlock()
		httpx.SendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		state.St.Mu.RUnlock()
		httpx.SendError(w, 403, "not a member")
		return
	}
	if !isAdminOrOwner(m) {
		state.St.Mu.RUnlock()
		httpx.SendError(w, 403, "owner or admin required")
		return
	}
	emails := map[string]string{}
	for id, u := range state.St.Users {
		if u != nil {
			emails[id] = u.Email
		}
	}
	state.St.Mu.RUnlock()

	events, err := store.DB.AuditEvents(wsID, q)
	if err != nil {
		log.Printf("error reading audit events for workspace %s: %v", wsID, err)
		httpx.SendError(w, 500, "storage error")
		return
	}
	out := make([]map[string]any, 0, len(events))
	for _, e := range events {
		actorEmail := emails[e.ActorID]
		out = append(out, map[string]any{
			"id":          e.ID,
			"workspaceId": e.WorkspaceID,
			"actorId":     e.ActorID,
			"actorEmail":  actorEmail,
			"action":      e.Action,
			"target":      e.Target,
			"revision":    e.Revision,
			"ip":          e.IP,
			"source":      e.Source,
			"createdAt":   e.CreatedAt,
		})
	}
	httpx.SendJSON(w, 200, map[string]any{"events": out})
}
