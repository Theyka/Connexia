# Connexia — Technical Architecture

This document describes how Connexia is built internally: the layered design,
module responsibilities, data model, encryption model, SSH session lifecycle,
cloud-sync protocol and the key code paths. It is aimed at developers
contributing to the project.

See also:

- [DEVELOPMENT.md](DEVELOPMENT.md) — building, running, testing, conventions.
- [API.md](API.md) — the sync-server REST API and snapshot format.
- [../README.md](../README.md) — user-facing overview and features.
- [../server/README.md](../server/README.md) — deploying the sync server.

---

## 1. Overview

Connexia is a Termius-style SSH client and terminal emulator written in
Flutter, targeting **Windows, macOS, Linux, iOS and Android** from a single
codebase. It is **offline-first**: all data lives in a local SQLite database
(drift), secrets are encrypted at rest, and an optional self-hosted sync
server provides zero-knowledge multi-device sync.

```
┌────────────────────────────── UI layer ──────────────────────────────┐
│  lib/ui/screens    screens: hosts, keys, known hosts, snippets,      │
│                    logs, settings, terminals, sftp                    │
│  lib/ui/widgets    panels, sidebar, title bar, selection, forms      │
│  lib/ui/state      Riverpod providers, nav, settings, connection     │
│  lib/ui/theme      AppColors (mutable palette), Material theme       │
│  lib/ui/utils      context-menu positioning helper                   │
├────────────────────────────── core layer ────────────────────────────┤
│  lib/core/db       drift schema + migrations + data access           │
│  lib/core/crypto   Vault (AES-256-GCM) + secret storage backends     │
│  lib/core/ssh      SshService, SessionManager, HostKeyStore          │
│  lib/core/sync     SyncApi, SyncCrypto, Snapshot, SyncController     │
│  lib/core/terminal themes, scrollback search                         │
│  lib/core/debug_log                                                  │
├────────────────────────────── infrastructure ────────────────────────┤
│  third_party/xterm  vendored xterm (patched)                         │
│  server/            Go zero-knowledge sync server                    │
└───────────────────────────────────────────────────────────────────────┘
```

**Layering rule:** the UI layer depends on the core layer; core subsystems
converge on the database and the vault. Nothing in core knows about widgets.

---

## 2. App lifecycle and wiring

### `lib/main.dart`

Process bootstrap. Because drift fails with *"database is locked"* when two
connections open the same SQLite file in one process (Linux), **one**
`ProviderContainer` is created before `runApp` and passed to the widget tree
via `UncontrolledProviderScope` — the same `AppDatabase` instance serves both
the window-restore reads and the whole app.

Responsibilities:

- Crash logging — unhandled `FlutterError.onError` and
  `PlatformDispatcher.instance.onError` are appended to
  `%TEMP%\connexia_errors.log` (`_setupErrorLogging`).
- Desktop window setup via `window_manager`: hidden title bar, background
  `Color(0xFF0B0C10)`, default `Size(1280, 800)`, min `Size(940, 600)`,
  centered.
- Non-blocking window-geometry restore: `windowSize`, `windowPosition`,
  `windowMaximized` are read from the DB while the window waits to show; the
  window appears after the first post-frame callback or a 600 ms timer
  fallback, then geometry is applied.

### `lib/app.dart`

`ConnexiaApp` builds the `MaterialApp` (theme from `buildAppTheme()`, home =
`HomeScreen()`). On `AppLifecycleState.detached` (window closing) it calls
`SessionManager.closeAllSessionLogs()` so no session log stays marked active.

### Provider wiring — `lib/ui/state/providers.dart`

| Provider | Value |
|---|---|
| `appDatabaseProvider` | Singleton `AppDatabase` (disposed on cleanup) |
| `secretStorageProvider` | `PlatformSecretStorage()` |
| `vaultProvider` | `Vault(secretStorage)` |
| `hostKeyStoreProvider` | `HostKeyStore(appDatabase)` |
| `sshServiceProvider` | `SshService()` |
| `sessionManagerProvider` | `SessionManager(db, vault, ssh, hostKeyStore)`; listens to settings to keep `maxConcurrentConnects` in sync; calls `endStaleSessionLogs()` on startup |
| `syncControllerProvider` | `NotifierProvider<SyncController, SyncState>` |

