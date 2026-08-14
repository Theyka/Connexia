# Connexia sync server

Zero-knowledge sync backend for the Connexia app. It stores only an
encrypted snapshot per user plus an scrypt password hash used to verify
logins — it can never read your hosts, passwords or SSH keys.

Zero runtime dependencies: Node.js (>= 18) built-ins only.

## Run

```bash
node server.js
# or
npm start
```

Listens on `http://0.0.0.0:8047` (override with `PORT=9000 node server.js`).
Data is stored as JSON in `./data` (override with `DATA_DIR=/path node server.js`).

## Endpoints

| Method | Path            | Body                     | Purpose                         |
|--------|-----------------|--------------------------|---------------------------------|
| POST   | /api/register   | `{ email, password }`    | Create an account               |
| POST   | /api/login      | `{ email, password }`    | Get a session token (30 days)   |
| GET    | /api/sync       | (Bearer token)           | Fetch `{ revision, blob, updatedAt }` |
| POST   | /api/sync       | `{ revision, blob }`     | Store the next revision (409 on conflict) |
| GET    | /api/health     | —                        | Liveness check                  |

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
