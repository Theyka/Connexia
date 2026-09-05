// Package state keeps the hot in-memory dataset (users, blobs, workspaces)
// and persists every mutation through the store package.
package state

import (
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"connexia/syncserver/internal/config"
	"connexia/syncserver/internal/cryptoutil"
	"connexia/syncserver/internal/model"
	"connexia/syncserver/internal/store"
)

// State is the whole hot dataset. Handlers must hold Mu (read or write)
// while touching the maps.
type State struct {
	Mu        sync.RWMutex
	Users     map[string]*model.User    // id -> user
	Blobs     map[string]*model.Blob    // id -> blob
	Teams     map[string]*model.Team    // workspace id -> team
	TeamBlobs map[string]*model.Blob    // workspace id -> blob
	UserKeys  map[string]*model.UserKey // user id -> keypair
	// RequireEmailVerification is a server-wide setting (default true)
	// controlling whether new registrations must verify their email.
	RequireEmailVerification bool
}

// St is the process-wide state instance.
var St = &State{
	Users:     map[string]*model.User{},
	Blobs:     map[string]*model.Blob{},
	Teams:     map[string]*model.Team{},
	TeamBlobs: map[string]*model.Blob{},
	UserKeys:  map[string]*model.UserKey{},
}

// Load reads everything from the store into memory and normalizes legacy
// rows (accounts without the email-verification flag count as verified).
func Load() error {
	users, blobs, err := store.DB.LoadAll()
	if err != nil {
		return err
	}
	teams, teamBlobs, err := store.DB.LoadTeams()
	if err != nil {
		return err
	}
	userKeys, err := store.DB.LoadUserKeys()
	if err != nil {
		return err
	}
	St.Mu.Lock()
	defer St.Mu.Unlock()
	St.Users = users
	St.Blobs = blobs
	St.Teams = teams
	St.TeamBlobs = teamBlobs
	St.UserKeys = userKeys
	St.RequireEmailVerification = true
	if v, ok, err := store.DB.GetSetting("require_email_verification"); err == nil && ok && v == "false" {
		St.RequireEmailVerification = false
	}
	if St.Users == nil {
		St.Users = map[string]*model.User{}
	}
	if St.Blobs == nil {
		St.Blobs = map[string]*model.Blob{}
	}
	if St.Teams == nil {
		St.Teams = map[string]*model.Team{}
	}
	if St.TeamBlobs == nil {
		St.TeamBlobs = map[string]*model.Blob{}
	}
	if St.UserKeys == nil {
		St.UserKeys = map[string]*model.UserKey{}
	}
	for id, account := range St.Users {
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
		if St.Blobs[id] == nil {
			St.Blobs[id] = &model.Blob{Revision: 0}
		}
	}
	for id := range St.Teams {
		if St.TeamBlobs[id] == nil {
			St.TeamBlobs[id] = &model.Blob{Revision: 0}
		}
	}
	return nil
}

// PersistUserID writes one user to the store. Callers must hold St.Mu
// (write lock).
func PersistUserID(id string) {
	if err := store.DB.SaveUser(id, St.Users[id]); err != nil {
		log.Printf("error saving user %s: %v", id, err)
	}
}

// PersistUser resolves the id for an account already in the map.
func PersistUser(account *model.User) {
	id := AccountIDOf(account)
	if id == "" {
		log.Printf("error persisting user: account not found in map")
		return
	}
	PersistUserID(id)
}

// PersistBlobID writes one blob to the store. Callers must hold St.Mu
// (write lock).
func PersistBlobID(id string) {
	if err := store.DB.SaveBlob(id, St.Blobs[id]); err != nil {
		log.Printf("error saving blob %s: %v", id, err)
	}
}

// AccountIDOf looks up the id an account is stored under.
func AccountIDOf(account *model.User) string {
	for id, a := range St.Users {
		if a == account {
			return id
		}
	}
	return ""
}

// IssueSession mints a session token for the account, stores it and prunes
// expired sessions. Callers must hold St.Mu (write lock).
func IssueSession(account *model.User) string {
	token := cryptoutil.RandomHex(32)
	expires := time.Now().Add(config.SessionTTL).UTC().Format("2006-01-02T15:04:05.000Z")
	account.Sessions[token] = expires
	// Keep the session map small.
	for t, e := range account.Sessions {
		if time.Now().After(cryptoutil.ParseISO(e)) {
			delete(account.Sessions, t)
		}
	}
	return token
}

// Auth extracts the bearer-token session and returns the account id, or ""
// when no session is valid.
func Auth(r *http.Request) string {
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, "Bearer ") {
		return ""
	}
	token := strings.TrimPrefix(header, "Bearer ")
	now := time.Now()
	St.Mu.RLock()
	defer St.Mu.RUnlock()
	for id, account := range St.Users {
		if account == nil {
			continue
		}
		if expires, ok := account.Sessions[token]; ok && now.Before(cryptoutil.ParseISO(expires)) {
			return id
		}
	}
	return ""
}
