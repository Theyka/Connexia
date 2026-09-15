package main

import (
	"fmt"
	"log"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"connexia/syncserver/internal/admin"
	"connexia/syncserver/internal/auth"
	"connexia/syncserver/internal/config"
	"connexia/syncserver/internal/cryptoutil"
	"connexia/syncserver/internal/httpx"
	"connexia/syncserver/internal/ratelimit"
	"connexia/syncserver/internal/relay"
	"connexia/syncserver/internal/state"
	"connexia/syncserver/internal/store"
	"connexia/syncserver/internal/syncapi"
	"connexia/syncserver/internal/teams"
	"connexia/syncserver/internal/web"
)

func main() {
	config.UsersFile = filepath.Join(config.DataDir, "users.json")
	config.BlobsDir = filepath.Join(config.DataDir, "blobs")

	var err error
	store.DB, err = store.Open()
	if err != nil {
		log.Fatalf("failed to open storage: %v", err)
	}
	defer store.DB.Close()
	log.Printf("Storage backend: %s", store.BackendName())

	store.MigrateFromJSON(store.DB, config.UsersFile, config.BlobsDir)

	if err := state.Load(); err != nil {
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

	rl := ratelimit.New()

	mux.HandleFunc("/api/health", withCORS(func(w http.ResponseWriter, r *http.Request) {
		httpx.SendJSON(w, 200, map[string]any{"ok": true, "time": cryptoutil.NowISO()})
	}))
	mux.HandleFunc("/api/register", withCORS(ratelimit.WithRateLimit(rl, "register", config.RateRegisterLimit, config.RateRegisterWindow, auth.HandleRegister)))
	mux.HandleFunc("/api/login", withCORS(ratelimit.WithRateLimit(rl, "login", config.RateLoginLimit, config.RateLoginWindow, auth.HandleLogin)))
	mux.HandleFunc("/api/verify-email", withCORS(ratelimit.WithRateLimit(rl, "verify", config.RateCodeLimit, config.RateCodeWindow, auth.HandleVerifyEmail)))
	mux.HandleFunc("/api/resend-verification", withCORS(ratelimit.WithRateLimit(rl, "resend", config.RateResendLimit, config.RateResendWindow, auth.HandleResendVerification)))
	mux.HandleFunc("/api/login/2fa", withCORS(ratelimit.WithRateLimit(rl, "login2fa", config.RateCodeLimit, config.RateCodeWindow, auth.HandleLogin2FA)))
	mux.HandleFunc("/api/public/stats", withCORS(ratelimit.WithRateLimit(rl, "stats", config.RateSyncLimit, config.RateSyncWindow, admin.HandlePublicStats)))
	mux.HandleFunc("/api/setup/status", withCORS(ratelimit.WithRateLimit(rl, "setup", config.RateSyncLimit, config.RateSyncWindow, admin.HandleSetupStatus)))
	mux.HandleFunc("/api/admin/users", withCORS(admin.HandleUsers))
	mux.HandleFunc("/api/admin/users/delete", withCORS(admin.HandleDeleteUser))
	mux.HandleFunc("/api/admin/users/role", withCORS(admin.HandleSetRole))
	mux.HandleFunc("/api/admin/settings", withCORS(admin.HandleSettings))
	mux.HandleFunc("/api/relay", ratelimit.WithRateLimit(rl, "relay", config.RateRelayLimit, config.RateRelayWindow, relay.Handle))
	mux.HandleFunc("/admin", withCORS(web.HandleAdmin))
	mux.HandleFunc("/robots.txt", withCORS(web.HandleRobots))
	mux.HandleFunc("/sitemap.xml", withCORS(web.HandleSitemap))
	mux.HandleFunc("/assets/", withCORS(web.HandleAsset))

	mux.HandleFunc("/docs", withCORS(web.HandleDocs))
	mux.HandleFunc("/dashboard", withCORS(web.HandleDashboard))
	mux.HandleFunc("/login", withCORS(web.HandleLogin))
	mux.HandleFunc("/register", withCORS(web.HandleRegister))
	mux.HandleFunc("/account", withCORS(web.HandleAccount))

	mux.HandleFunc("/", withCORS(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/":
			web.HandleHome(w, r)
			return
		}
		teamPath := r.URL.Path == "/api/me/key" ||
			r.URL.Path == "/api/workspaces" ||
			strings.HasPrefix(r.URL.Path, "/api/workspaces/")
		switch r.URL.Path {
		case "/api/account", "/api/enable-2fa", "/api/confirm-2fa", "/api/disable-2fa",
			"/api/account/delete", "/api/sync":
		default:
			if !teamPath {
				httpx.SendError(w, 404, "not found")
				return
			}
		}
		userId := state.Auth(r)
		if userId == "" {
			httpx.SendError(w, 401, "missing or invalid session token")
			return
		}
		state.St.Mu.RLock()
		account := state.St.Users[userId]
		state.St.Mu.RUnlock()
		if account == nil {
			httpx.SendError(w, 401, "unknown account")
			return
		}
		if account.EmailVerified != nil && !*account.EmailVerified {
			httpx.SendError(w, 403, "email not verified")
			return
		}
		if teamPath {
			teams.HandleRequest(w, r, account, userId)
			return
		}
		switch r.URL.Path {
		case "/api/account":
			auth.HandleAccount(w, account)
		case "/api/account/delete":
			auth.HandleDeleteAccount(w, userId)
		case "/api/enable-2fa":
			auth.HandleEnable2FA(w, account)
		case "/api/confirm-2fa":
			auth.HandleConfirm2FA(w, account, r)
		case "/api/disable-2fa":
			auth.HandleDisable2FA(w, account, r)
		case "/api/sync":
			if r.Method == http.MethodGet {
				syncapi.HandleGet(w, r, userId)
			} else if r.Method == http.MethodPost {
				if !rl.Allow("sync:"+ratelimit.ClientIP(r), config.RateSyncLimit, config.RateSyncWindow) {
					httpx.SendError(w, 429, "too many requests")
					return
				}
				syncapi.HandlePost(w, r, userId)
			} else {
				httpx.SendError(w, 404, "not found")
			}
		}
	}))

	addr := fmt.Sprintf(":%d", config.Port)
	log.Printf("Connexia sync server listening on http://0.0.0.0:%d", config.Port)
	log.Printf("Data directory: %s", config.DataDir)
	server := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	if err := server.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
