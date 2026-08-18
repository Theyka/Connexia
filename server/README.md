# Connexia sync server

Zero-knowledge sync backend for the Connexia app. It stores only an
encrypted snapshot per user plus an scrypt password hash used to verify
logins — it can never read your hosts, passwords or SSH keys.

Written in Go. Storage is pluggable: PostgreSQL when `DATABASE_URL` is set,
otherwise a pure-Go SQLite file in `DATA_DIR`. On first boot any legacy
`data/` JSON directory is migrated into the database automatically. It is a
drop-in replacement for the original Node.js server (same endpoints).

## Official instance

The default builds of the app point at `https://sync.connexia.run`. Anyone
can use it for free; self-hosting is fully supported and recommended for
teams or anyone who wants full control.

## Run

```bash
go build -o syncserver .   # produces a static-ish binary, run anywhere
./syncserver
```

Listens on `http://0.0.0.0:8047` (override with `PORT=9000 ./syncserver`).
Without `DATABASE_URL`, data is stored in a SQLite file in `./data` (override
with `DATA_DIR=/path ./syncserver`).

## Docker / Coolify

The included `Dockerfile` builds a small static image (multi-stage, runs as a
non-root user, `HEALTHCHECK` on `/api/health`):

```bash
docker build -t syncserver .
docker run -d --name syncserver -p 8047:8047 -v sync-data:/data -e SMTP_HOST=... syncserver
```

To deploy in [Coolify](https://coolify.io), with the repo pushed to GitHub:

1. **New Resource → Public/Private Repository** (private needs the GitHub App
   linked) and pick the `Connexia` repo.
2. Build pack **Dockerfile**, set **Dockerfile Location** to
   `server/Dockerfile` (or Base Directory to `server`).
3. **Ports** — expose container port `8047`.
4. **Storage** — add a volume mounted at `/data` (the container already sets
   `DATA_DIR=/data`). Only needed for the SQLite fallback; when using
   PostgreSQL the data lives in the database resource.
5. **Database** (optional but recommended) — add a **PostgreSQL** resource,
   then set `DATABASE_URL` to its connection string. To use **PgBouncer**
   (Coolify's Postgres offers it on its own port), paste the PgBouncer
   connection string — the server pools connections through it transparently.
   No `DATABASE_URL` → SQLite is used automatically.
6. **Environment Variables** — add the SMTP settings from the table below so
   verification emails actually send (without them, codes only print to the
   server log).
7. **Domains** — add `sync.connexia.run`, let Coolify issue the Let's Encrypt
   certificate (point the domain's A record at your Coolify server first).
8. **Deploy** — the container's healthcheck then shows up in Coolify's UI.

## Endpoints

| Method | Path            | Body                     | Purpose                         |
|--------|-----------------|--------------------------|---------------------------------|
| POST   | /api/register   | `{ email, password }`    | Create an account (the first account on a fresh server becomes the admin) |
| POST   | /api/login      | `{ email, password }`    | Get a session token (30 days)   |
| GET    | /api/sync       | (Bearer token)           | Fetch `{ revision, blob, updatedAt }` |
| POST   | /api/sync       | `{ revision, blob }`     | Store the next revision (409 on conflict) |
| GET    | /api/health     | —                        | Liveness check                  |
| GET    | /api/setup/status | —                      | `{ adminExists }` — tells the client whether to offer a first-run admin registration |
| POST   | /api/account/delete | (Bearer token)        | Permanently delete the account, its sessions and its snapshot |

Plus email verification (`/api/verify-email`, `/api/resend-verification`),
TOTP 2FA (`/api/enable-2fa`, `/api/confirm-2fa`, `/api/disable-2fa`,
`/api/login/2fa`) and account status (`/api/account`). The public stats
endpoint is `GET /api/public/stats`.

## Rate limits

Per-IP fixed-window limits (in-memory, reset on restart):

| Endpoint            | Limit            |
|---------------------|------------------|
| `/api/register`     | 10 per hour      |
| `/api/login`        | 10 per minute    |
| `/api/login/2fa`    | 10 per minute    |
| `/api/verify-email` | 10 per minute    |
| `/api/resend-verification` | 5 per minute |
| `/api/sync` (POST)  | 120 per minute   |

Requests over the limit get `429 too many requests`. The verification-code
resend is additionally limited to one per minute per account.

## Configuration

All options are environment variables (see [`.env.example`](.env.example) —
documentation only, the server does not load a dotenv file).

| Variable     | Default              | Purpose                              |
|--------------|----------------------|--------------------------------------|
| `PORT`       | `8047`               | Listen port                          |
| `DATA_DIR`   | `./data`             | Data directory (SQLite fallback lives here) |
| `DATABASE_URL` | *(none)*           | PostgreSQL connection string. Set it to use Postgres (optionally via Coolify's PgBouncer URL); unset → SQLite |
| `SERVER_NAME`| `Connexia Sync Server`| Server name shown on the web dashboard |
| `SMTP_HOST`  | *(none)*             | SMTP relay for verification emails. Without it, codes are logged to the console (local testing only) |
| `SMTP_PORT`  | `587` (`465` if `SMTP_SECURE=true`) | SMTP port            |
| `SMTP_SECURE`| `false`              | Use implicit TLS on 465              |
| `SMTP_USER`  | *(none)*             | SMTP username (AUTH PLAIN)           |
| `SMTP_PASS`  | *(none)*             | SMTP password                        |
| `SMTP_FROM`  | `Connexia <noreply@connexia.local>` | From address        |

## Web dashboard & admin

The server serves a public, SEO-friendly landing page at `/` with live
stats (accounts, snapshots, encrypted bytes, uptime) rendered server-side,
plus `robots.txt` and `sitemap.xml`. Point the domain root (e.g.
`https://connexia.run`) at this server and the page is served automatically.

`/admin` is guarded by the **admin account** (no secret token):

- **Fresh server** — `/admin` shows a first-run registration form. The
  account created there (or the very first account via `/api/register`) is
  promoted to admin automatically; clients can check
  `GET /api/setup/status` → `{ "adminExists": bool }` to detect this state.
- **After setup** — `/admin` requires signing in as the admin account, then
  shows the per-account list (email, role, creation date, verification, 2FA,
  sessions, blob size). The admin API is `GET /api/admin/users` with the
  admin account's session token as a `Bearer` header.

If no SMTP relay is configured, the email-verification code printed to the
server log can be used to finish the admin setup.

## Exposing it

- **Local network (phone + PC at home):** point the app at
  `http://<your-pc-ip>:8047`. Add a firewall rule for port 8047.
- **Over the internet:** put it behind a reverse proxy with TLS, e.g.
  Caddy:
  ```
  sync.example.com {
      reverse_proxy 127.0.0.1:8047
  }
  ```
  then use `https://sync.example.com` in the app.

## Backups

- **SQLite:** stop the server and copy the `data/` directory (or back up the
  `sync.db` file — WAL mode, safe to snapshot with the `-wal`/`-shm` files).
- **PostgreSQL:** use the standard `pg_dump` (or your Coolify Postgres
  resource's snapshot/backup settings).

## Security notes

- Passwords are never sent to the server in plaintext form that is
  recoverable: the server keeps only an scrypt hash.
- The snapshot is AES-256-GCM encrypted with a key derived from the
  password (PBKDF2-HMAC-SHA256, 100 000 iterations) — the server only
  stores the ciphertext.
- Sessions are bearer tokens valid for 30 days. Use HTTPS if the server
  is reachable from untrusted networks.