Data streams (`hostsProvider`, `groupsProvider`, …) are `StreamProvider`s fed
by drift `watch*` queries; mutations go through `appDatabaseProvider` methods
and ripple back reactively.

---

## 3. Database layer — `lib/core/db/database.dart`

Drift schema, currently at **schemaVersion 7**. All IDs are client-generated
text UUIDs. Relations are implicit (no FK constraints).

| Table | Columns | Notes |
|---|---|---|
| `Groups` | `id`, `name`, `parentId?`, `color?`, `sortOrder`, `username?`, `authType?`, `keyId?`, `encryptedPassword?` | Optional shared credentials inherited by child hosts |
| `Hosts` | `id`, `name`, `address`, `port`, `username`, `authType`, `keyId?`, `encryptedPassword?`, `groupId?`, `tags`, `color?`, `notes`, `favorite`, `lastConnected?`, `os?` | `os` detected remotely on connect |
| `Identities` | `id`, `name`, `encryptedKeyPem`, `encryptedPassphrase?`, `comment`, `publicKey`, `certificate`, `createdAt` | SSH private keys, encrypted at rest |
| `KnownHosts` | `hostKey` (PK), `keyType`, `fingerprint`, `firstSeen`, `lastSeen` | TOFU host-key registry |
| `SettingsTable` | `key` (PK), `value` | Key/value preferences + sync metadata |
| `Snippets` | `id`, `title`, `command`, `createdAt`, `updatedAt?` | `updatedAt` nullable by design (SQLite can't add a column with non-constant default) |
| `SessionLogs` | `id`, `address`, `username`, `connectedAt`, `disconnectedAt?`, `status` | Connection history |
| `AppThemes` | `id`, `name`, `paletteJson`, `createdAt` | Custom user palettes |

Implicit relations: `Hosts.groupId → Groups.id`, `Hosts.keyId →
Identities.id`, `Groups.parentId → Groups.id`, `Groups.keyId →
Identities.id`.

### Migrations (v1 → v7)

1. Baseline.
2. Group auth columns (`username`/`authType`/`keyId`/`encryptedPassword`);
   adds `snippets` and `sessionLogs` tables.
3. Adds `publicKey`/`certificate` to identities.
4. Renames legacy `snippets.name/content` → `title/command`, guarded by
   `pragma_table_info`.
5. Adds `snippets.updated_at` when missing.
6. Adds `hosts.os`.
7. Adds `appThemes`.

### Notable methods

- Hosts: `allHosts()` / `watchHosts()` (ordered `lastConnected DESC`),
  `upsertHost`, `deleteHost`, `updateHostLastConnected*`,
  `updateHostOsByAddress`, `findHostById`.
- Sync support: `getSessionLogsUnbounded()`, `clearAllForSync()` (empties
  every table, children before parents; intended to run inside a transaction).
- Diagnostics: `databaseFilePath()` (via `PRAGMA database_list`),
  `tableRowCounts()` (via `sqlite_master`) — used by the Database settings
  panel.

Regenerate generated code after schema changes:

```sh
dart run build_runner build
```

---

## 4. Encryption model — `lib/core/crypto/`

Connexia uses **two independent encryption layers**:

### 4.1 Vault (device-local, at rest) — `vault.dart`

- Random 256-bit master key generated on first use, held in platform secret
  storage under `connexia_master_key_v1`, cached in memory.
- Secrets (host/group passwords, identity PEMs and passphrases) are
  encrypted with **AES-256-GCM**: `base64(nonce ‖ ciphertext ‖ mac)`.
- API: `encrypt(text)`, `decrypt(ciphertext)`, `exportKey()` (base64 master
  key, used to seed other devices), `adoptKey(base64Key)` (replace master key
  with one from another device, used by cloud sync).

### 4.2 Secret storage backends — `secret_storage.dart`

`SecretStorage` is a minimal `read/write/delete` abstraction so `Vault` is
testable without platform dependencies.

| Backend | Where |
|---|---|
| `WindowsRegistrySecretStorage` | `HKCU\Software\Connexia` as REG_SZ (relies on Windows user-level ACL protection; chosen over ATL credential APIs to avoid build complexity) |
| `FileSecretStorage` | One user-private file per key (`<key>.sec`) in the app-support dir; `chmod 600` on non-Windows; key names sanitized to `[A-Za-z0-9_-]` |
| `PlatformSecretStorage` | Lazy factory: Windows → registry, else → file storage |

### 4.3 Sync crypto (in transit / at rest on server) — `sync/sync_crypto.dart`

- Key derivation: **PBKDF2-HMAC-SHA256**, 100,000 iterations, 256 bits,
  salt/nonce `'connexia-sync-v1:<userId>'` — two accounts never share a key.
- Whole-snapshot encryption: **AES-256-GCM** → `base64(nonce‖ciphertext‖mac)`.
- The server only ever sees ciphertext.

### 4.4 Cross-device key distribution

The vault master key is written once into synced settings
(`vaultMasterKey`) so every device on an account shares it. After a sync
import, `SyncController._adoptVaultKeyIfNeeded` switches the local vault to
the remote master key and **re-encrypts** any locally-created host/group
passwords and identity key blobs that were encrypted with the old key, then
re-wraps the stored sync key so the session survives the switch.

---

## 5. SSH layer — `lib/core/ssh/`

### 5.1 `ssh_service.dart` — transport

Low-level SSH via `dartssh2`.

- `connectClient(...)` — connect + authenticate **without** a shell (used by
  SFTP).
- `connect(...)` — full interactive shell with `SSHPtyConfig(type:
  'xterm-256color', …)`.
- Timeouts: socket 15 s, handshake 25 s, auth 12 s.
- `_identityCache` keyed by `pems.join('|')|passphrase` so hosts sharing one
  identity never re-run expensive key parsing.
- `_parseIdentities`: unencrypted keys parse synchronously; encrypted ones go
  through `compute(unlockKeyPems, …)` in an isolate (bcrypt_pbkdf is slow),
  and the isolate re-serializes keys unencrypted so only cheap parsing
  remains on the main thread.
- `onVerifyHostKey` receives `(keyType, fingerprint)` where the fingerprint
  is decoded from bytes via `utf8.decode` (OpenSSH-style `SHA256:…`).

### 5.2 `session_manager.dart` — session lifecycle (largest core file)

Orchestrates open/connect/reconnect/close, host-key verification, session
logging, OS detection, concurrency throttling and terminal I/O plumbing.

Key types:

- `enum SessionStatus { connecting, verifyingHostKey, connected,
  disconnected, error }`
- `HostConnectionRequest` — immutable value object (`displayName`, `address`,
  `port`, `username`, `password?`, `identityId?`, `keyPassphrase?`).
- `TerminalSession extends ChangeNotifier` — per-session mutable state
  (terminal, controller, status, pending host-key verification completer,
  auto-retry timer, mobile modifier locks, log id, …).

`SessionManager`:

- `openSession(request)` → assigns a unique id, dedupes the label `(n)`,
  wires `terminal.onOutput`/`onResize`, kicks off a throttled connect.
- `closeSession`, `reconnect`, `duplicateSession`, `renameSession`.
- Broadcast helpers: `pasteToActiveSession`, `runInActiveSession`,
  `pasteToAllConnected`, `runInAllConnected`.
- `resolveHostKey(session, {accept})` — completes the pending verification
  dialog.
- `detectOs(client, address, port)` — runs `uname -s; uname -m;
  cat /etc/os-release` (fallback `ver`), parses Windows/macOS/BSD/Solaris/
  Linux (incl. `PRETTY_NAME`), persists via `updateHostOsByAddress`.
- `normalizePaste(String)` — strips CRLF/CR → LF (clipboard safety).
- `onHostKeyVerification` callback hook.

Notable internals:

- **Concurrency throttle:** `_pumpConnectQueue` bounds simultaneous connects
  to `maxConcurrentConnects` (default 4) because key exchange does CPU-heavy
  crypto on the UI thread.
- **Host-key flow (`_verifyHostKey`):** consult `HostKeyStore.isTrusted` →
  auto-accept if `autoAcceptHostKeys` setting → else set status
  `verifyingHostKey`, stash a `Completer<bool>` in `session.pendingVerification`,
  invoke `onHostKeyVerification`, await the completer, then `trust()` on
  accept. A mismatch sets error status and refuses.
- **Streaming UTF-8 (`Utf8StreamDecoder`):** decodes each SSH chunk
  immediately while carrying an incomplete multi-byte sequence across chunk
  boundaries — avoids `�` garbage from full-screen TUI redraws (dart:convert's
  chunked sink buffers until close).
- **Auto-reconnect:** `_scheduleAutoRetry` starts a 1-second periodic timer;
  retries every 5 s until success or `stopAutoRetry`.
- **Modifier locks (`_applyModifierLocks`, `_ctrlTransform`):** locked /
  one-shot Ctrl/Alt transforms for soft keyboards (Ctrl+c → ^C, Alt prefixes
  ESC, PC-style punctuation mappings).
- **`_friendlyError`:** maps `SSHAuthFailError`, `SSHHandshakeError`,
  `SSHHostkeyError`, `SSHSocketError`, `SocketException`, `TimeoutException`
  to user-readable messages.
- Session logs are written on connect (`_logConnect`, UUID v4 id) and ended
  on disconnect (`_logDisconnect`); `shell.done` handlers ignore superseded
  shells (only the current shell may end the session).

### 5.3 `host_key_store.dart` — trust-on-first-use

Backed by the `KnownHosts` table.

- `normalizeHostKey(address, port)` → `'$address:$port'`.
- `isTrusted({address, port, keyType, fingerprint})` — `false` if unknown;
  **throws `HostKeyMismatchError`** if known but the presented key differs.
- `trust({...})` — upserts with `lastSeen` refreshed.

---

## 6. Cloud sync — `lib/core/sync/`

**Local-first**: no account ⇒ nothing changes; with an account, local edits
push automatically (debounced) and the server snapshot is pulled at startup.
Conflicts resolve **last-write-wins by timestamp**.

### Components

| File | Role |
|---|---|
| `sync_api.dart` | Typed HTTP client (JSON, Bearer auth, 15 s timeouts). Register/login/2FA/verify/account + `fetchSnapshot`/`pushSnapshot` (409 = conflict). |
| `sync_crypto.dart` | PBKDF2 key derivation + AES-256-GCM envelope (see §4.3). |
| `snapshot.dart` | Serialization of every syncable table; `excludedSettingKeys` (window geometry + all `sync*` metadata) never leave the device; `exportSnapshot`/`importSnapshot` (atomic, single transaction); `SyncPayload` (`format: 'connexia-sync'`, `version: 1`). |
| `sync_controller.dart` | Owns the account: session persistence, key derivation, pull/push reconcile loop. |

### SyncController internals

- **Secret-storage keys:** `connexia_sync_token`, `connexia_sync_key`,
  `connexia_sync_account`; settings keys `syncServerUrl`, `syncEmail`,
  `syncUserId`, `syncRevision`, `syncLastPulledAt`, `syncLastLocalWriteAt`,
  `syncDirty`, `syncLastPayloadHash`, `vaultMasterKey`.
- **Serialized queue (`_serialize`):** chains all sync ops so pulls/pushes
  never interleave (prevents 409 storms and repeated full-table imports).
- **Session restore (`_loadSession`):** reads settings + secret storage;
  falls back to `_accountKey` JSON if DB settings were wiped by an older
  import; if secrets are gone but meta exists, forces a fresh login. The sync
  key is wrapped with the vault key (`_vault.encrypt`).
- **Periodic background poll (`_startSyncTimer`):** a `Timer.periodic` at
  `syncPollInterval` (30 s) calls `_serialize(_reconcile)` while signed in,
  so changes made on other devices are picked up automatically. Started
  after login / session restore; cancelled on sign-out / account deletion.
- **Reconcile (`_reconcile`):** compares local vs remote revision; equal →
  push if dirty or seed if server empty; server empty → seed; otherwise
  decrypt remote payload, compare content hash (`sha256` of `toJson`,
  computed in an isolate) to detect no-op echoes, and apply last-write-wins
  by `modifiedAt`.
- **Push (`_push`):** builds payload, encrypts the whole snapshot with
  AES-GCM **off the UI thread** (`Isolate.run`), POSTs; on 409 re-pulls and
  reconciles; on success bumps revision to `baseRevision + 1`.
- **Debounced local-change push (`_onLocalDataChange`):** fired from
  `ref.listen` on all seven data providers + settings; sets `syncDirty`,
  records `syncLastLocalWriteAt`, schedules a 3-second debounced
  `_pushChanges`. Emissions are suppressed for 3 s after an import
  (`_suppressEmissionsUntil`) to avoid echoing its own writes. No-op pushes
  are skipped by comparing the local snapshot hash to `syncLastPayloadHash`.
- **Sign-out (`signOut`):** pings `/api/health` first (`SyncApi.checkHealth`,
  5 s timeout); if the server is unreachable, returns `false` so the caller
  can prompt the user before proceeding (the token would otherwise stay
  valid server-side for up to 30 days). `force: true` clears locally
  regardless.
- **Account deletion (`deleteAccount`):** calls `SyncApi.deleteAccount`
  (`POST /api/account/delete`), then `_clearLocalSession`. Surfaces errors
  via `SyncState.error`.
- CPU-heavy work (hashing, encryption, decryption) always runs in isolates.

---

## 7. Terminal layer — `lib/core/terminal/`

- `themes.dart` — 37 terminal color-scheme presets: the built-in **Connexia**
  theme (driven by `AppColors.*` so it follows custom palettes) plus 36
  community schemes (Dracula, Nord, Tokyo Night, Catppuccin Mocha, …).
  `terminalThemeByName(name)` falls back to the Connexia preset.
- `scrollback_search.dart` — case-insensitive search over the scrollback
  buffer with a highlight overlay. `SearchMatch {line, startCol, endCol}`;
  highlights are xterm `TerminalHighlight`s built from buffer anchors.

### Vendored xterm — `third_party/xterm`

The `xterm` package is vendored and patched for:

- **Pixel-accurate resize** (`_syncViewportSize` in `terminal_screen.dart` is
  the single resize driver; `autoResize: false` on the view avoids conflicting
  window changes for pixel-aware TUIs like tmux).
- **Live-TUI selection** — selecting text in a moving terminal (top, htop,
  log tails) and copying it even while the screen redraws.

Keep patches localized; see `third_party/xterm/pubspec.yaml`.

---

## 8. UI layer — `lib/ui/`

### 8.1 Navigation model

Two-tiered:

- An outer `appSectionProvider` (`StateProvider<AppSection>`) swaps an
  `IndexedStack` of the eight screens (see `nav.dart` for `enum AppSection`).
- A nested `Navigator` (`appNavigatorKey`) handles pushed routes (e.g. SFTP)
  **below** the persistent title bar / tabs.

### 8.2 Cross-screen communication via providers

Rather than callbacks, screens publish shared transient UI through Riverpod
providers:

- Editor requests: `hostEditorRequestProvider`, `groupEditorRequestProvider`,
  `snippetEditorRequestProvider` — the consuming screen consumes and clears
  immediately.
- Floating multi-select bar: `selectionBarProvider`
  (`StateProvider<SelectionBarData?>`). Only the active section may publish
  it (checked against `appSectionProvider`), and section switches clear it.

### 8.3 Screens (`lib/ui/screens/`)

| Screen | Role |
|---|---|
| `home_screen.dart` | Root scaffold: custom `WindowTitleBar` (desktop) / mobile title bar, nested navigator, `_AppShell` with sidebar + `IndexedStack` of sections. |
| `hosts_screen.dart` | Host & group management: search, group drill-down, rubber-band multi-select, host/group cards, editor panels. Largest management screen (~1770 lines). |
| `keys_screen.dart` | SSH key management: import (manual / file / drag-drop), generate via `ssh-keygen`, set passphrase, delete. Uses the shared `BandSelection` mixin. |
| `known_hosts_screen.dart` | Host-key registry: copy fingerprint, remove. |
| `snippets_screen.dart` | Reusable commands: run/paste into sessions, sort, editor panel. |
| `logs_screen.dart` | Paginated session history (page size 50), infinite scroll, clear. |
| `settings_screen.dart` | Four categories: Account, Terminal, Database, About. |
| `terminal_screen.dart` | All SSH sessions in an `IndexedStack` of `_TerminalPane`s; keyboard handling, search overlay, snippets sidebar, mobile key toolbar, reconnect/auto-retry views. |
| `sftp_screen.dart` | Two-pane SFTP file manager: local↔remote, host-to-host, transfers with progress/cancel, dual drag & drop, chmod/rename/delete. Largest screen (~3030 lines). |

### 8.4 Widgets (`lib/ui/widgets/`)

| Widget | Role |
|---|---|
| `sidebar.dart` | Left nav rail; 224px expanded (≥1160px) / 64px collapsed. |
| `window_title_bar.dart` | Custom desktop chrome: home/SFTP buttons, session tabs (status underline, inline rename, context menu), sidebar toggle, window controls; persists geometry (debounced 400 ms); `WindowResizeHandles` restore native resizing on the frameless window. |
| `quick_connect_sheet.dart` | Ad-hoc connection bottom sheet with optional "Save this host". |
| `host_details_panel.dart` | Host/group editor panels (auto-save, vault-encrypted passwords, group credential defaults, sticky Connect). |
| `key_details_panel.dart` | Manual key entry + `ssh-keygen` generation panels. |
| `key_select_field.dart` | Identity dropdown `FormField<String?>` replacement. |
| `multi_select_bar.dart` | Floating "N selected" pill with actions. |
| `band_selection.dart` | Shared rubber-band drag-selection mixin (keys / known hosts / snippets; hosts has an older inline copy). Features Ctrl-add, long-press arming on touch, edge auto-scroll. |
| `account_settings_panel.dart` | Cloud-sync account UI: register/login, email verification, TOTP 2FA, sync status, sign out. |
| `database_settings_panel.dart` | DB diagnostics (file path, WAL sizes, per-table row counts) + JSON export. |

### 8.5 Theming

- `app_colors.dart` — `AppThemePalette` (12 named colors, JSON-persisted) and
  `AppColors`, an `abstract final class` of **mutable statics** so a
  user-selected palette can be swapped at runtime via `applyPalette(palette)`
  (callers must rebuild). Also `hostColorOptions` (8 selectable accents).
- `app_theme.dart` — `buildAppTheme()` returns a Material 3 dark `ThemeData`
  seeded from `AppColors.accent`, using the **Inter** font.

### 8.6 Utilities

- `context_menu.dart` — `showContextMenuAt<T>` wraps `showMenu` and converts
  screen-global coordinates into the nearest overlay's local space. Required
  because screens live in a nested navigator below the title bar; naive
  global coords render menus too low.

---

## 9. Credential resolution & connection flows

`lib/ui/state/connection_helpers.dart` centralizes credential resolution
(shared by terminal and SFTP connect):

- `resolveCredentials(ref, host)` implements **group credential inheritance**
  (host wins, group falls back), decrypting passwords via the vault; returns
  `null` if unresolvable.
- `connectSavedHost(context, ref, host)` — bumps `lastConnected`, resolves
  credentials, prompts via `promptCredentials` if needed, opens a session via
  `sessionManagerProvider.openSession(HostConnectionRequest(...))`, then
  switches to `AppSection.terminals`.
- `quickConnect(ref, request)` — raw connection request, switches to
  terminals.
- `resolveKeyMaterial(ref, identityId)` — decrypts the PEM and passphrase
  from the vault.

`lib/ui/state/key_utils.dart`:

- `computeKeyFingerprint(pemText)` — OpenSSH `SHA256:` fingerprint.
- `generateSshKey(...)` — shells out to Windows `ssh-keygen.exe` (found via
  `_findSshKeygen`), supports ED25519 / ECDSA / RSA / ML-DSA, parses outputs
  into `GeneratedKey`, cleans up temp dir; throws `GenKeyException` on
  failure (ML-DSA requires OpenSSH ≥ 9.9).

---

## 10. Sync server — `server/`

A Go server split across `main.go` (handlers, HTTP, crypto, sessions,
rate-limiting), `store.go` (storage abstraction), `dashboard.go` (stats +
admin), and `site.go` (public website). Dependencies: stdlib +
`golang.org/x/crypto` (scrypt), `github.com/jackc/pgx/v5` (Postgres) and
`modernc.org/sqlite` (pure-Go SQLite, no CGO). It is a drop-in replacement
for the original Node.js server — same endpoints and on-disk format.

### Storage — `store.go`

The server keeps its hot state in memory and persists every mutation through
a `Store` interface. Two backends, selected by environment:

| Backend | When | Path |
|---|---|---|
| PostgreSQL | `DATABASE_URL` set | via pgx (PgBouncer works transparently) |
| SQLite | otherwise | `<DATA_DIR>/sync.db` (pure-Go, WAL + 5 s busy timeout) |

Schema (shared between both, differing only in placeholder style `$1` vs
`?`): a `users` table and a `blobs` table, with an `is_admin` column on
`users`. `migrateFromJSON` imports a legacy `<DATA_DIR>/users.json` +
`blobs/` directory into the database on first boot (only when empty) and
leaves the JSON files untouched as a backup.

### Security posture

- Passwords stored only as **scrypt** hashes (params match Node's
  `crypto.scryptSync` defaults so existing data verifies).
- Snapshots are opaque ciphertext (client encrypts with a password-derived
  key); server enforces a 6 MB blob limit.
- Sessions are 32-byte random bearer tokens, TTL 30 days.
- Login uses a timing-safe compare against a random salt even for unknown
  emails so response time does not leak which emails exist.
- Email verification (6-digit code, 10-min TTL, rate-limited resend) and
  TOTP 2FA (RFC 6238, ±1 step window).
- **Per-IP rate limiting** (in-memory fixed-window, reset on restart):
  register 10/hour, login 10/min, verify + 2FA 10/min, resend 5/min,
  sync POST 120/min. `clientIP` honors `X-Forwarded-For` for reverse-proxy
  deployments. Over-limit → `429`.

### Admin system

- The **first account** registered on a fresh server is promoted to admin
  automatically and is trusted immediately (admin accounts skip email
  verification). `GET /api/setup/status` → `{ "adminExists": bool }` lets
  clients detect the first-run state.
- Admin endpoints (require the admin account's bearer token):
  `GET /api/admin/users` (list all accounts), `POST /api/admin/users/delete`
  (`{ id }`), `POST /api/admin/users/role` (`{ id, isAdmin }` — promote /
  demote). The last admin can never be deleted or demoted.
- `account.delete` (`POST /api/account/delete`) lets a user delete their
  own account (and its snapshot) directly.

### Web dashboard & website

The server serves the full Connexia website from the same binary
(templates in `server/templates/`, embedded via `//go:embed`):

- `/` — landing page with **live server stats** (accounts, snapshots,
  encrypted bytes, uptime) rendered server-side (SEO-friendly) and
  auto-refreshed by `/api/public/stats`.
- `/features`, `/downloads`, `/docs`, `/pricing` — marketing pages.
- `/register`, `/login`, `/account` — browser-based account management.
- `/admin` — admin console (first-run registration when no admin exists,
  then requires admin sign-in).
- `/robots.txt`, `/sitemap.xml`, `/assets/site.css`, `/assets/site.js`.

Full endpoint reference: [API.md](API.md).

---

## 11. Testing strategy

Tests live in `test/` (15 files, ~40 tests). Coverage areas:

| Area | Files |
|---|---|
| Terminal emulation | `resize_test.dart`, `terminal_resize_test.dart`, `terminal_chain_resize_test.dart`, `terminal_behavior_test.dart`, `terminal_theme_test.dart`, `tui_toggle_test.dart`, `alt_tui_toggle_test.dart` |
| Selection stability | `selection_sticky_test.dart`, `selection_live_tui_test.dart` |
| Crypto / keys | `vault_test.dart`, `ssh_key_parse_test.dart` |
| Sync | `sync_test.dart` |
| Other | `hosts_ordering_test.dart`, `utf8_stream_decoder_test.dart`, `widget_test.dart` |

Run with `flutter test`. The terminal tests exercise the vendored xterm
directly; vault tests use `InMemorySecretStorage`.

---

## 12. Key invariants to preserve

1. **Single `AppDatabase` per process** — never open the DB twice (see
   `main.dart`).
2. **Never store plaintext secrets** — everything sensitive goes through
   `Vault` (AES-256-GCM) before touching disk or sync.
3. **Keep heavy crypto off the UI thread** — use `compute` / `Isolate.run`
   (key unlock, snapshot encrypt/decrypt, hashing).
4. **Bound SSH connect fan-out** — respect `maxConcurrentConnects`.
5. **Screen-transient UI via providers, not callbacks** — editor requests and
   the selection bar flow through Riverpod and are cleared immediately.
6. **Sync is additive and debounced** — local-first; never block normal
   operation on the network.
7. **Custom chrome positioning** — any popup/menu opened from a screen must go
   through `showContextMenuAt` (nested-navigator coordinate translation).
