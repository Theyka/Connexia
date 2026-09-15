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

type State struct {
	Mu        sync.RWMutex
	Users     map[string]*model.User
	Blobs     map[string]*model.Blob
	Teams     map[string]*model.Team
	TeamBlobs map[string]*model.Blob
	UserKeys  map[string]*model.UserKey

	RequireEmailVerification bool
	WebSSHEnabled            bool
	WebSSHAllowPrivate       bool
}

var St = &State{
	Users:     map[string]*model.User{},
	Blobs:     map[string]*model.Blob{},
	Teams:     map[string]*model.Team{},
	TeamBlobs: map[string]*model.Blob{},
	UserKeys:  map[string]*model.UserKey{},
}

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
	St.WebSSHEnabled = true
	if v, ok, err := store.DB.GetSetting("web_ssh_enabled"); err == nil && ok && v == "false" {
		St.WebSSHEnabled = false
	}
	St.WebSSHAllowPrivate = false
	if v, ok, err := store.DB.GetSetting("web_ssh_allow_private"); err == nil && ok && v == "true" {
		St.WebSSHAllowPrivate = true
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

func PersistUserID(id string) {
	if err := store.DB.SaveUser(id, St.Users[id]); err != nil {
		log.Printf("error saving user %s: %v", id, err)
	}
}

func PersistUser(account *model.User) {
	id := AccountIDOf(account)
	if id == "" {
		log.Printf("error persisting user: account not found in map")
		return
	}
	PersistUserID(id)
}

func PersistBlobID(id string) {
	if err := store.DB.SaveBlob(id, St.Blobs[id]); err != nil {
		log.Printf("error saving blob %s: %v", id, err)
	}
}

func AccountIDOf(account *model.User) string {
	for id, a := range St.Users {
		if a == account {
			return id
		}
	}
	return ""
}

func IssueSession(account *model.User) string {
	token := cryptoutil.RandomHex(32)
	expires := time.Now().Add(config.SessionTTL).UTC().Format("2006-01-02T15:04:05.000Z")
	account.Sessions[token] = expires

	for t, e := range account.Sessions {
		if time.Now().After(cryptoutil.ParseISO(e)) {
			delete(account.Sessions, t)
		}
	}
	return token
}

func Auth(r *http.Request) string {
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, "Bearer ") {
		return ""
	}
	return AuthToken(strings.TrimPrefix(header, "Bearer "))
}

func WebSSH() (enabled, allowPrivate bool) {
	St.Mu.RLock()
	defer St.Mu.RUnlock()
	return St.WebSSHEnabled, St.WebSSHAllowPrivate
}

func AuthToken(token string) string {
	if token == "" {
		return ""
	}
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
