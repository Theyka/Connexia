# Connexia Sync — API & Protocol Reference

The Connexia sync server is a **zero-knowledge** backend: it stores only an
encrypted snapshot per user plus an scrypt password hash for login. It can
never read hosts, passwords or SSH keys. This document is the complete
reference for the REST API and the client-side snapshot/payload format.

See [../server/README.md](../server/README.md) for deployment, and
[ARCHITECTURE.md](ARCHITECTURE.md#6-cloud-sync--libcoresync) for how the
client drives this protocol.

---

## 1. Conventions

- Base URL: the server root, e.g. `https://sync.connexia.run` or
  `http://<host>:8047`. The client strips trailing slashes.
- All request bodies and responses are JSON (`Content-Type: application/json`).
- Authenticated requests send `Authorization: Bearer <token>`.
- All requests time out after 15 s on the client; the server enforces a
  10 s `ReadHeaderTimeout`.
- Errors are returned as `{"error": "<message>"}` with an appropriate HTTP
  status. The client surfaces the `error` string.
- CORS is enabled (`Access-Control-Allow-Origin: *`), and `OPTIONS`
  preflight returns `204 No Content`.
- **Rate limits** are per-IP fixed-window (in-memory, reset on restart).
  Over-limit → `429 {"error":"too many requests"}`. See §4.

### Server limits (`server/main.go`)

| Constant | Value |
|---|---|
| `maxBodyBytes` | 16 MB (request body cap) |
| `blobLimitBytes` | 6 MB (decoded snapshot blob cap) |
| `sessionTTL` | 30 days |
| `verifyCodeTTL` | 10 minutes |
| `verifyResendDelay` | 1 minute |
| `totpChallengeTTL` | 5 minutes |

### Storage

The server keeps hot state in memory and persists through a `Store`
interface (`server/store.go`). Two backends, selected by environment:

| Backend | When | Where |
|---|---|---|
| PostgreSQL | `DATABASE_URL` set | via `pgx` (PgBouncer-compatible) |
| SQLite | otherwise | `<DATA_DIR>/sync.db` (pure-Go, WAL + 5 s busy timeout) |

On first boot with an empty database, `migrateFromJSON` imports a legacy
`<DATA_DIR>/users.json` + `blobs/` directory and leaves the JSON files in
place as a backup.

---

## 2. Authentication model

Sessions are 32-byte random hex bearer tokens, TTL 30 days, stored per
account. Login is a state machine:

```
                     ┌─────────────────┐
   POST /api/login ──►│  email verify?  │── no ──► issue token (signed in)
                     └──────┬──────────┘
                            │ yes (403 emailNotVerified)
                            ▼
                  POST /api/verify-email
                            │
                            ▼
                  (re-login → issue token)
```

```
   POST /api/login ──► needsTotp? ── no ──► issue token (signed in)
                       │ yes
                       ▼
                 POST /api/login/2fa  (challengeToken + code)
                       │
                       ▼
                 issue token (signed in)
```

### Admin / first-run setup

- The **first account** registered on a fresh server (no admin yet) is
  promoted to admin automatically and is trusted immediately — admin
  accounts **skip email verification**.
- `GET /api/setup/status` → `{ "adminExists": bool }` lets a client detect
  the first-run state (e.g. to offer admin registration at `/admin`).
- Admin endpoints (`/api/admin/*`) require the admin account's bearer
  token. The last admin can never be deleted or demoted.
- A user can delete their own account with `POST /api/account/delete`.

### Rate limits

Per-IP fixed-window limits (in-memory, reset on restart). `clientIP`
honors `X-Forwarded-For` for reverse-proxy deployments.

| Endpoint | Limit |
|---|---|
| `POST /api/register` | 10 per hour |
| `POST /api/login` | 10 per minute |
| `POST /api/login/2fa` | 10 per minute |
| `POST /api/verify-email` | 10 per minute |
| `POST /api/resend-verification` | 5 per minute |
| `POST /api/sync` | 120 per minute |
| `GET /api/public/stats` | 120 per minute |
| `GET /api/setup/status` | 120 per minute |

Over-limit → `429 {"error":"too many requests"}`. The verification-code
resend is additionally limited to one per minute per account.

Security notes:

- Passwords are stored only as **scrypt** hashes
  (`N=16384, r=8, p=1, keyLen=64`, matching Node's `crypto.scryptSync`
  defaults so data from the original Node server still verifies).
- Login computes scrypt against a random salt even for unknown emails and
  uses `subtle.ConstantTimeCompare`, so response time does not leak which
  emails exist.
- A valid session is required for all `/api/*` endpoints except the public
  ones below. An unverified email returns `403 "email not verified"` on
  authenticated endpoints.

---

## 3. Public endpoints

### `POST /api/register`

Create an account. A verification code is emailed (or logged if no SMTP is
configured) and the account starts unverified.

**Request**
```json
{ "email": "user@example.com", "password": "secret-passphrase" }
```

**Validation**
- `email` must match `^[^\s@]+@[^\s@]+\.[^\s@]+$` (lower-cased, trimmed).
- `password` must be ≥ 8 characters.
- Email must not already exist (`409`).

**First-run behavior:** if no admin account exists yet, the new account is
promoted to admin and is trusted immediately (no email verification
required). Otherwise a verification code is emailed (or logged if no SMTP
is configured) and the account starts unverified.

**Response** `201 Created`
```json
{ "userId": "550e8400-e29b-41d4-a716-446655440000", "emailVerified": false, "isAdmin": false }
```

### `POST /api/login`

Verify credentials. Three outcomes:

**1. Success** — `200 OK`
```json
{ "token": "<64-hex>", "userId": "550e8400-..." }
```

**2. TOTP required** — `200 OK` (the account has 2FA enabled)
```json
{ "needsTotp": true, "challengeToken": "<64-hex>" }
```
The `challengeToken` is valid for 5 minutes. Complete with
`POST /api/login/2fa`.

**3. Email not verified** — `403 Forbidden`
```json
{ "error": "emailNotVerified" }
```
A fresh verification code is resent (rate-limited to once per minute).
Complete verification with `POST /api/verify-email`, then log in again.

On bad credentials: `401 {"error":"invalid email or password"}`.

### `POST /api/verify-email`

Verify an email with a 6-digit code.

**Request**
```json
{ "email": "user@example.com", "code": "123456" }
```

**Response** `200 OK`
```json
{ "verified": true }
```
Errors: `404` "no pending verification for this email" (no account or
already verified), `400` "invalid or expired code".

### `POST /api/resend-verification`

Resend the verification code. Rate-limited to once per minute.

**Request**
```json
{ "email": "user@example.com" }
```

**Response** `200 OK`
```json
{ "resent": true }
```
Errors: `404` "no pending verification for this email", `429` "wait a minute
before requesting another code".

### `POST /api/login/2fa`

Complete a TOTP login using the `challengeToken` from `POST /api/login`.

**Request**
```json
{ "challengeToken": "<64-hex>", "code": "123456" }
```

**Response** `200 OK`
```json
{ "token": "<64-hex>", "userId": "550e8400-..." }
```
Errors: `400` "invalid or expired challenge" (bad token or > 5 min),
`401` "invalid code". TOTP is RFC 6238 with a ±1 step (30 s) window.

### `GET /api/health`

Liveness check (no auth).

**Response** `200 OK`
```json
{ "ok": true, "time": "2026-08-23T12:00:00.000Z" }
```

### `GET /api/setup/status`

Reports whether an admin account exists yet, so the client can offer a
first-run admin registration flow (no auth).

**Response** `200 OK`
```json
{ "adminExists": false }
```

### `GET /api/public/stats`

Public server stats (rendered server-side on the landing page; no auth).

**Response** `200 OK`
```json
{
  "name": "Connexia Sync Server",
  "version": "1.0.0",
  "uptime": "2h15m",
  "users": 42,
  "verified": 38,
  "snapshots": 35,
  "blobBytes": 1048576,
  "lastActive": "2026-08-23 12:00:00",
  "serverUrl": "sync.connexia.run"
}
```

### Admin endpoints

All admin endpoints require `Authorization: Bearer <token>` belonging to an
**admin** account. Non-admin → `401 {"error":"admin account required"}`.

#### `GET /api/admin/users`

List all accounts (admin only).

**Response** `200 OK`
```json
{
  "users": [
    {
      "id": "550e8400-...",
      "email": "user@example.com",
      "createdAt": "2026-08-23T12:00:00.000Z",
      "emailVerified": true,
      "totpEnabled": false,
      "sessions": 2,
      "blobBytes": 20480,
      "isAdmin": false
    }
  ]
}
```

#### `POST /api/admin/users/delete`

Delete any account (admin only). The last admin cannot be deleted.

**Request**
```json
{ "id": "550e8400-..." }
```

**Response** `200 OK` — `{"deleted": true}`.
Errors: `404` "unknown account", `400` "cannot delete the last admin".

#### `POST /api/admin/users/role`

Promote or demote an account (admin only). The last admin cannot be
demoted.

**Request**
```json
{ "id": "550e8400-...", "isAdmin": true }
```

**Response** `200 OK` — `{"isAdmin": true}`.
Errors: `404` "unknown account", `400` "cannot demote the last admin".

---

## 4. Authenticated endpoints

All of the following require `Authorization: Bearer <token>` and a verified
email. Missing/expired token → `401 {"error":"missing or invalid session
token"}`. Unverified email → `403 {"error":"email not verified"}`.

### `GET /api/account`

**Response** `200 OK`
```json
{
  "email": "user@example.com",
  "emailVerified": true,
  "totpEnabled": false
}
```

### `POST /api/account/delete`

Permanently delete the signed-in account, its sessions and its encrypted
snapshot (both the in-memory entry and the stored blob).

**Response** `200 OK` — `{"deleted": true}`.

### `POST /api/enable-2fa`

Begin enabling TOTP 2FA. Returns a base32 secret and an `otpauth://` URL
for QR-code enrollment. The secret is *pending* until confirmed.

**Response** `200 OK`
```json
{
  "secret": "JBSWY3DPEHPK3PXP",
  "otpauthUrl": "otpauth://totp/Connexia:user%40example.com?secret=...&issuer=Connexia&digits=6&period=30"
}
```

### `POST /api/confirm-2fa`

Confirm a pending 2FA setup with a valid TOTP code.

**Request**
```json
{ "code": "123456" }
```

**Response** `200 OK` — `{"enabled": true}`.
Errors: `400` "no pending 2FA setup" / "invalid code".

### `POST /api/disable-2fa`

Disable 2FA (requires a current TOTP code).

**Request**
```json
{ "code": "123456" }
```

**Response** `200 OK` — `{"disabled": true}`.
Errors: `400` "2FA is not enabled" / "invalid code".

### `GET /api/sync`

Fetch the current encrypted snapshot.

**Response** `200 OK`
```json
{
  "revision": 7,
  "blob": "<base64 AES-256-GCM ciphertext>",
  "updatedAt": "2026-08-23T12:00:00.000Z"
}
```
`blob` is `null` when no snapshot has ever been pushed. `revision` starts
at `0` for a new account.

### `POST /api/sync`

Push the next snapshot. **Optimistic concurrency**: the request `revision`
must equal the server's current `revision`, otherwise `409`.

**Request**
```json
{ "revision": 7, "blob": "<base64 AES-256-GCM ciphertext>" }
```

**Validation**
- `revision` ≥ 0 (else `400` "invalid revision").
- Decoded `blob` size ≤ 6 MB (else `413` "blob too large").

**Response** `200 OK`
```json
{ "revision": 8 }
```
The server increments the revision by 1 and records `updatedAt`.

**Conflict** — `409 Conflict`
```json
{ "error": "revision conflict" }
```
The client re-pulls (`GET /api/sync`), reconciles, and retries with the
new base revision.

---

## 5. Snapshot & payload format (client side)

The server treats `blob` as opaque ciphertext. The plaintext is a
**`SyncPayload`** defined in `lib/core/sync/snapshot.dart`. The client
encrypts/decrypts it with a password-derived key (see §6).

### 5.1 `SyncSnapshotData`

The actual application data. Each table is serialized as a list of row maps;
settings is a `Map<String,String>`.

| Field | Type |
|---|---|
| `hosts` | `List<Map<String,dynamic>>` |
| `groups` | `List<Map<String,dynamic>>` |
| `identities` | `List<Map<String,dynamic>>` |
| `knownHosts` | `List<Map<String,dynamic>>` |
| `snippets` | `List<Map<String,dynamic>>` |
| `sessionLogs` | `List<Map<String,dynamic>>` |
| `themes` | `List<Map<String,dynamic>>` |
| `settings` | `Map<String,String>` |

Derived:
- `bool get isEmpty` — true when every list is empty and settings is empty.
- `DateTime get modifiedAt` — the **latest** timestamp across all rows of
  all tables. This is the value used for **last-write-wins** conflict
  resolution during reconcile.

Serialization helpers: `toJson()` / `fromJson()`.

### 5.2 Excluded settings keys

These keys **never leave the device** (defined as `excludedSettingKeys` in
`snapshot.dart`):

- `windowSize`, `windowPosition` — device-specific window geometry.
- All `sync*` metadata keys: `syncServerUrl`, `syncEmail`, `syncUserId`,
  `syncRevision`, `syncLastPulledAt`, `syncLastLocalWriteAt`, `syncDirty`,
  `syncLastPayloadHash`.

The vault master key (`vaultMasterKey`) is *not* in `excludedSettingKeys` —
it is intentionally seeded into synced settings once so every device on an
account shares it (see [ARCHITECTURE.md §4.4](ARCHITECTURE.md#44-cross-device-key-distribution)).

### 5.3 Export / import

- `exportSnapshot(AppDatabase db)` → `SyncSnapshotData`. Dumps every table,
  filtering out `excludedSettingKeys` from settings.
- `importSnapshot(AppDatabase db, SyncSnapshotData snapshot)` — wipes all
  tables (`clearAllForSync`, children before parents) and batch-inserts the
  snapshot inside a **single transaction**. Device-local settings
  (`excludedSettingKeys`) are preserved across an import so the sync
  session itself survives. Includes defensive coercion helpers (`_date`,
  `_int`, `_bool`) for robustness against schema drift.

### 5.4 `SyncPayload`

The wire envelope. `buildPayload(SyncSnapshotData, {DateTime? modifiedAt})`
constructs it:

```json
{
  "format": "connexia-sync",
  "version": 1,
  "modifiedAt": "2026-08-23T12:00:00.000Z",
  "data": { /* SyncSnapshotData.toJson() */ }
}
```

`SyncPayload.encode()` / `SyncPayload.decode()` handle serialization. The
encoded string is what gets encrypted and pushed as `blob`.

---

## 6. Encryption (client side)

Defined in `lib/core/sync/sync_crypto.dart`. The server never sees the key.

### Key derivation

```
SyncCrypto.deriveKey(password, userId)
  → PBKDF2-HMAC-SHA256, 100 000 iterations, 256-bit output
  salt / nonce = "connexia-sync-v1:" + userId
```

The `userId` (returned by `/api/register` and `/api/login`) is mixed into
the salt so two accounts never share a key, even with the same password.

### Envelope encryption

```
blob = base64( nonce ‖ ciphertext ‖ mac )   // AES-256-GCM
```

- `encryptString(plaintext, key)` → the base64 envelope above.
- `decryptString(ciphertext, key)` → plaintext; throws on a wrong key.

The pushed `blob` is therefore `SyncCrypto.encryptString(payload.encode(),
derivedKey)`. On pull, the client decrypts and `SyncPayload.decode()`s.

### Session key wrapping

The derived `SecretKey` is itself **wrapped with the vault master key**
(`Vault.encrypt`) before being persisted to secret storage as
`connexia_sync_key`. This couples the sync key to the device vault; if the
vault master key is rotated (e.g. adopted from another device after a
sync), the controller re-wraps the sync key so the session survives.

---

## 7. Reconcile & revision model

The client (`SyncController` in `sync_controller.dart`) drives the loop.
All sync operations are serialized through a single queue so pulls and
pushes never interleave.

### `syncNow` (pull-then-push)

1. `GET /api/sync` → remote `{revision, blob, updatedAt}`.
2. Compare local `syncRevision` to remote `revision`:
   - **Equal** → push if local is dirty, or seed if the server blob is
     empty.
   - **Server empty** → seed (push the local snapshot as revision 1).
   - **Otherwise** → decrypt the remote payload, compute a content hash
     (`sha256` of `toJson`, in an isolate) to detect no-op echoes, and
     apply **last-write-wins by `modifiedAt`**:
     - remote newer → `importSnapshot` (preserving device-local settings).
     - local newer → push.
3. On a push `409` → re-pull and reconcile again.

### Push (`_push`)

1. `exportSnapshot` → `buildPayload` → `SyncCrypto.encryptString` (off the
   UI thread via `Isolate.run`).
2. `POST /api/sync { revision: baseRevision, blob }`.
3. Success → local `syncRevision = baseRevision + 1`.
4. `409` → re-pull and reconcile.

### Debounced local-change push

`ref.listen` on all seven data providers + settings fires
`_onLocalDataChange`, which sets `syncDirty`, records
`syncLastLocalWriteAt`, and schedules a **3-second debounced** push.
Emissions are suppressed for 3 s after an import
(`_suppressEmissionsUntil`) to avoid echoing the device's own writes back.
No-op pushes are skipped by comparing the local snapshot hash to
`syncLastPayloadHash`.

---

## 8. Client persistence keys

The sync account is persisted so the user stays signed in across launches.

**Secret storage** (OS keychain / 0600 file):

| Key | Value |
|---|---|
| `connexia_sync_token` | bearer token |
| `connexia_sync_key` | vault-wrapped derived `SecretKey` (base64) |
| `connexia_sync_account` | fallback account JSON (used if DB settings were wiped) |

**Database settings** (`SettingsTable`):

| Key | Value |
|---|---|
| `syncServerUrl` | server base URL (default `https://sync.connexia.run/`) |
| `syncEmail` | account email |
| `syncUserId` | account id (also the PBKDF2 salt component) |
| `syncRevision` | last known server revision |
| `syncLastPulledAt` | last successful pull timestamp |
| `syncLastLocalWriteAt` | last local mutation timestamp |
| `syncDirty` | local changes pending a push |
| `syncLastPayloadHash` | `sha256` of the last pushed payload (no-op guard) |
| `vaultMasterKey` | vault master key, seeded once for cross-device sharing |

---

## 9. Server storage format

Storage is pluggable (`server/store.go`). The schema is shared between
backends, differing only in placeholder style (`$1` vs `?`).

### PostgreSQL (`DATABASE_URL` set)

Standard connection via `pgx` (PgBouncer-compatible). The server pools up
to 10 connections.

### SQLite (default)

A pure-Go (no CGO) database at `<DATA_DIR>/sync.db`, opened in WAL mode
with a 5 s busy timeout. A single connection is used (writes are
serialized by the app lock anyway) to sidestep any residual "database is
locked" edge cases.

### Schema

```sql
CREATE TABLE users (
  id               TEXT PRIMARY KEY,
  email            TEXT NOT NULL,
  salt             TEXT NOT NULL,
  hash             TEXT NOT NULL,
  created_at       TEXT NOT NULL,
  email_verified   INTEGER NOT NULL DEFAULT 0,
  verify_code      TEXT NOT NULL,
  last_verify_sent TEXT NOT NULL,
  sessions         TEXT NOT NULL,        -- JSON map of token -> expiry
  totp_secret      TEXT NOT NULL,
  totp_pending     TEXT NOT NULL,        -- JSON or empty
  challenge        TEXT NOT NULL,        -- JSON or empty
  is_admin         INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE blobs (
  id         TEXT PRIMARY KEY,
  revision   INTEGER NOT NULL DEFAULT 0,
  blob_data  TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_users_email ON users(email);
```

`sessions`, `verify_code`, `totp_pending` and `challenge` are stored as
JSON strings. Accounts created before email verification existed are
treated as verified on load.

### Legacy JSON migration

On first boot with an empty database, `migrateFromJSON` imports a legacy
`<DATA_DIR>/users.json` + `blobs/<id>.json` directory (the original Node.js
format) and leaves the JSON files in place as a backup.

---

## 10. Web dashboard & website

The server serves the full Connexia website from the same binary (templates
in `server/templates/`, embedded via `//go:embed`). These are HTML pages,
not JSON API endpoints:

| Path | Auth | Purpose |
|---|---|---|
| `/` (and `/dashboard`) | none | Landing page with live server stats (rendered server-side, auto-refreshed via `/api/public/stats`) |
| `/features`, `/downloads`, `/docs`, `/pricing` | none | Marketing / docs pages |
| `/register` | none | Browser account registration |
| `/login` | none | Browser sign-in |
| `/account` | none | Account view (role, verification, 2FA, sign out, delete account) |
| `/admin` | admin | First-run registration when no admin exists; afterwards admin sign-in + account management console |
| `/robots.txt`, `/sitemap.xml` | none | SEO |
| `/assets/site.css`, `/assets/site.js` | none | Static assets |

`SERVER_NAME` (env) controls the name shown on the landing page.
