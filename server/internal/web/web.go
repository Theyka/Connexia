package web

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"html/template"
	"io"
	"io/fs"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	texttemplate "text/template"

	"connexia/syncserver/internal/admin"
	"connexia/syncserver/internal/httpx"
)

//go:embed templates
var templateFS embed.FS

//go:embed static
var staticRoot embed.FS

var staticFS = func() fs.FS {
	sub, err := fs.Sub(staticRoot, "static")
	if err != nil {
		panic(err)
	}
	return sub
}()

type pageData struct {
	Current string
	Name    string
	Title   string
	NoIndex bool
}

type homeData struct {
	pageData
	Stats admin.Stats
}

type authData struct {
	pageData
	Headline string
	Sub      string
	Features []string
}

var templateFuncs = template.FuncMap{
	"icon": icon,
}

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

	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := sitePages.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("render %s: %v", name, err)
		httpx.SendError(w, 500, "internal error")
	}
}

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

var etags sync.Map

func etagOf(name string) (string, []byte, error) {
	data, err := fs.ReadFile(staticFS, name)
	if err != nil {
		return "", nil, err
	}
	if tag, ok := etags.Load(name); ok {
		return tag.(string), data, nil
	}
	sum := sha256.Sum256(data)
	tag := `"` + hex.EncodeToString(sum[:8]) + `"`
	etags.Store(name, tag)
	return tag, data, nil
}

func HandleAsset(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/assets/")
	if strings.HasSuffix(name, ".wasm") {
		serveCompressed(w, r, name)
		return
	}
	info, err := fs.Stat(staticFS, name)
	if err != nil || info.IsDir() {
		httpx.SendError(w, 404, "not found")
		return
	}
	if strings.HasPrefix(name, "fonts/") {
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		http.ServeFileFS(w, r, staticFS, name)
		return
	}
	tag, _, err := etagOf(name)
	if err != nil {
		httpx.SendError(w, 404, "not found")
		return
	}
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("ETag", tag)
	http.ServeFileFS(w, r, staticFS, name)
}

func serveCompressed(w http.ResponseWriter, r *http.Request, name string) {
	tag, data, err := etagOf(name + ".gz")
	if err != nil {
		httpx.SendError(w, 404, "not found")
		return
	}
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("ETag", tag)
	w.Header().Set("Vary", "Accept-Encoding")
	w.Header().Set("Content-Type", "application/wasm")
	if r.Header.Get("If-None-Match") == tag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Set("Content-Length", strconv.Itoa(len(data)))
		_, _ = w.Write(data)
		return
	}
	reader, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		httpx.SendError(w, 500, "internal error")
		return
	}
	_, _ = io.Copy(w, reader)
}
