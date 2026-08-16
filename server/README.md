# Connexia sync server

Zero-knowledge sync backend for the Connexia app. It stores only an
encrypted snapshot per user plus an scrypt password hash used to verify
logins — it can never read your hosts, passwords or SSH keys.

Written in Go with a single third-party dependency
([golang.org/x/crypto](https://pkg.go.dev/golang.org/x/crypto) for scrypt);
everything else is the standard library. It is a drop-in replacement for the
original Node.js server and uses the same on-disk format, so an existing
`data/` directory keeps working unchanged.

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
Data is stored as JSON in `./data` (override with `DATA_DIR=/path ./syncserver`).

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
   `DATA_DIR=/data`).
5. **Environment Variables** — add the SMTP settings from the table below so
   verification emails actually send (without them, codes only print to the
   server log).
6. **Domains** — add `sync.connexia.run`, let Coolify issue the Let's Encrypt
   certificate (point the domain's A record at your Coolify server first).
7. **Deploy** — the container's healthcheck then shows up in Coolify's UI.

## Endpoints

| Method | Path            | Body                     | Purpose                         |
|--------|-----------------|--------------------------|---------------------------------|
| POST   | /api/register   | `{ email, password }`    | Create an account               |
| POST   | /api/login      | `{ email, password }`    | Get a session token (30 days)   |
| GET    | /api/sync       | (Bearer token)           | Fetch `{ revision, blob, updatedAt }` |
| POST   | /api/sync       | `{ revision, blob }`     | Store the next revision (409 on conflict) |
| GET    | /api/health     | —                        | Liveness check                  |
| POST   | /api/account/delete | (Bearer token)        | Permanently delete the account, its sessions and its snapshot |

Plus email verification (`/api/verify-email`, `/api/resend-verification`),
TOTP 2FA (`/api/enable-2fa`, `/api/confirm-2fa`, `/api/disable-2fa`,
`/api/login/2fa`) and account status (`/api/account`).

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
| `DATA_DIR`   | `./data`             | Data directory                       |
| `SMTP_HOST`  | *(none)*             | SMTP relay for verification emails. Without it, codes are logged to the console (local testing only) |
| `SMTP_PORT`  | `587` (`465` if `SMTP_SECURE=true`) | SMTP port            |
| `SMTP_SECURE`| `false`              | Use implicit TLS on 465              |
| `SMTP_USER`  | *(none)*             | SMTP username (AUTH PLAIN)           |
| `SMTP_PASS`  | *(none)*             | SMTP password                        |
| `SMTP_FROM`  | `Connexia <noreply@connexia.local>` | From address        |

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

Stop the server and copy the `data/` directory, or back it up live (JSON
writes are atomic via temp-file + rename).

## Security notes

- Passwords are never sent to the server in plaintext form that is
  recoverable: the server keeps only an scrypt hash.
- The snapshot is AES-256-GCM encrypted with a key derived from the
  password (PBKDF2-HMAC-SHA256, 100 000 iterations) — the server only
  stores the ciphertext.
- Sessions are bearer tokens valid for 30 days. Use HTTPS if the server
  is reachable from untrusted networks.