# Connexia — Developer Guide

How to build, run, test and contribute to Connexia. For the design, see
[ARCHITECTURE.md](ARCHITECTURE.md); for the sync API, see [API.md](API.md).

---

## 1. Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Flutter SDK | `^3.12.2` (stable) | `pubspec.yaml` `environment.sdk` |
| Dart | bundled with Flutter | |
| Go | any recent (1.21+) | only for the sync server (`server/`) |

The sync server also pulls two Go modules at build time:
`github.com/jackc/pgx/v5` (PostgreSQL) and `modernc.org/sqlite` (pure-Go
SQLite, no CGO). `go build` resolves them automatically from `go.sum`.

Platform build toolchains (only the ones for the platforms you target):

| Platform | Prerequisites |
|---|---|
| Windows | Visual Studio with *Desktop development with C++* |
| macOS | Xcode (build on a Mac) |
| Linux | `clang`, `cmake`, `ninja`, GTK dev headers |
| iOS | Xcode + iOS signing (build on a Mac) |
| Android | Android Studio / SDK |

Verify your setup:

```sh
flutter doctor
```

---

## 2. Getting the code

```sh
git clone <repo-url> Connexia
cd Connexia
flutter pub get
```

`flutter pub get` also resolves the vendored `xterm` at
`third_party/xterm` (a path dependency). No extra step is needed.

---

## 3. Running the app

```sh
flutter run -d windows      # or: macos / linux
flutter run -d <device-id>  # iOS / Android device or emulator
```

To list devices: `flutter devices`.

### First-run behavior

On first launch Connexia:

- generates a 256-bit vault master key and stores it in the OS secret store
  (Windows: `HKCU\Software\Connexia`; other platforms: a 0600 file in the
  app-support directory);
- creates the SQLite database (`connexia.sqlite`) and runs migrations to
  `schemaVersion 7`;
- restores persisted window geometry (size/position/maximized), or uses
  the default `1280×800` (min `940×600`).

There is no sign-in step. Sync is optional and configured under
Settings → Account.

---

## 4. Code generation

Drift generates `database.g.dart` from `database.dart`. **Regenerate after
any schema change** (adding/removing tables or columns, changing types):

```sh
dart run build_runner build
```

For iterative work during schema changes, watch mode is handy:

```sh
dart run build_runner watch --delete-conflicting-outputs
```

The generated file is committed; if you forget to regenerate, the build
will fail to compile against the stale `_$AppDatabase` superclass.

---

## 5. Analyzing and testing

```sh
flutter analyze   # static analysis + flutter_lints (excludes third_party/**)
flutter test      # ~40 tests across 15 files
```

`analysis_options.yaml` excludes `third_party/**`, `build/**` and the
platform folders from analysis so the vendored xterm and generated runners
don't pollute the findings.

### What the tests cover

| Area | Test files |
|---|---|
| Terminal emulation (resize/reflow, CJK, TUI toggles) | `resize_test.dart`, `terminal_resize_test.dart`, `terminal_chain_resize_test.dart`, `terminal_behavior_test.dart`, `terminal_theme_test.dart`, `tui_toggle_test.dart`, `alt_tui_toggle_test.dart` |
| Selection stability (sticky + live TUI) | `selection_sticky_test.dart`, `selection_live_tui_test.dart` |
| Vault crypto | `vault_test.dart` |
| SSH key parsing | `ssh_key_parse_test.dart` |
| Sync snapshots | `sync_test.dart` |
| Host ordering | `hosts_ordering_test.dart` |
| UTF-8 stream decoding | `utf8_stream_decoder_test.dart` |

The vault tests use `InMemorySecretStorage` (from
`lib/core/crypto/secret_storage.dart`) so they run without a platform
keychain. When writing new tests that need a `Vault`, do the same.

---

## 6. Building per platform (release)

| Platform | Command | Output |
|---|---|---|
| Windows | `flutter build windows --release` | `build/windows/x64/runner/Release/` |
| macOS | `flutter build macos --release` | `build/macos/Build/Products/Release/` |
| Linux | `flutter build linux --release` | `build/linux/x64/release/bundle/` |
| iOS | `flutter build ios --release` | `.ipa` via Xcode archive |
| Android | `flutter build apk --release` | `build/app/outputs/flutter-apk/app-release.apk` |

### Windows installer

The Inno Setup script is `installer/connexia.iss`. The CI workflow
(`.github/workflows/release.yml`) builds it:

```sh
choco install innosetup -y
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\connexia.iss /DMyAppVersion=0.1.0
# produces build\installer\connexia-setup.exe
```

---

## 7. Releases (CI)

`.github/workflows/release.yml` is triggered by pushing a tag (`v*`) or
manually from the Actions tab. It builds **Windows (x64)** and
**Android (APK)**, packages a portable Windows zip + Inno Setup installer,
and attaches everything to a GitHub Release.

