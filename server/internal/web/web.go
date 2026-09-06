// Package web serves the HTML pages: the marketing site, the auth pages,
// the app dashboard and the admin view. Everything is embedded in the
// binary so the container has no runtime file dependency.
//
// Templates are split into shared components (templates/partials) and the
// pages themselves (templates/pages). /admin is protected by the admin
// *account*: on a fresh server (no admin yet) it shows a first-run
// registration form; afterwards it requires signing in as the admin.
package web

import (
	"embed"
	"html/template"
	"log"
	"net/http"
	"strings"
	texttemplate "text/template"

	"connexia/syncserver/internal/admin"
	"connexia/syncserver/internal/httpx"
)

//go:embed templates/*
var templateFS embed.FS

// pageData carries the shared layout context (page title, nav item, server
// name).
type pageData struct {
	Current string
	Name    string
	Title   string
	NoIndex bool
}

// homeData adds live server stats for the landing page.
type homeData struct {
	pageData
	Stats admin.Stats
}

// authData adds the left-panel copy for the login/register pages.
type authData struct {
	pageData
	Headline string
	Sub      string
	Features []string
}

var sitePages = template.Must(template.ParseFS(templateFS,
	"templates/partials/*.html",
	"templates/pages/*.html",
))

// robots.txt and sitemap.xml are plain text, not HTML pages.
var (
	robotsTxt   = mustAssetFile("templates/robots.txt")
	sitemapTmpl = texttemplate.Must(texttemplate.New("sitemap").Parse(mustAssetFile("templates/sitemap.xml")))
)

func mustAssetFile(path string) string {
	b, err := templateFS.ReadFile(path)
	if err != nil {
		panic(err)
	}
	return string(b)
}

func renderPage(w http.ResponseWriter, name string, data any) {
	// HTML pages are small and change with every release; never cache them
	// so users always get the latest markup.
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := sitePages.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("render %s: %v", name, err)
		httpx.SendError(w, 500, "internal error")
	}
}

// ---------- Page handlers ----------

func HandleHome(w http.ResponseWriter, r *http.Request) {
	renderPage(w, "home", homeData{
		pageData: pageData{Current: "home", Name: admin.ServerName, Title: "Connexia — Manage Every Server From One Place"},
		Stats:    admin.CollectStats(),
	})
}

func HandleDocs(w http.ResponseWriter, r *http.Request) {
	renderPage(w, "docs", pageData{Current: "docs", Name: admin.ServerName, Title: "Documentation — Connexia"})
}

func HandleDashboard(w http.ResponseWriter, r *http.Request) {
	renderPage(w, "dashboard", pageData{Current: "dashboard", Name: admin.ServerName, Title: "Connexia", NoIndex: true})
}

func HandleLogin(w http.ResponseWriter, r *http.Request) {
	renderPage(w, "login", authData{
		pageData: pageData{Current: "login", Name: admin.ServerName, Title: "Sign in — Connexia", NoIndex: true},
		Headline: "Back in control of every server.",
		Sub:      "Sign in once, and your hosts, keys and snippets are available on every device you own.",
		Features: []string{
			"Zero-knowledge, end-to-end encrypted sync",
			"Windows, Linux, macOS, iOS and Android",
			"Optional two-factor authentication",
		},
	})
}

func HandleRegister(w http.ResponseWriter, r *http.Request) {
	renderPage(w, "register", authData{
		pageData: pageData{Current: "register", Name: admin.ServerName, Title: "Create account — Connexia", NoIndex: true},
		Headline: "One account, every machine.",
		Sub:      "Create a free account and your hosts, keys and snippets follow you to every device.",
		Features: []string{
			"Encrypted before it ever leaves your device",
			"No credit card, no limits",
			"Delete your account anytime",
		},
	})
}

func HandleAccount(w http.ResponseWriter, r *http.Request) {
	renderPage(w, "account", pageData{Current: "account", Name: admin.ServerName, Title: "My account — Connexia", NoIndex: true})
}

func HandleAdmin(w http.ResponseWriter, r *http.Request) {
	renderPage(w, "admin", pageData{Current: "admin", Name: admin.ServerName, Title: "Connexia — Admin", NoIndex: true})
}

func HandleRobots(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte(robotsTxt))
}

func HandleSitemap(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/xml; charset=utf-8")
	_ = sitemapTmpl.Execute(w, map[string]string{"Host": r.Host})
}

// ---------- Static assets ----------

// The site favicon: the Connexia logo tile (dark rounded square with a
// teal ">_" glyph), matching the app icons on every platform.
const faviconSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 192 192"><rect width="192" height="192" rx="31" fill="#0B0C10"/><path d="M53 63 82 96 53 118" fill="none" stroke="#3DDC97" stroke-width="14" stroke-linecap="round" stroke-linejoin="round"/><path d="M97 129h43" fill="none" stroke="#3DDC97" stroke-width="12" stroke-linecap="round"/></svg>`

var (
	siteCSS     = mustAssetFile("templates/site.css")
	siteJS      = mustAssetFile("templates/site.js")
	tailwindJS  = mustAssetFile("templates/tailwind.js")
	accountCSS  = mustAssetFile("templates/account.css")
	adminCSS    = mustAssetFile("templates/admin.css")
	loginJS     = mustAssetFile("templates/login.js")
	registerJS  = mustAssetFile("templates/register.js")
	accountJS   = mustAssetFile("templates/account.js")
	adminPageJS = mustAssetFile("templates/admin.js")
	dashJS      = mustAssetFile("templates/dashboard.js")
)

func HandleAsset(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	switch strings.TrimPrefix(r.URL.Path, "/assets/") {
	case "favicon.svg":
		w.Header().Set("Content-Type", "image/svg+xml")
		_, _ = w.Write([]byte(faviconSVG))
	case "site.css":
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
		_, _ = w.Write([]byte(siteCSS))
	case "account.css":
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
		_, _ = w.Write([]byte(accountCSS))
	case "admin.css":
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
		_, _ = w.Write([]byte(adminCSS))
	case "site.js":
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		_, _ = w.Write([]byte(siteJS))
	case "login.js":
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		_, _ = w.Write([]byte(loginJS))
	case "register.js":
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		_, _ = w.Write([]byte(registerJS))
	case "account.js":
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		_, _ = w.Write([]byte(accountJS))
	case "admin.js":
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		_, _ = w.Write([]byte(adminPageJS))
	case "dashboard.js":
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		_, _ = w.Write([]byte(dashJS))
	case "tailwind.js":
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		_, _ = w.Write([]byte(tailwindJS))
	default:
		httpx.SendError(w, 404, "not found")
	}
}
