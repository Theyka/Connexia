package main

import (
	"encoding/base64"
	"html/template"
	"net/http"
	"sort"
	"strings"
	"time"

	"crypto/subtle"
)

// Dashboard configuration.
//
// The web UI is served from the same binary: a public, SEO-friendly landing
// page at / (stats are rendered server-side so crawlers see them), an admin
// view at /admin (guarded by ADMIN_TOKEN) and robots.txt / sitemap.xml.
var (
	serverName    = envStr("SERVER_NAME", "Connexia Sync Server")
	adminToken    = envStr("ADMIN_TOKEN", "")
	serverVersion = "1.0.0"
	startTime     = time.Now()
)

// ---------- Stats ----------

type dashboardStats struct {
	Name       string
	Version    string
	Uptime     string
	Users      int
	Verified   int
	Snapshots  int
	BlobBytes  int64
	LastActive string
}

func collectStats() dashboardStats {
	st.mu.RLock()
	defer st.mu.RUnlock()
	var s dashboardStats
	for id, u := range st.users {
		if u == nil {
			continue
		}
		s.Users++
		if u.EmailVerified != nil && *u.EmailVerified {
			s.Verified++
		}
		if b := st.blobs[id]; b != nil && b.Blob != nil && *b.Blob != "" {
			s.Snapshots++
			s.BlobBytes += int64(base64.StdEncoding.DecodedLen(len(*b.Blob)))
			if b.UpdatedAt != nil && (s.LastActive == "" || *b.UpdatedAt > s.LastActive) {
				s.LastActive = *b.UpdatedAt
			}
		}
	}
	s.Name = serverName
	s.Version = serverVersion
	s.Uptime = formatDuration(time.Since(startTime))
	if s.LastActive != "" {
		s.LastActive = s.LastActive[:10] + " " + s.LastActive[11:19]
	}
	return s
}

func formatDuration(d time.Duration) string {
	d = d.Round(time.Second)
	h := d / time.Hour
	d -= h * time.Hour
	m := d / time.Minute
	d -= m * time.Minute
	sec := d / time.Second
	if h > 0 {
		return strings.TrimSpace(strings.Join([]string{
			formatInt(int(h), "h"), formatInt(int(m), "m"), formatInt(int(sec), "s"),
		}, " "))
	}
	if m > 0 {
		return strings.TrimSpace(strings.Join([]string{
			formatInt(int(m), "m"), formatInt(int(sec), "s"),
		}, " "))
	}
	return formatInt(int(sec), "s")
}

func formatInt(n int, suffix string) string {
	if n == 0 {
		return ""
	}
	return itoa(n) + suffix
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

// ---------- Handlers ----------

func handlePublicStats(w http.ResponseWriter, r *http.Request) {
	s := collectStats()
	sendJSON(w, 200, map[string]any{
		"name":        s.Name,
		"version":     s.Version,
		"uptime":      s.Uptime,
		"users":       s.Users,
		"verified":    s.Verified,
		"snapshots":   s.Snapshots,
		"blobBytes":   s.BlobBytes,
		"lastActive":  s.LastActive,
		"serverUrl":   r.Host,
	})
}

func adminAllowed(r *http.Request) bool {
	if adminToken == "" {
		return false
	}
	token := r.URL.Query().Get("token")
	if token == "" {
		h := r.Header.Get("Authorization")
		if strings.HasPrefix(h, "Bearer ") {
			token = strings.TrimPrefix(h, "Bearer ")
		}
	}
	return subtle.ConstantTimeCompare([]byte(token), []byte(adminToken)) == 1
}

func handleAdminUsers(w http.ResponseWriter, r *http.Request) {
	if !adminAllowed(r) {
		sendError(w, 401, "admin token required")
		return
	}
	st.mu.RLock()
	defer st.mu.RUnlock()
	users := []map[string]any{}
	for id, u := range st.users {
		if u == nil {
			continue
		}
		var blobBytes int64
		if b := st.blobs[id]; b != nil && b.Blob != nil {
			blobBytes = int64(base64.StdEncoding.DecodedLen(len(*b.Blob)))
		}
		users = append(users, map[string]any{
			"id":            id,
			"email":         u.Email,
			"createdAt":     u.CreatedAt,
			"emailVerified": u.EmailVerified != nil && *u.EmailVerified,
			"totpEnabled":   u.TotpSecret != "",
			"sessions":      len(u.Sessions),
			"blobBytes":     blobBytes,
		})
	}
	sort.Slice(users, func(i, j int) bool {
		return users[i]["createdAt"].(string) < users[j]["createdAt"].(string)
	})
	sendJSON(w, 200, map[string]any{"users": users})
}

// ---------- Pages ----------

func serveDashboard(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = dashboardTmpl.Execute(w, collectStats())
}

func serveAdmin(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(adminHTML))
}