To cut a release:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The `release` job only attaches artifacts when triggered by a tag
(`workflow_dispatch` builds artifacts but doesn't publish).

---

## 8. Running the sync server locally

The server is a Go program split across `main.go` (handlers, HTTP, crypto,
sessions, rate-limiting), `store.go` (storage abstraction),
`dashboard.go` (stats + admin), and `site.go` (public website). See
[../server/README.md](../server/README.md) for full details.

```sh
cd server
go build -o syncserver .
./syncserver                 # listens on http://0.0.0.0:8047, SQLite in ./data
```

Storage defaults to a pure-Go SQLite file in `./data/sync.db`. To use
PostgreSQL instead, set `DATABASE_URL`:

```sh
DATABASE_URL=postgres://user:pass@host:5432/syncserver ./syncserver
```

Without `SMTP_HOST`, email-verification codes are printed to the server log
(useful for local testing). The first account registered on a fresh server
becomes the admin (skips email verification). Point the app at your local
server in Settings → Account → Sync server URL (e.g.
`http://<your-pc-ip>:8047`).

Data lives in `server/data/` (SQLite `sync.db` + legacy JSON backup) and is
gitignored — never commit it (it contains password hashes and session
tokens).

### Server tests

```sh
cd server
go test ./...
```

`store_pg_test.go` exercises the PostgreSQL storage backend (requires a
`DATABASE_URL` pointing at a test database; skipped when unset).

---

## 9. Project layout

```
lib/
  main.dart                 entry; single ProviderContainer, window setup
  app.dart                  MaterialApp root
  core/
    db/database.dart        drift schema + migrations + data access
    crypto/                 Vault (AES-256-GCM) + secret storage backends
    ssh/                    SshService, SessionManager, HostKeyStore
    sync/                   SyncApi, SyncCrypto, Snapshot, SyncController
    terminal/               terminal themes, scrollback search
    debug_log.dart          %TEMP%\connexia_debug.log (never throws)
  ui/
    screens/                8 section screens
    widgets/                panels, sidebar, title bar, selection, forms
    state/                  Riverpod providers, nav, settings, connection helpers
    theme/                  AppColors (mutable palette), Material theme
    utils/context_menu.dart
third_party/xterm/          vendored, patched xterm package
server/                     Go zero-knowledge sync server (main.go, store.go,
                            dashboard.go, site.go, templates/)
installer/connexia.iss       Inno Setup script for the Windows installer
.github/workflows/release.yml
test/                       15 test files (~40 tests)
```

A deeper walkthrough of each module is in [ARCHITECTURE.md](ARCHITECTURE.md).

---

## 10. Conventions

### Code style

- Lints come from `package:flutter_lints/flutter.yaml`. Run `flutter analyze`
  before committing; it must be clean.
- Single quotes are the project norm (though not enforced).
- **Do not add comments** unless explaining something non-obvious; the
  codebase is comment-light by design.
- Keep heavy work off the UI thread: use `compute(...)` or `Isolate.run(...)`
  for key unlocking, snapshot encryption/decryption and hashing. This is a
  recurring pattern in the core layer — match it.

### State management

- **Riverpod** (`flutter_riverpod`) is the only DI/state container. Core
  services are singletons in `lib/ui/state/providers.dart`.
- Reactive data flows through drift `watch*` streams wrapped in
  `StreamProvider`s; mutations go through `AppDatabase` methods and ripple
  back automatically.
- Cross-screen transient UI (editor panels, the multi-select bar) is
  communicated via providers, not callbacks. Consumers clear the request
  provider immediately after reading it.

### Secrets

- **Never** store plaintext passwords or key material. Always go through
  `Vault.encrypt(...)` before persisting to the DB or syncing.
- Settings keys in `excludedSettingKeys` (window geometry, all `sync*`
  metadata, `vaultMasterKey` is seeded separately) never leave the device.

### Database

- One `AppDatabase` per process (see `main.dart` — drift fails with
  "database is locked" otherwise on Linux).
- After schema changes: bump `schemaVersion`, add an `onUpgrade` branch,
  regenerate with `build_runner`, and commit the generated `database.g.dart`.

### Menus and popups

- Any popup opened from a screen must use `showContextMenuAt`
  (`lib/ui/utils/context_menu.dart`), which translates screen-global
  coordinates into the nested navigator's overlay space. Using `showMenu`
  directly renders menus in the wrong place.

---

## 11. Logging

Two separate file logs in `%TEMP%` (Windows) / the system temp dir:

| File | Written by | Purpose |
|---|---|---|
| `connexia_errors.log` | `main.dart` (`_setupErrorLogging`) | Unhandled framework + platform errors |
| `connexia_debug.log` | `lib/core/debug_log.dart` (`writeDebugLog`) | Diagnostic lines (rendering metrics, connect timing) |

`writeDebugLog` deliberately swallows all errors so logging can never break
the app. The user-facing connection history is the `SessionLogs` DB table,
not these files.

---

## 12. Troubleshooting

| Symptom | Fix |
|---|---|
| `database is locked` on Linux | Only one `AppDatabase` may exist per process; ensure you're not constructing a second one outside `appDatabaseProvider`. |
| Build fails referencing `_$AppDatabase` | Regenerate: `dart run build_runner build`. |
| Menus appear in the wrong place | Use `showContextMenuAt`, not `showMenu` directly. |
| `ssh-keygen` generation fails on Windows | `key_utils.dart` looks for `ssh-keygen.exe` via `_findSshKeygen`; ensure OpenSSH client is installed. ML-DSA requires OpenSSH ≥ 9.9. |
| Sync pushes nothing | Local snapshot hash matches `syncLastPayloadHash`; either no real change, or emissions were suppressed for 3 s after an import. |
| Terminal shows `�` in TUIs | Should not happen — `Utf8StreamDecoder` carries multibyte sequences across chunks. If you touched `session_manager.dart` streaming, re-check the decoder. |

---

## 13. Committing

- Run `flutter analyze` and `flutter test` before committing.
- Don't commit `server/data/`, the built `server/syncserver` binary, or
  anything under `build/`.
- The generated `database.g.dart` **is** committed (regenerate and commit it
  together with the schema change).
- Follow the existing concise commit-message style (see `git log --oneline`).
