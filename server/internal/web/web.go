// Package web serves the HTML pages: the marketing site, the auth pages,
// the app dashboard and the admin view. Everything is embedded in the
// binary so the container has no runtime file dependency.
//
// Layout:
//
//	templates/pages     one HTML template per page
//	templates/partials  shared components (head, header, footer, brand, ...)
//	templates/seo       robots.txt and the sitemap template
//	static/css          stylesheets              -> /assets/css/...
//	static/js           page scripts             -> /assets/js/...
//	static/img          favicon and icon sprite  -> /assets/img/...
//
// /admin is protected by the admin *account*: on a fresh server (no admin
// yet) it shows a first-run registration form; afterwards it requires
// signing in as the admin.
package web

import (
	"embed"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"strings"
	texttemplate "text/template"

	"connexia/syncserver/internal/admin"
	"connexia/syncserver/internal/httpx"
)

//go:embed templates
var templateFS embed.FS

//go:embed static
var staticRoot embed.FS

// staticFS is the static/ directory, served under /assets/.
var staticFS = func() fs.FS {
	sub, err := fs.Sub(staticRoot, "static")
	if err != nil {
		panic(err)
	}
	return sub
}()

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

// templateFuncs are available in every page template.
var templateFuncs = template.FuncMap{
	"icon": icon,
}

// icon renders a decorative SVG that references a symbol in
// static/img/icons.svg, e.g. {{icon "server"}} or {{icon "linux" "ico-fill"}}.
func icon(name string, classes ...string) template.HTML {
	class := strings.Join(append([]string{"ico"}, classes...), " ")
	return template.HTML(`<svg class="` + template.HTMLEscapeString(class) +
		`" aria-hidden="true"><use href="/assets/img/icons.svg#i-` +
		template.HTMLEscapeString(name) + `"/></svg>`)
}

var sitePages = template.Must(template.New("site").Funcs(templateFuncs).ParseFS(templateFS,
	"templates/partials/*.html",
	"templates/pages/*.html",
))

// robots.txt and sitemap.xml are plain text, not HTML pages.
var (
	robotsTxt   = mustTemplateFile("templates/seo/robots.txt")
	sitemapTmpl = texttemplate.Must(texttemplate.New("sitemap").Parse(mustTemplateFile("templates/seo/sitemap.xml")))
)

func mustTemplateFile(path string) string {
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

// HandleAsset serves files from static/ under /assets/ (CSS, JS, images).
// Directories and unknown paths are a 404.
func HandleAsset(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/assets/")
	info, err := fs.Stat(staticFS, name)
	if err != nil || info.IsDir() {
		httpx.SendError(w, 404, "not found")
		return
	}
	// Assets change with every release; never cache them so users always
	// get the files that match the current markup.
	w.Header().Set("Cache-Control", "no-store")
	http.ServeFileFS(w, r, staticFS, name)
}
