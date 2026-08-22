# Connexia

An SSH client and terminal emulator written in Flutter — one
codebase for **Windows, macOS, Linux, iOS and Android**.

Connexia combines a full-featured host/key manager, an interactive terminal
with dozens of color schemes, multi-session tabs, an SFTP file browser and an
encrypted vault, all offline-first with an optional zero-knowledge sync server.

## Documentation

| Document | Audience | Contents |
| -------- | -------- | -------- |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Contributors | Layered design, module breakdown, data model, encryption model, SSH lifecycle, sync protocol, key code paths |
| [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) | Contributors | Build/run/test per platform, codegen, conventions, troubleshooting |
| [`docs/API.md`](docs/API.md) | Integrators | Sync-server REST API and the client-side snapshot/payload format |
| [`server/README.md`](server/README.md) | Operators | Deploying and configuring the self-hosted sync server |

## Features

- **Host manager** — groups, tags, colors, favorites, search (hosts, groups,
  addresses, tags), duplicate, delete
- **SSH connections** — password or private-key auth (PEM, OpenSSH,
  passphrase-protected), quick connect for ephemeral sessions
- **Host-key verification** — trust-on-first-use with fingerprint dialog and
  change detection
- **Multi-session tabs** — parallel connections in the title bar, per-tab
  status, rename, duplicate, reconnect with an auto-retry countdown
- **Interactive terminal** — xterm emulation with CJK/emoji support, 256
  colors, IME input, scrollback, pixel-exact resize, and 37 color themes
  (default: Connexia)
- **Selection that survives live TUIs** — select text in a moving terminal
  (top, htop, log tails) and copy it even while the screen redraws
- **SFTP browser** — navigate, upload/download with progress, new folder,
  rename, delete, chmod, drag & drop
- **Snippets** — a dockable sidebar with commands you can insert, run or paste
  into the active session
- **Key manager** — generate keys, import PEM/OpenSSH keys, view fingerprints
- **Known hosts** — track and remove trusted host keys
- **Session logs** — every connection is recorded with start/end timestamps
- **Encrypted vault** — passwords and keys are encrypted with AES-256-GCM; the
  master key lives in the OS keychain (Windows: HKCU registry; other
  platforms: a user-private 0600 file)
- **Zero-knowledge sync** — optional self-hosted server that stores only an
  encrypted snapshot; it can never read your data (see
  [`server/`](server/README.md))

## Sections

| Section        | Purpose                                     |
| -------------- | ------------------------------------------- |
| Hosts          | Manage and connect to hosts                 |
| Keys           | Generate, import and manage SSH keys        |
| Known hosts    | Trusted host keys and fingerprints          |
| Snippets       | Reusable commands and shell snippets        |
| Logs           | Session history                             |
| Settings       | Theme, terminal font size, sync, window     |
| Terminals      | Open terminal sessions (also as tabs above) |
| SFTP           | Remote file browser                         |

## Keyboard shortcuts

| Shortcut         | Action                              |
| ---------------- | ----------------------------------- |
| Ctrl+Shift+C     | Copy selection                      |
| Ctrl+Shift+V     | Paste                               |
| Ctrl+Shift+F     | Find in terminal scrollback         |
| Ctrl+= / Ctrl+-  | Zoom font in / out                  |
| Ctrl+0           | Reset font size                     |
| Ctrl+wheel       | Zoom font                           |

Plain Ctrl+C / Ctrl+A / Ctrl+V are forwarded to the remote shell, so
screen/readline keybindings keep working.

## Stack

