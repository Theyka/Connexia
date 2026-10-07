// Package version exposes the latest Connexia release to clients.
//
// The app polls GET /api/version instead of talking to GitHub directly. We
// fetch the release server-side and cache it, which keeps every client well
// inside GitHub's unauthenticated rate limit and gives us a single place to
// point at a mirrored release if needed.
package version

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"connexia/syncserver/internal/config"
	"connexia/syncserver/internal/httpx"
)

// Release is the normalized payload returned by the endpoint.
type Release struct {
	Version     string            `json:"version"`
	Tag         string            `json:"tag"`
	URL         string            `json:"url"`
	Notes       string            `json:"notes"`
	PublishedAt string            `json:"publishedAt,omitempty"`
	Assets      map[string]string `json:"assets"`
}

type githubRelease struct {
	TagName     string `json:"tag_name"`
	HTMLURL     string `json:"html_url"`
	Body        string `json:"body"`
	PublishedAt string `json:"published_at"`
	Assets      []struct {
		Name               string `json:"name"`
		BrowserDownloadURL string `json:"browser_download_url"`
	} `json:"assets"`
}

type cache struct {
	mu      sync.Mutex
	release *Release
	fetched time.Time
}

var releases = &cache{}

// HandleLatest serves the cached latest release. Public, no auth required.
func HandleLatest(w http.ResponseWriter, _ *http.Request) {
	rel, err := latest()
	if err != nil {
		httpx.SendError(w, 503, "latest release unavailable")
		return
	}
	httpx.SendJSON(w, 200, rel)
}

func latest() (*Release, error) {
	releases.mu.Lock()
	if releases.release != nil &&
		time.Since(releases.fetched) < config.UpdateCacheTTL {
		rel := releases.release
		releases.mu.Unlock()
		return rel, nil
	}
	releases.mu.Unlock()

	rel, err := fetchAndParse()
	if err != nil {
		// Serve the last known good release rather than failing the client.
		releases.mu.Lock()
		defer releases.mu.Unlock()
		if releases.release != nil {
			return releases.release, nil
		}
		return nil, err
	}

	releases.mu.Lock()
	releases.release = rel
	releases.fetched = time.Now()
	releases.mu.Unlock()
	return rel, nil
}

func fetchAndParse() (*Release, error) {
	req, err := http.NewRequest(http.MethodGet, config.UpdateGitHubAPIURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "connexia-syncserver")
	if config.UpdateGitHubToken != "" {
		req.Header.Set("Authorization", "Bearer "+config.UpdateGitHubToken)
	}

	client := &http.Client{Timeout: 10 * time.Second}
	res, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("github returned %d", res.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	return parseGitHubRelease(body)
}

// parseGitHubRelease converts the GitHub API response into a Release. It is
// split out from the network call so it can be tested without a live request.
func parseGitHubRelease(body []byte) (*Release, error) {
	var raw githubRelease
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, err
	}
	if raw.TagName == "" {
		return nil, fmt.Errorf("release has no tag")
	}
	return &Release{
		Version:     strings.TrimPrefix(raw.TagName, "v"),
		Tag:         raw.TagName,
		URL:         raw.HTMLURL,
		Notes:       raw.Body,
		PublishedAt: raw.PublishedAt,
		Assets:      mapAssets(raw),
	}, nil
}

// mapAssets keys the download URLs by the platform the app asks for.
func mapAssets(raw githubRelease) map[string]string {
	assets := map[string]string{}
	for _, a := range raw.Assets {
		name := strings.ToLower(a.Name)
		switch {
		case strings.HasSuffix(name, ".exe") && strings.Contains(name, "setup"):
			assets["windows"] = a.BrowserDownloadURL
		case strings.HasSuffix(name, ".dmg"):
			assets["macos"] = a.BrowserDownloadURL
		case strings.HasSuffix(name, ".tar.gz"):
			assets["linux"] = a.BrowserDownloadURL
		case strings.HasSuffix(name, ".apk"):
			assets["android"] = a.BrowserDownloadURL
		}
	}
	return assets
}