func serveRobots(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte("User-agent: *\nDisallow: /admin\n\nSitemap: /sitemap.xml\n"))
}

func serveSitemap(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/xml; charset=utf-8")
	host := r.Host
	_, _ = w.Write([]byte(`<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://` + host + `/</loc><priority>1.0</priority></url>
</urlset>
`))
}

var dashboardTmpl = template.Must(template.New("dash").Parse(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{.Name}} — Zero-Knowledge Sync for SSH Clients</title>
<meta name="description" content="{{.Name}} is a privacy-first, zero-knowledge synchronization server for the Connexia SSH client. It stores only encrypted data and can never read your hosts, keys or snippets.">
<meta property="og:type" content="website">
<meta property="og:title" content="{{.Name}}">
<meta property="og:description" content="Privacy-first, zero-knowledge synchronization for your SSH client. Encrypted before upload, the server can never read your data.">
<meta property="og:site_name" content="Connexia">
<link rel="canonical" href="/">
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"SoftwareApplication","name":"Connexia","applicationCategory":"NetworkApplication","operatingSystem":"Linux, macOS, Windows, iOS, Android","description":"Zero-knowledge synchronization server for the Connexia SSH client.","offers":{"@type":"Offer","price":"0","priceCurrency":"USD"}}
</script>
<style>
:root{--bg:#0d0e12;--panel:#14161d;--border:#23262f;--text:#e6e8ee;--muted:#9aa0ae;--accent:#5b9df7;--green:#3ddc97;}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;line-height:1.6}
.wrap{max-width:960px;margin:0 auto;padding:0 20px}
header{border-bottom:1px solid var(--border);padding:18px 0}
header .wrap{display:flex;align-items:center;gap:12px}
.logo{font-weight:800;font-size:18px;letter-spacing:.3px}
.logo span{color:var(--accent)}
.badge{margin-left:auto;font-size:12px;color:var(--muted);border:1px solid var(--border);padding:3px 10px;border-radius:99px}
.hero{padding:64px 0 32px;text-align:center}
.hero h1{font-size:34px;letter-spacing:-.5px}
.hero p{color:var(--muted);max-width:620px;margin:14px auto 0;font-size:17px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:14px;padding:24px 0}
.card{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:20px;text-align:center}
.card .num{font-size:30px;font-weight:800;color:var(--accent);font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.card .lbl{font-size:12px;color:var(--muted);margin-top:6px;text-transform:uppercase;letter-spacing:.6px}
section{padding:28px 0}
h2{font-size:22px;margin-bottom:14px;letter-spacing:-.3px}
p.lead{color:var(--muted)}
code{background:var(--panel);border:1px solid var(--border);padding:2px 7px;border-radius:6px;font-family:ui-monospace,Menlo,monospace;font-size:13px}
table{width:100%;border-collapse:collapse;margin-top:10px;font-size:14px}
th,td{text-align:left;padding:9px 12px;border-bottom:1px solid var(--border)}
th{color:var(--muted);font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.5px}
footer{border-top:1px solid var(--border);padding:26px 0;color:var(--muted);font-size:13px;text-align:center}
.status{display:inline-flex;align-items:center;gap:7px;color:var(--green);font-size:13px;margin-top:8px}
.dot{width:8px;height:8px;border-radius:50%;background:var(--green);display:inline-block}
</style>
</head>
<body>
<header><div class="wrap"><div class="logo">Connexia<span> Sync</span></div><div class="badge">v{{.Version}}</div></div></header>

<main class="wrap">
  <div class="hero">
    <h1>Zero-knowledge sync for your SSH client</h1>
    <p>Connexia keeps your hosts, keys and snippets in sync across devices — encrypted on your device before upload. This server stores only ciphertext and can never read your data.</p>
    <div class="status"><span class="dot"></span> Online &mdash; up for {{.Uptime}}</div>
  </div>

  <div class="grid">
    <div class="card"><div class="num" id="n-users">{{.Users}}</div><div class="lbl">Accounts</div></div>
    <div class="card"><div class="num">{{.Snapshots}}</div><div class="lbl">Snapshots stored</div></div>
    <div class="card"><div class="num" id="n-bytes">{{.BlobBytes}}</div><div class="lbl">Encrypted bytes</div></div>
    <div class="card"><div class="num">{{.Verified}}</div><div class="lbl">Verified users</div></div>
  </div>

  <section>
    <h2>How it works</h2>
    <p class="lead">Every device derives an encryption key from your account password and encrypts the entire snapshot with AES-256-GCM before anything leaves the app. The server receives only the ciphertext, a revision number and a timestamp. There are no plaintext passwords stored — only scrypt hashes used to verify sign-in.</p>
  </section>

  <section>
    <h2>Endpoints</h2>
    <table>
      <thead><tr><th>Method</th><th>Path</th><th>Purpose</th></tr></thead>
      <tbody>
        <tr><td><code>POST</code></td><td><code>/api/register</code></td><td>Create an account</td></tr>
        <tr><td><code>POST</code></td><td><code>/api/login</code></td><td>Get a session token</td></tr>
        <tr><td><code>GET</code></td><td><code>/api/sync</code></td><td>Fetch your encrypted snapshot</td></tr>
        <tr><td><code>POST</code></td><td><code>/api/sync</code></td><td>Store the next revision</td></tr>
        <tr><td><code>GET</code></td><td><code>/api/health</code></td><td>Liveness check</td></tr>
      </tbody>
    </table>
  </section>

  <section>
    <h2>Point your app at this server</h2>
    <p class="lead">In Connexia, open <strong>Settings → Sync → Change</strong> and enter this server&rsquo;s URL. Everything stays encrypted; you can self-host the same binary on your own hardware.</p>
  </section>
</main>

<footer class="wrap">
  Connexia &mdash; an open SSH client and terminal emulator for Windows, macOS, Linux, iOS and Android. This page is auto-refreshed every 30 seconds.
</footer>
<script>
async function fmt(n){return (n>=1048576)?(n/1048576).toFixed(1)+' MB':(n>=1024)?(n/1024).toFixed(1)+' KB':n+' B'}
async function refresh(){
  try{
    const r=await fetch('/api/public/stats');const s=await r.json();
    const u=document.getElementById('n-users');if(u)u.textContent=s.users;
    const b=document.getElementById('n-bytes');if(b)b.textContent=await fmt(s.blobBytes);
  }catch(e){}
}
refresh();setInterval(refresh,30000);
</script>
</body>
</html>`))

const adminHTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Connexia — Admin</title>
<style>
:root{--bg:#0d0e12;--panel:#14161d;--border:#23262f;--text:#e6e8ee;--muted:#9aa0ae;--accent:#5b9df7;--red:#f0645c;}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif;line-height:1.5}
.wrap{max-width:1100px;margin:0 auto;padding:24px 20px}
h1{font-size:22px;margin-bottom:18px}
h1 span{color:var(--accent)}
#login{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:22px;max-width:420px}
label{display:block;font-size:12px;color:var(--muted);margin-bottom:6px;text-transform:uppercase;letter-spacing:.5px}
input{width:100%;background:var(--bg);border:1px solid var(--border);color:var(--text);border-radius:8px;padding:10px 12px;font-family:ui-monospace,Menlo,monospace;font-size:14px}
button{margin-top:14px;background:var(--accent);color:#0b0d12;border:0;border-radius:8px;padding:10px 18px;font-weight:700;cursor:pointer}
button:hover{filter:brightness(1.1)}
#err{color:var(--red);margin-top:10px;font-size:13px;display:none}
table{width:100%;border-collapse:collapse;font-size:13px;display:none;margin-top:8px}
th,td{text-align:left;padding:9px 12px;border-bottom:1px solid var(--border);white-space:nowrap}
th{color:var(--muted);font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.5px}
td.email{font-family:ui-monospace,Menlo,monospace}
.muted{color:var(--muted)}
.pill{display:inline-block;padding:2px 8px;border-radius:99px;font-size:11px}
.ok{background:rgba(61,220,151,.15);color:#3ddc97}
.no{background:rgba(240,100,92,.15);color:var(--red)}
.summary{color:var(--muted);font-size:13px;margin-bottom:10px;display:none}
</style>
</head>
<body>
<div class="wrap">
  <h1>Connexia <span>Admin</span></h1>
  <div id="login">
    <label>Admin token</label>
    <input type="password" id="token" placeholder="ADMIN_TOKEN" autocomplete="off">
    <button onclick="load()">View users</button>
    <div id="err"></div>
  </div>
  <p class="summary" id="summary"></p>
  <table id="tbl">
    <thead><tr><th>Email</th><th>Created</th><th>Verified</th><th>2FA</th><th>Sessions</th><th>Blob</th></tr></thead>
    <tbody id="rows"></tbody>
  </table>
</div>
<script>
const esc=s=>s.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt=n=>n>=1048576?(n/1048576).toFixed(1)+' MB':n>=1024?(n/1024).toFixed(1)+' KB':n+' B';
function rowsToHtml(users){return users.map(u=>
 '<tr><td class="email">'+esc(u.email)+'</td>'+
 '<td class="muted">'+esc((u.createdAt||'').replace('T',' ').slice(0,19))+'</td>'+
 '<td>'+(u.emailVerified?'<span class="pill ok">yes</span>':'<span class="pill no">no</span>')+'</td>'+
 '<td>'+(u.totpEnabled?'<span class="pill ok">yes</span>':'<span class="pill no">no</span>')+'</td>'+
 '<td>'+u.sessions+'</td>'+
 '<td class="muted">'+fmt(u.blobBytes)+'</td></tr>'
).join('')}
async function load(){
  const token=document.getElementById('token').value.trim();const err=document.getElementById('err');
  if(!token){err.style.display='block';err.textContent='Enter the admin token.';return}
  try{
    const r=await fetch('/api/admin/users?token='+encodeURIComponent(token));
    if(!r.ok){throw new Error((await r.json()).error||'failed')}
    const data=await r.json();
    document.getElementById('login').style.display='none';
    document.getElementById('rows').innerHTML=rowsToHtml(data.users);
    document.getElementById('summary').textContent=data.users.length+' account(s) — totals: '+data.users.length+' users, '+fmt(data.users.reduce((a,u)=>a+u.blobBytes,0))+' encrypted.';
    document.getElementById('summary').style.display='block';
    document.getElementById('tbl').style.display='table';
  }catch(e){err.style.display='block';err.textContent=String(e.message||e)}
}
document.getElementById('token').addEventListener('keydown',e=>{if(e.key==='Enter')load()});
</script>
</body>
</html>`