| Concern      | Package                                                |
| ------------ | ------------------------------------------------------ |
| Terminal     | [xterm](https://pub.dev/packages/xterm) (vendored at `third_party/xterm`, patched for pixel-accurate resizing and live-TUI selection) |
| SSH/SFTP     | [dartssh2](https://pub.dev/packages/dartssh2) (pure Dart) |
| State        | [flutter_riverpod](https://pub.dev/packages/flutter_riverpod) |
| Database     | [drift](https://pub.dev/packages/drift) (SQLite)       |
| Crypto       | [cryptography](https://pub.dev/packages/cryptography) (AES-256-GCM, PBKDF2, scrypt) |
| Window       | [window_manager](https://pub.dev/packages/window_manager) (frameless custom chrome) |

## Getting started

```sh
flutter pub get
flutter run -d windows        # or -d macos / -d linux / -d <android/ios device>
```

After changing the drift database schema, regenerate the code:

```sh
dart run build_runner build
```

## Building per platform

| Platform | Prerequisites                                                    | Command                |
| -------- | ---------------------------------------------------------------- | ---------------------- |
| Windows  | Visual Studio (Desktop C++)                                       | `flutter build windows` |
| macOS    | Xcode (build on a Mac)                                            | `flutter build macos`  |
| Linux    | `clang`, `cmake`, `ninja`, GTK dev headers (build on Linux)       | `flutter build linux`  |
| iOS      | Xcode + iOS signing (build on a Mac)                              | `flutter build ios`    |
| Android  | Android Studio / SDK                                              | `flutter build apk`    |

## Releases / installation

Prebuilt binaries are attached to every [GitHub release](https://github.com/Theyka/Connexia/releases):

- `connexia-setup.exe` — Windows (x64) installer
- `connexia-linux-x64.tar.gz` — Linux (x64) bundle
- `app-release.apk` — Android (arm64, armv7, x86_64)

### Linux

The tarball is a self-contained bundle — extract it and run the binary from
inside `bundle/` (it needs to find its `lib/` and `data/` next to it):

```sh
tar -xzf connexia-linux-x64.tar.gz
cd bundle
./connexia
```

Optional: install system-wide and add a launcher:

```sh
sudo mkdir -p /opt/connexia
sudo cp -r bundle /opt/connexia/
sudo ln -s /opt/connexia/bundle/connexia /usr/local/bin/connexia
```

```ini
# ~/.local/share/applications/connexia.desktop
[Desktop Entry]
Name=Connexia
Exec=/opt/connexia/bundle/connexia
Icon=utilities-terminal
Terminal=false
Type=Application
Categories=Network;
```

Runtime dependencies (Ubuntu/Debian): `sudo apt install libgtk-3-0 libsecret-1-0`.

## Verification

```sh
flutter analyze
flutter test
```

The test suite covers terminal emulation (resize/reflow, CJK, TUI toggles),
selection stability, vault crypto, SSH key parsing, sync snapshots and host
ordering (40 tests).

## Sync server

Connexia can sync hosts, keys and settings between devices through a
zero-knowledge backend. The official server runs at
`https://sync.connexia.run` and is the default in release builds — you can
also run your own in minutes:

```bash
cd server
go build -o syncserver . && ./syncserver
```

It listens on `http://0.0.0.0:8047`, stores only scrypt password hashes and
AES-256-GCM encrypted snapshots, and never sees your plaintext data.
Point the app at your server in Settings → Sync. See
[`server/README.md`](server/README.md) for setup, TLS and backups.

## Project structure

```
lib/
  main.dart               entry; single ProviderContainer, window setup
  app.dart                MaterialApp root
  core/
    db/                   drift schema (schemaVersion 7) + migrations
    crypto/               Vault (AES-256-GCM) + platform secret storage
    ssh/                  SshService, SessionManager, HostKeyStore (TOFU)
    sync/                 SyncApi, SyncCrypto, Snapshot, SyncController
    terminal/             37 terminal color themes, scrollback search
  ui/
    screens/              hosts, keys, known hosts, snippets, logs,
                          settings, terminals, sftp
    widgets/              panels, sidebar, custom title bar, forms
    state/                Riverpod providers, nav, settings, connection helpers
    theme/                mutable palette + Material 3 dark theme
third_party/xterm/        vendored, patched xterm (pixel resize + live-TUI selection)
server/                   Go zero-knowledge sync server (Postgres/SQLite storage,
                          admin dashboard, marketing website)
installer/                Inno Setup script for the Windows installer
test/                     15 files, ~40 tests
```

A full walkthrough of each module is in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
