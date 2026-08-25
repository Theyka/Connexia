package main

import (
	"html/template"
	"log"
	"net/http"
	"strings"
)

// pageData carries the shared layout context (current nav item, server name).
type pageData struct {
	Current string
	Name    string
}

// homeData adds live server stats for the landing page.
type homeData struct {
	pageData
	Stats dashboardStats
}

var sitePages = template.Must(template.ParseFS(templateFS,
	"templates/partials.html",
	"templates/home.html",
	"templates/docs.html",
	"templates/dashboard.html",
	"templates/login.html",
	"templates/register.html",
))

func renderPage(w http.ResponseWriter, name string, data any) {
	// HTML pages are small and change with every release; never cache them
	// so users always get the latest markup.
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := sitePages.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("render %s: %v", name, err)
		sendError(w, 500, "internal error")
	}
}

func serveHome(w http.ResponseWriter, r *http.Request) {
	renderPage(w, "home", homeData{
		pageData: pageData{Current: "home", Name: serverName},
		Stats:    collectStats(),
	})
}

func serveDocs(w http.ResponseWriter, r *http.Request) {
	renderPage(w, "docs", pageData{Current: "docs", Name: serverName})
}

func serveDashboard(w http.ResponseWriter, r *http.Request) {
	renderPage(w, "dashboard", pageData{Current: "dashboard", Name: serverName})
}

func serveLogin(w http.ResponseWriter, r *http.Request) {
	renderPage(w, "login", pageData{Current: "login", Name: serverName})
}

func serveRegister(w http.ResponseWriter, r *http.Request) {
	renderPage(w, "register", pageData{Current: "register", Name: serverName})
}

// ---------- Static assets ----------

var (
	siteCSS = mustTemplateFile("templates/site.css")
	siteJS  = mustTemplateFile("templates/site.js")
)

func serveAsset(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	switch strings.TrimPrefix(r.URL.Path, "/assets/") {
	case "site.css":
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
		_, _ = w.Write([]byte(siteCSS))
	case "site.js":
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		_, _ = w.Write([]byte(siteJS))
	default:
		sendError(w, 404, "not found")
	}
}
