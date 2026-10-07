package version

import "testing"

func TestParseGitHubRelease(t *testing.T) {
	body := []byte(`{
		"tag_name": "v0.4.3",
		"html_url": "https://github.com/Theyka/Connexia/releases/tag/v0.4.3",
		"body": "notes here",
		"published_at": "2026-10-01T12:00:00Z",
		"assets": [
			{"name": "connexia-setup.exe", "browser_download_url": "https://x/setup.exe"},
			{"name": "connexia-macos-arm64.dmg", "browser_download_url": "https://x/app.dmg"},
			{"name": "connexia-linux-x64.tar.gz", "browser_download_url": "https://x/app.tar.gz"},
			{"name": "app-release.apk", "browser_download_url": "https://x/app.apk"},
			{"name": "connexia-server-linux-x64", "browser_download_url": "https://x/server"},
			{"name": "connexia-server-windows-x64.exe", "browser_download_url": "https://x/server.exe"}
		]
	}`)

	rel, err := parseGitHubRelease(body)
	if err != nil {
		t.Fatalf("parseGitHubRelease: %v", err)
	}
	if rel.Version != "0.4.3" {
		t.Errorf("version = %q, want 0.4.3", rel.Version)
	}
	if rel.Tag != "v0.4.3" {
		t.Errorf("tag = %q, want v0.4.3", rel.Tag)
	}
	if rel.Notes != "notes here" {
		t.Errorf("notes = %q", rel.Notes)
	}
	if rel.URL != "https://github.com/Theyka/Connexia/releases/tag/v0.4.3" {
		t.Errorf("url = %q", rel.URL)
	}

	cases := map[string]string{
		"windows": "https://x/setup.exe",
		"macos":   "https://x/app.dmg",
		"linux":   "https://x/app.tar.gz",
		"android": "https://x/app.apk",
	}
	for platform, want := range cases {
		if got := rel.Assets[platform]; got != want {
			t.Errorf("asset[%s] = %q, want %q", platform, got, want)
		}
	}

	// The server binaries must not be mistaken for desktop app downloads.
	for _, platform := range []string{"windows", "linux"} {
		if rel.Assets[platform] == "https://x/server" ||
			rel.Assets[platform] == "https://x/server.exe" {
			t.Errorf("asset[%s] picked up a server binary: %q", platform, rel.Assets[platform])
		}
	}
}

func TestParseGitHubReleaseRejectsMissingTag(t *testing.T) {
	if _, err := parseGitHubRelease([]byte(`{"html_url":"x"}`)); err == nil {
		t.Fatal("expected an error for a release without a tag")
	}
}

func TestParseGitHubReleaseInvalidJSON(t *testing.T) {
	if _, err := parseGitHubRelease([]byte(`not json`)); err == nil {
		t.Fatal("expected an error for invalid JSON")
	}
}
