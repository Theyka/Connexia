package main

import (
	"encoding/base64"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

// ---------- Data types ----------

type userKey struct {
	UserID            string `json:"userId"`
	PublicKey         string `json:"publicKey"`
	WrappedPrivateKey string `json:"wrappedPrivateKey"`
}

type teamMember struct {
	UserID     string `json:"userId"`
	Email      string `json:"email"`
	Role       string `json:"role"`
	WrappedKey string `json:"wrappedKey"`
	JoinedAt   string `json:"joinedAt"`
}

type team struct {
	ID         string       `json:"id"`
	Name       string       `json:"name"`
	CreatedBy  string       `json:"createdBy"`
	CreatedAt  string       `json:"createdAt"`
	Members    []teamMember `json:"members"`
	KeyVersion int          `json:"keyVersion"`
}

type auditEvent struct {
	ID          string `json:"id"`
	WorkspaceID string `json:"workspaceId"`
	ActorID     string `json:"actorId"`
	Action      string `json:"action"`
	Target      string `json:"target"`
	Revision    int    `json:"revision"`
	IP          string `json:"ip"`
	Source      string `json:"source"`
	CreatedAt   string `json:"createdAt"`
}

type auditQuery struct {
	Actor  string
	Action string
	Limit  int
	Offset int
}

// Rate limiters for team endpoints.
var (
	teamRL     = newRateLimiter()
	teamSyncRL = newRateLimiter()
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

func memberOf(t *team, userID string) *teamMember {
	for i := range t.Members {
		if t.Members[i].UserID == userID {
			return &t.Members[i]
		}
	}
	return nil
}

func isAdminOrOwner(m *teamMember) bool {
	return m != nil && (m.Role == "admin" || m.Role == "owner")
}

func isOwner(m *teamMember) bool {
	return m != nil && m.Role == "owner"
}

func teamMutateAllowed(r *http.Request) bool {
	return teamRL.allow("team:"+clientIP(r), teamMutateLimit, teamMutateWindow)
}

// auditLog appends a single event to the store. Callers need not hold st.mu.
func auditLog(wsID, actorID, action, target, ip string, revision int, source string) {
	e := &auditEvent{
		ID: newUUID(), WorkspaceID: wsID, ActorID: actorID,
		Action: action, Target: target, Revision: revision,
		IP: ip, Source: source, CreatedAt: nowISO(),
	}
	if err := store.AppendAudit(e); err != nil {
		log.Printf("error appending audit event for workspace %s: %v", wsID, err)
	}
}

// removeUserFromTeams drops userID from every workspace membership.
// Callers must hold st.mu (write lock).
func removeUserFromTeams(userID string) {
	for id, t := range st.teams {
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
	if err := store.SaveTeam(id, st.teams[id]); err != nil {
		log.Printf("error saving team %s: %v", id, err)
	}
}

func persistTeamBlobID(id string) {
	if err := store.SaveTeamBlob(id, st.teamBlobs[id]); err != nil {
		log.Printf("error saving team blob %s: %v", id, err)
	}
}

func persistUserKeyID(id string) {
	if err := store.SaveUserKey(id, st.userKeys[id]); err != nil {
		log.Printf("error saving user key %s: %v", id, err)
	}
}

// ---------- Dispatch ----------

// handleTeamRequest dispatches to the appropriate handler based on the path.
// It is called from the authenticated route catch-all in main.go.
func handleTeamRequest(w http.ResponseWriter, r *http.Request, account *user, userId string) {
	path := r.URL.Path

	if path == "/api/me/key" {
		switch r.Method {
		case http.MethodGet:
			handleGetUserKey(w, userId)
		case http.MethodPost:
			handleSetUserKey(w, r, userId)
		default:
			sendError(w, 404, "not found")
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
			sendError(w, 404, "not found")
		}
		return
	}
	if !strings.HasPrefix(path, "/api/workspaces/") {
		sendError(w, 404, "not found")
		return
	}
	rest := strings.TrimPrefix(path, "/api/workspaces/")
	wsID, sub, hasSub := strings.Cut(rest, "/")
	if wsID == "" {
		sendError(w, 404, "not found")
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
			sendError(w, 404, "not found")
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
			sendError(w, 404, "not found")
		}
	case "audit":
		if r.Method != http.MethodGet {
			sendError(w, 404, "not found")
			return
		}
		handleAuditList(w, r, wsID, userId)
	case "invites":
		if r.Method != http.MethodPost {
			sendError(w, 404, "not found")
			return
		}
		handleInvite(w, r, wsID, account, userId)
	case "key-rotate":
		if r.Method != http.MethodPost {
			sendError(w, 404, "not found")
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
				sendError(w, 404, "not found")
			}
			return
		}
		sendError(w, 404, "not found")
	}
}

// ---------- User key endpoints ----------

func handleGetUserKey(w http.ResponseWriter, userId string) {
	st.mu.RLock()
	uk := st.userKeys[userId]
	st.mu.RUnlock()
	if uk == nil || uk.PublicKey == "" {
		sendJSON(w, 200, map[string]any{"hasKey": false})
		return
	}
	sendJSON(w, 200, map[string]any{"hasKey": true, "publicKey": uk.PublicKey})
}

func handleSetUserKey(w http.ResponseWriter, r *http.Request, userId string) {
	var body struct {
		PublicKey         string `json:"publicKey"`
		WrappedPrivateKey string `json:"wrappedPrivateKey"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	body.PublicKey = strings.TrimSpace(body.PublicKey)
	body.WrappedPrivateKey = strings.TrimSpace(body.WrappedPrivateKey)
	if body.PublicKey == "" || body.WrappedPrivateKey == "" {
		sendError(w, 400, "missing publicKey or wrappedPrivateKey")
		return
	}
	if len(body.PublicKey) > 4096 || len(body.WrappedPrivateKey) > 8192 {
		sendError(w, 400, "key too large")
		return
	}
	uk := &userKey{UserID: userId, PublicKey: body.PublicKey, WrappedPrivateKey: body.WrappedPrivateKey}
	st.mu.Lock()
	st.userKeys[userId] = uk
	st.mu.Unlock()
	persistUserKeyID(userId)
	sendJSON(w, 200, map[string]any{"saved": true})
}

// ---------- Workspace CRUD ----------

func handleCreateTeam(w http.ResponseWriter, r *http.Request, account *user, userId string) {
	var body struct {
		Name       string `json:"name"`
		WrappedKey string `json:"wrappedKey"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	name := strings.TrimSpace(body.Name)
	if name == "" || len(name) > 100 {
		sendError(w, 400, "invalid workspace name")
		return
	}
	if strings.TrimSpace(body.WrappedKey) == "" {
		sendError(w, 400, "missing wrappedKey")
		return
	}
	if !teamMutateAllowed(r) {
		sendError(w, 429, "too many requests")
		return
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	id := newUUID()
	t := &team{
		ID: id, Name: name, CreatedBy: userId, CreatedAt: nowISO(),
		Members: []teamMember{{
			UserID: userId, Email: account.Email, Role: "owner",
			WrappedKey: body.WrappedKey, JoinedAt: nowISO(),
		}},
		KeyVersion: 1,
	}
	st.teams[id] = t
	st.teamBlobs[id] = &blob{Revision: 0}
	persistTeamID(id)
	persistTeamBlobID(id)
	auditLog(id, userId, "workspace.create", name, clientIP(r), 0, "server")
	log.Printf("[%s] %s created workspace %s (%s)", nowISO(), account.Email, name, id)
	sendJSON(w, 201, map[string]any{"id": id, "name": name, "role": "owner", "keyVersion": 1})
}

func handleListTeams(w http.ResponseWriter, userId string) {
	st.mu.RLock()
	defer st.mu.RUnlock()
	out := []map[string]any{}
	for id, t := range st.teams {
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
	sendJSON(w, 200, map[string]any{"workspaces": out})
}

func handleGetTeam(w http.ResponseWriter, wsID, userId string) {
	st.mu.RLock()
	defer st.mu.RUnlock()
	t := st.teams[wsID]
	if t == nil {
		sendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		sendError(w, 403, "not a member")
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
		if uk := st.userKeys[tm.UserID]; uk != nil {
			entry["publicKey"] = uk.PublicKey
		}
		members = append(members, entry)
	}
	sendJSON(w, 200, map[string]any{
		"id": wsID, "name": t.Name, "createdBy": t.CreatedBy, "createdAt": t.CreatedAt,
		"keyVersion": t.KeyVersion, "myRole": m.Role, "members": members,
	})
}

func handleRenameTeam(w http.ResponseWriter, r *http.Request, wsID string, account *user, userId string) {
	var body struct {
		Name string `json:"name"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	name := strings.TrimSpace(body.Name)
	if name == "" || len(name) > 100 {
		sendError(w, 400, "invalid workspace name")
		return
	}
	if !teamMutateAllowed(r) {
		sendError(w, 429, "too many requests")
		return
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	t := st.teams[wsID]
	if t == nil {
		sendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		sendError(w, 403, "not a member")
		return
	}
	if !isAdminOrOwner(m) {
		sendError(w, 403, "owner or admin required")
		return
	}
	oldName := t.Name
	t.Name = name
	persistTeamID(wsID)
	auditLog(wsID, userId, "workspace.rename", oldName+" -> "+name, clientIP(r), t.KeyVersion, "server")
	log.Printf("[%s] %s renamed workspace %s to %s", nowISO(), account.Email, wsID, name)
	sendJSON(w, 200, map[string]any{"name": name})
}

func handleDeleteTeam(w http.ResponseWriter, r *http.Request, wsID string, account *user, userId string) {
	if !teamMutateAllowed(r) {
		sendError(w, 429, "too many requests")
		return
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	t := st.teams[wsID]
	if t == nil {
		sendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		sendError(w, 403, "not a member")
		return
	}
	if !isOwner(m) {
		sendError(w, 403, "only the owner can delete the workspace")
		return
	}
	name := t.Name
	delete(st.teams, wsID)
	delete(st.teamBlobs, wsID)
	if err := store.DeleteTeam(wsID); err != nil {
		log.Printf("error deleting team %s: %v", wsID, err)
	}
	if err := store.DeleteTeamBlob(wsID); err != nil {
		log.Printf("error deleting team blob %s: %v", wsID, err)
	}
	auditLog(wsID, userId, "workspace.delete", name, clientIP(r), 0, "server")
	log.Printf("[%s] %s deleted workspace %s (%s)", nowISO(), account.Email, name, wsID)
	sendJSON(w, 200, map[string]any{"deleted": true})
}

// ---------- Membership ----------

func handleInvite(w http.ResponseWriter, r *http.Request, wsID string, account *user, userId string) {
	var body struct {
		Email string `json:"email"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	email := strings.ToLower(strings.TrimSpace(body.Email))
	if !emailRe.MatchString(email) {
		sendError(w, 400, "invalid email")
		return
	}
	if !teamMutateAllowed(r) {
		sendError(w, 429, "too many requests")
		return
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	t := st.teams[wsID]
	if t == nil {
		sendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		sendError(w, 403, "not a member")
		return
	}
	if !isAdminOrOwner(m) {
		sendError(w, 403, "owner or admin required")
		return
	}
	var targetID string
	var target *user
	for id, u := range st.users {
		if u != nil && u.Email == email {
			targetID = id
			target = u
			break
		}
	}
	if target == nil {
		sendError(w, 404, "no Connexia account with that email")
		return
	}
	if memberOf(t, targetID) != nil {
		sendError(w, 409, "already a member")
		return
	}
	if target.EmailVerified != nil && !*target.EmailVerified {
		sendError(w, 409, "that account has not verified its email")
		return
	}
	uk := st.userKeys[targetID]
	if uk == nil || uk.PublicKey == "" {
		sendError(w, 409, "that account has not set up a key yet")
		return
	}
	sendJSON(w, 200, map[string]any{"userId": targetID, "publicKey": uk.PublicKey, "email": target.Email})
}

func handleAddMember(w http.ResponseWriter, r *http.Request, wsID, uid string, account *user, userId string) {
	var body struct {
		Role       string `json:"role"`
		WrappedKey string `json:"wrappedKey"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	role := body.Role
	if role != "admin" && role != "member" {
		sendError(w, 400, "invalid role: must be admin or member")
		return
	}
	if strings.TrimSpace(body.WrappedKey) == "" {
		sendError(w, 400, "missing wrappedKey")
		return
	}
	if !teamMutateAllowed(r) {
		sendError(w, 429, "too many requests")
		return
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	t := st.teams[wsID]
	if t == nil {
		sendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		sendError(w, 403, "not a member")
		return
	}
	if !isAdminOrOwner(m) {
		sendError(w, 403, "owner or admin required")
		return
	}
	if uid == userId {
		sendError(w, 400, "cannot add yourself")
		return
	}
	if st.users[uid] == nil {
		sendError(w, 404, "unknown account")
		return
	}
	uk := st.userKeys[uid]
	if uk == nil || uk.PublicKey == "" {
		sendError(w, 409, "that account has no key")
		return
	}
	if existing := memberOf(t, uid); existing != nil {
		existing.Role = role
		existing.WrappedKey = body.WrappedKey
	} else {
		acct := st.users[uid]
		t.Members = append(t.Members, teamMember{
			UserID: uid, Email: acct.Email, Role: role,
			WrappedKey: body.WrappedKey, JoinedAt: nowISO(),
		})
	}
	persistTeamID(wsID)
	auditLog(wsID, userId, "member.add", uid, clientIP(r), t.KeyVersion, "server")
	log.Printf("[%s] %s added %s (%s) to workspace %s", nowISO(), account.Email, st.users[uid].Email, uid, wsID)
	sendJSON(w, 200, map[string]any{"ok": true})
}

func handleSetMemberRole(w http.ResponseWriter, r *http.Request, wsID, uid string, account *user, userId string) {
	var body struct {
		Role string `json:"role"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	role := body.Role
	if role != "admin" && role != "member" {
		sendError(w, 400, "invalid role: must be admin or member")
		return
	}
	if !teamMutateAllowed(r) {
		sendError(w, 429, "too many requests")
		return
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	t := st.teams[wsID]
	if t == nil {
		sendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		sendError(w, 403, "not a member")
		return
	}
	if !isOwner(m) {
		sendError(w, 403, "only the owner can change roles")
		return
	}
	tm := memberOf(t, uid)
	if tm == nil {
		sendError(w, 404, "not a member of this workspace")
		return
	}
	if tm.Role == "owner" {
		sendError(w, 400, "cannot change the owner's role through this endpoint")
		return
	}
	tm.Role = role
	persistTeamID(wsID)
	auditLog(wsID, userId, "member.role", uid+":"+role, clientIP(r), t.KeyVersion, "server")
	log.Printf("[%s] %s set role of %s to %s in workspace %s", nowISO(), account.Email, uid, role, wsID)
	sendJSON(w, 200, map[string]any{"ok": true})
}

func handleRemoveMember(w http.ResponseWriter, r *http.Request, wsID, uid string, account *user, userId string) {
	if !teamMutateAllowed(r) {
		sendError(w, 429, "too many requests")
		return
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	t := st.teams[wsID]
	if t == nil {
		sendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		sendError(w, 403, "not a member")
		return
	}
	tm := memberOf(t, uid)
	if tm == nil {
		sendError(w, 404, "not a member of this workspace")
		return
	}
	if uid == userId {
		// Leaving workspace.
		if tm.Role == "owner" {
			sendError(w, 400, "owner cannot leave; delete the workspace instead")
			return
		}
	} else {
		// Removing someone else.
		if !isAdminOrOwner(m) {
			sendError(w, 403, "owner or admin required")
			return
		}
		if tm.Role == "owner" && !isOwner(m) {
			sendError(w, 403, "only the owner can remove the owner")
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
	auditLog(wsID, userId, "member.remove", uid, clientIP(r), t.KeyVersion, "server")
	log.Printf("[%s] %s removed %s from workspace %s", nowISO(), account.Email, uid, wsID)
	sendJSON(w, 200, map[string]any{"ok": true})
}

// ---------- Key rotation ----------

func handleKeyRotate(w http.ResponseWriter, r *http.Request, wsID string, account *user, userId string) {
	var body struct {
		Members []struct {
			UserID     string `json:"userId"`
			Role       string `json:"role"`
			WrappedKey string `json:"wrappedKey"`
		} `json:"members"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	if len(body.Members) == 0 {
		sendError(w, 400, "members list cannot be empty")
		return
	}
	if !teamMutateAllowed(r) {
		sendError(w, 429, "too many requests")
		return
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	t := st.teams[wsID]
	if t == nil {
		sendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		sendError(w, 403, "not a member")
		return
	}
	if !isAdminOrOwner(m) {
		sendError(w, 403, "owner or admin required")
		return
	}
	newMembers := []teamMember{}
	actorIncluded := false
	for _, item := range body.Members {
		uid := item.UserID
		acct := st.users[uid]
		if acct == nil {
			sendError(w, 400, "unknown user: "+uid)
			return
		}
		role := item.Role
		if !validRole(role) {
			sendError(w, 400, "invalid role for user "+uid)
			return
		}
		if strings.TrimSpace(item.WrappedKey) == "" {
			sendError(w, 400, "missing wrappedKey for user "+uid)
			return
		}
		uk := st.userKeys[uid]
		if uk == nil || uk.PublicKey == "" {
			sendError(w, 400, "user "+uid+" has no key")
			return
		}
		joinedAt := nowISO()
		if old := memberOf(t, uid); old != nil {
			joinedAt = old.JoinedAt
		}
		newMembers = append(newMembers, teamMember{
			UserID: uid, Email: acct.Email, Role: role,
			WrappedKey: item.WrappedKey, JoinedAt: joinedAt,
		})
		if uid == userId {
			actorIncluded = true
		}
	}
	if !actorIncluded {
		sendError(w, 400, "you must remain a member after rotation")
		return
	}
	t.Members = newMembers
	t.KeyVersion++
	persistTeamID(wsID)
	auditLog(wsID, userId, "workspace.key-rotate", strconv.Itoa(t.KeyVersion), clientIP(r), t.KeyVersion, "server")
	log.Printf("[%s] %s rotated key for workspace %s (v%d)", nowISO(), account.Email, wsID, t.KeyVersion)
	sendJSON(w, 200, map[string]any{"keyVersion": t.KeyVersion})
}

// ---------- Sync ----------

func handleTeamSyncGet(w http.ResponseWriter, wsID, userId string) {
	st.mu.RLock()
	t := st.teams[wsID]
	if t == nil {
		st.mu.RUnlock()
		sendError(w, 404, "unknown workspace")
		return
	}
	if memberOf(t, userId) == nil {
		st.mu.RUnlock()
		sendError(w, 403, "not a member")
		return
	}
	b := st.teamBlobs[wsID]
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

func handleTeamSyncPost(w http.ResponseWriter, r *http.Request, wsID string, account *user, userId string) {
	var body struct {
		Revision int `json:"revision"`
		Blob     string `json:"blob"`
		Actions  []struct {
			Action string `json:"action"`
			Target string `json:"target"`
		} `json:"actions"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	if body.Revision < 0 {
		sendError(w, 400, "invalid revision")
		return
	}
	decodedLen := base64.StdEncoding.DecodedLen(len(body.Blob))
	if decodedLen > blobLimitBytes {
		sendError(w, 413, "blob too large")
		return
	}
	if len(body.Actions) > 200 {
		sendError(w, 400, "too many actions")
		return
	}
	if !teamSyncRL.allow("ws-sync:"+clientIP(r), rateSyncLimit, rateSyncWindow) {
		sendError(w, 429, "too many requests")
		return
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	t := st.teams[wsID]
	if t == nil {
		sendError(w, 404, "unknown workspace")
		return
	}
	if memberOf(t, userId) == nil {
		sendError(w, 403, "not a member")
		return
	}
	current := st.teamBlobs[wsID]
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
	st.teamBlobs[wsID] = next
	persistTeamBlobID(wsID)
	ip := clientIP(r)
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
	log.Printf("[%s] %s synced workspace %s -> revision %d", nowISO(), account.Email, wsID, next.Revision)
	sendJSON(w, 200, map[string]any{"revision": next.Revision})
}

// ---------- Audit ----------

func handleAuditList(w http.ResponseWriter, r *http.Request, wsID, userId string) {
	q := auditQuery{Limit: 100, Offset: 0}
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

	st.mu.RLock()
	t := st.teams[wsID]
	if t == nil {
		st.mu.RUnlock()
		sendError(w, 404, "unknown workspace")
		return
	}
	m := memberOf(t, userId)
	if m == nil {
		st.mu.RUnlock()
		sendError(w, 403, "not a member")
		return
	}
	if !isAdminOrOwner(m) {
		st.mu.RUnlock()
		sendError(w, 403, "owner or admin required")
		return
	}
	emails := map[string]string{}
	for id, u := range st.users {
		if u != nil {
			emails[id] = u.Email
		}
	}
	st.mu.RUnlock()

	events, err := store.AuditEvents(wsID, q)
	if err != nil {
		log.Printf("error reading audit events for workspace %s: %v", wsID, err)
		sendError(w, 500, "storage error")
		return
	}
	out := make([]map[string]any, 0, len(events))
	for _, e := range events {
		actorEmail := emails[e.ActorID]
		out = append(out, map[string]any{
			"id":         e.ID,
			"workspaceId": e.WorkspaceID,
			"actorId":    e.ActorID,
			"actorEmail": actorEmail,
			"action":     e.Action,
			"target":     e.Target,
			"revision":   e.Revision,
			"ip":         e.IP,
			"source":     e.Source,
			"createdAt":  e.CreatedAt,
		})
	}
	sendJSON(w, 200, map[string]any{"events": out})
}