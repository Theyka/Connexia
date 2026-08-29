# Connexia

[![License](https://img.shields.io/badge/License-AGPL--3.0-orange?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0iI2ZmZiIgZD0iTTEgMjFoMTJ2Mkgxdi0yek01LjI0IDguMDdsMi44My0yLjgzIDE0LjE0IDE0LjE0LTIuODMgMi44M0w1LjI0IDguMDd6TTEyLjMyIDFsNS42NiA1LjY2LTIuODMgMi44My01LjY2LTUuNjZMMTIuMzIgMXpNMy44MyA5LjQ4bDUuNjYgNS42Ni0yLjgzIDIuODNMMSAxMi4zMWwyLjgzLTIuODN6Ii8+PC9zdmc+)](https://www.gnu.org/licenses/agpl-3.0.html)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-%2302569B?style=for-the-badge&logo=flutter&logoColor=white)](https://flutter.dev)
[![Latest release](https://img.shields.io/github/v/release/Theyka/Connexia?style=for-the-badge&logo=github&logoColor=white&label=Release)](https://github.com/Theyka/Connexia/releases/latest)

An SSH client, terminal emulator, SFTP browser and encrypted vault — one
codebase for **Windows, macOS, Linux, iOS and Android** built with Flutter.

---

## Download

| Platform | Installer | Notes |
| -------- | --------- | ----- |
| **Windows** (x64) | [![Download](https://img.shields.io/badge/Download-blue?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB2aWV3Qm94PSIwIDAgODggODgiIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyIgaGVpZ2h0PSI4OCIgd2lkdGg9Ijg4Ij48cGF0aCBkPSJtMCAxMi40MDIgMzUuNjg3LTQuODYuMDE2IDM0LjQyMy0zNS42Ny4yMDN6bTM1LjY3IDMzLjUyOS4wMjggMzQuNDUzTC4wMjggNzUuNDguMDI2IDQ1Ljd6bTQuMzI2LTM5LjAyNUw4Ny4zMTQgMHY0MS41MjdsLTQ3LjMxOC4zNzZ6bTQ3LjMyOSAzOS4zNDktLjAxMSA0MS4zNC00Ny4zMTgtNi42NzgtLjA2Ni0zNC43Mzl6IiBmaWxsPSIjZmZmIi8+PC9zdmc+)](https://github.com/Theyka/Connexia/releases/latest/download/connexia-setup.exe) | Inno Setup installer, signed |
| **Linux** (x64) | [![Download](https://img.shields.io/badge/Download-gray?style=for-the-badge&logo=linux&logoColor=white)](https://github.com/Theyka/Connexia/releases/latest/download/connexia-linux-x64.tar.gz) | Self-contained bundle |
| **Android** | [![Download](https://img.shields.io/badge/Download-green?style=for-the-badge&logo=android&logoColor=white)](https://github.com/Theyka/Connexia/releases/latest/download/app-release.apk) | Universal APK |

> **macOS and iOS** — installable bundles are not yet attached to every release
> (awaiting CI signing). Build from source with `flutter build macos` or
> `flutter build ios`.

---

## Quick start

1. **Download** the installer for your platform from the table above.
2. **Launch** Connexia — the **Hosts** screen opens.
3. **Add a host** — tap the **+** button, enter a label, address, SSH port,
   username and authentication (password or private key).
4. **Connect** — tap the host row. The terminal opens in a new tab.
5. **Open a tunnel** (optional) — switch to the **Tunnels** sidebar entry,
   create a local (`-L`), dynamic SOCKS (`-D`) or remote (`-R`) forward
   against any saved host, then hit Start. The bind endpoint is one click
   away to copy.
6. **Sync** (optional) — go to **Settings → Sync**, enter
   `https://sync.connexia.run`, create a free account, and your hosts,
   keys, tunnels and settings are encrypted and synced between all your
   devices.

---

## Features

- **Host manager** — groups, tags, colors, favorites, search (hosts, groups,
  addresses, tags), duplicate, delete
- **SSH connections** — password or private-key auth (PEM, OpenSSH,
  passphrase-protected), quick connect for ephemeral sessions
- **Host-key verification** — trust-on-first-use with fingerprint dialog and
  change detection
- **Multi-session tabs** — parallel connections in the title bar, per-tab
  status, rename, duplicate, reconnect with an auto-retry countdown
- **Workspace tiling** — drag sessions into a tiled grid inside the same
  window, resize and reorder by dragging to the title bar
- **SSH tunneling** — local port forwards (`-L`), dynamic SOCKS proxies
  (`-D`) and remote forwards (`-R`); auto-start at launch, live status,
  one-click copy of the bind endpoint, full integration with sync and
  team workspaces
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
- **Session & tunnel logs** — every connection and tunnel event is recorded
  with start/end timestamps, errors and stack traces; device-local, never
  synced
- **Encrypted vault** — passwords and keys are encrypted with AES-256-GCM; the
  master key lives in the OS keychain (Windows: HKCU registry; other
  platforms: a user-private 0600 file)
- **Zero-knowledge sync** — optional cloud sync that stores only an encrypted
  snapshot; the server can never read your data
- **Team workspaces** — share hosts, groups, keys, snippets and tunnels with
  your team in end-to-end encrypted workspaces, with a metadata-only audit
  log of who changed what

---

## SSH tunneling

The **Tunnels** screen lets you forward traffic through any saved host
without leaving the app. Three modes are supported:

| Mode | What it does |
| ---- | ------------ |
| **Local** (`-L`) | Listen on a local port; forward every connection to `host:port` on the remote side. Classic "access an internal service" pattern. |
| **Dynamic** (`-D`) | Spin up a SOCKS5 proxy on a local port. Point your browser or system proxy at it to route traffic through the remote host. |
| **Remote** (`-R`) | Listen on a port on the remote host and tunnel back to a local address — useful for exposing a local dev server behind NAT. |

Each tunnel can be linked to a saved host (uses that host's credentials)
or stand alone (own address / username / password / key). Mark any tunnel
as **auto-start** and Connexia will bring it up automatically every time
the app launches.

### Live status & logs

Every tunnel shows its current state as a colored accent along the bottom
of its card (running / connecting / error / stopped), matching the
terminal-tab status palette. Click the bind endpoint to copy it to the
clipboard. The **Logs** screen has a dedicated **Tunnels** tab with the
last events per tunnel, including full stack traces on failure —
device-local, never synced.

### Sync & workspaces

Tunnel configs sync alongside everything else, so creating a tunnel on
your laptop makes it appear on your desktop seconds later. Team workspaces
can also share tunnels — everyone in the workspace sees the same set,
with their own runtime status.

---

## Sync server

### Free official instance — `sync.connexia.run`

Connexia ships with `https://sync.connexia.run` as the default sync endpoint.
It is **free to use** for everyone:

1. Open **Settings → Sync**.
2. Tap **Sign out** (if shown) then **Sign in**.
3. **Create an account** — enter your email and a password. A verification
   code is sent to your inbox (check spam).
4. Once verified, your vault is encrypted on-device with your password and
   pushed to the server. The server stores only the ciphertext and an scrypt
   password hash — it can never read your hosts, keys, tunnels or passwords.
5. Sign in on another device with the same account and your data appears
   automatically.

Tunnels were added to the synced snapshot without any server-side changes:
the sync backend treats payloads as opaque encrypted blobs, so new fields
ride along inside the existing envelope.

### Self-hosted server

You can run your own sync server anywhere (VPS, Raspberry Pi, Docker). The
server is a single Go binary with no runtime dependencies:

```bash
cd server
go build -o syncserver . && ./syncserver
```

It listens on `http://0.0.0.0:8047`. By default it stores data in a SQLite
file, or you can point it at PostgreSQL with `DATABASE_URL`.

**Docker:**
```bash
docker build -t syncserver server/
docker run -d --name syncserver -p 8047:8047 -v sync-data:/data syncserver
```

**Coolify / Fly.io / Railway —** see the [server README](server/README.md) for
full deployment guides, environment variables, TLS, SMTP and backup
instructions.

Prebuilt server binaries are attached to every
[GitHub release](https://github.com/Theyka/Connexia/releases):

| Platform | Binary |
| -------- | ------ |
| Linux (x64) | [`connexia-server-linux-x64`](https://github.com/Theyka/Connexia/releases/latest/download/connexia-server-linux-x64) |
| Windows (x64) | [`connexia-server-windows-x64.exe`](https://github.com/Theyka/Connexia/releases/latest/download/connexia-server-windows-x64.exe) |

---

## Team workspaces

Workspaces let a team share hosts, groups, keys, snippets and tunnels across
every member's devices, end-to-end encrypted. The server never sees the data
— it stores only ciphertext plus a metadata-only audit log.

### How it works

1. **Open Settings → Teams** and create a workspace. Connexia generates a
   per-account X25519 keypair on first use; the public key is uploaded to
   the server and the private key is wrapped with your password-derived
   sync key and stored alongside it.
2. **Invite members** by email. The server returns the invitee's public
   key; your client wraps the workspace data key with it and uploads the
   share. Only invited members can decrypt the workspace.
3. **Activate a workspace** to scope the Hosts / Groups / Keys / Snippets /
   Tunnels screens to that workspace. Switch back to **Personal scope** any
   time.
4. Every push records a server-side audit event automatically (who synced
   what revision, when, from which IP). The client additionally attaches a
   plaintext action summary (`host.create`, `key.delete`, …) so the audit
   log shows *what* changed without leaking data content.
5. **Rotate the workspace key** when a member leaves. A new workspace key
   is generated, the snapshot is re-encrypted, and every remaining member
   receives a new wrapped share. The removed member can no longer decrypt
   new revisions.

### Roles

| Role | Can |
| ---- | --- |
| **Owner** | Everything: manage members, rotate key, delete workspace, view audit |
| **Admin** | Manage members, sync, view audit |
| **Member** | Read/write hosts, groups, keys and snippets in the workspace |

### Zero-knowledge guarantee

The workspace data key is a random 256-bit key. It is wrapped per member
with an X25519 shared secret (your private key × their public key), so the
server only ever sees opaque ciphertext. Audit events record *who did
what* (actor email, action type, target, timestamp) but never the data
content — the same zero-knowledge property as personal sync.

---

## Installation

### Windows

Run `connexia-setup.exe` — the installer places Connexia in
`%ProgramFiles%\Connexia` and adds a shortcut to the Start Menu.

### Linux

The tarball is a self-contained bundle — extract it and run the binary from
inside `bundle/`:

```sh
tar -xzf connexia-linux-x64.tar.gz
cd bundle
./connexia
```

**Optional — system-wide install and launcher:**

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

**Runtime dependencies (Ubuntu/Debian):**
```sh
sudo apt install libgtk-3-0 libsecret-1-0
```

### macOS

```sh
flutter build macos
open build/macos/Build/Products/Release/connexia.app
```

### Android

Transfer the APK to your device and install it, or use `adb`:

```sh
flutter build apk --release
adb install build/app/outputs/flutter-apk/app-release.apk
```

### iOS

```sh
flutter build ios
open build/ios/iphoneos/Runner.app
```

---

## Keyboard shortcuts

| Shortcut | Action |
| -------- | ------ |
| Ctrl+Shift+C | Copy selection |
| Ctrl+Shift+V | Paste |
| Ctrl+Shift+F | Find in terminal scrollback |
| Ctrl+= / Ctrl+- | Zoom font in / out |
| Ctrl+0 | Reset font size |
| Ctrl+wheel | Zoom font |
| E | Edit card under cursor (hosts, groups, keys, snippets, tunnels) |
| Ctrl+Shift+N | New window |

All shortcuts are **configurable** in **Settings → Shortcuts** — click Record
on any action and press the key combination you prefer.

Plain Ctrl+C / Ctrl+A / Ctrl+V are forwarded to the remote shell, so
screen/readline keybindings keep working.

---

## Stack

| Concern | Package |
| ------- | ------ |
| Terminal | [xterm](https://pub.dev/packages/xterm) (vendored at `third_party/xterm`, patched for pixel-accurate resizing and live-TUI selection) |
| SSH/SFTP | [dartssh2](https://pub.dev/packages/dartssh2) (pure Dart) |
| State | [flutter_riverpod](https://pub.dev/packages/flutter_riverpod) |
| Database | [drift](https://pub.dev/packages/drift) (SQLite) |
| Crypto | [cryptography](https://pub.dev/packages/cryptography) (AES-256-GCM, PBKDF2, scrypt) |
| Window | [window_manager](https://pub.dev/packages/window_manager) (frameless custom chrome) |

---

## Building from source

```sh
flutter pub get
flutter run -d windows        # or -d macos / -d linux / -d <android/ios device>
```

After changing the drift database schema, regenerate the code:
```sh
dart run build_runner build
```

| Platform | Prerequisites | Command |
| -------- | ------------- | ------- |
| Windows | Visual Studio (Desktop C++) | `flutter build windows` |
| macOS | Xcode (build on a Mac) | `flutter build macos` |
| Linux | `clang`, `cmake`, `ninja`, GTK dev headers | `flutter build linux` |
| iOS | Xcode + iOS signing (build on a Mac) | `flutter build ios` |
| Android | Android Studio / SDK | `flutter build apk` |

---

## Verification

```sh
flutter analyze
flutter test
```

The test suite covers terminal emulation (resize/reflow, CJK, TUI toggles),
selection stability, vault crypto, SSH key parsing, sync snapshots,
migration upgrades across every schema version, tunnel forwarding and
host ordering (53 tests).

---

## Project structure

```
lib/
  main.dart               entry; single ProviderContainer, window setup
  app.dart                MaterialApp root, global keyboard shortcuts
  core/
    db/                   drift schema (schemaVersion 10) + migrations
                          hosts, groups, identities, known_hosts, snippets,
                          session_logs, themes, tunnels, tunnel_logs
    crypto/               Vault (AES-256-GCM) + platform secret storage
    ssh/                  SshService, SessionManager, TunnelManager,
                          HostKeyStore (TOFU)
    sync/                 SyncApi, SyncCrypto, Snapshot, SyncController,
                          TeamController (workspaces), TeamCrypto (X25519)
    terminal/             37 terminal color themes, scrollback search
    shortcuts.dart        Configurable keyboard shortcut model
    debug_log.dart        Fire-and-forget diagnostics log (%TEMP%)
  ui/
    screens/              hosts, keys, known hosts, snippets, tunnels,
                          logs, settings, teams, terminals, sftp
    widgets/              panels, sidebar, custom title bar, forms
    state/                Riverpod providers, nav, settings, connection helpers
    theme/                mutable palette + Material 3 dark theme
third_party/xterm/        vendored, patched xterm (pixel resize + live-TUI selection)
server/                   Go zero-knowledge sync server (Postgres/SQLite storage,
                          admin dashboard, marketing website)
installer/                Inno Setup script for the Windows installer
test/                     53 tests across 8 files
```

---

## Documentation

| Document | Audience | Contents |
| -------- | -------- | -------- |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Contributors | Layered design, module breakdown, data model, encryption model, SSH lifecycle, sync protocol, key code paths |
| [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) | Contributors | Build/run/test per platform, codegen, conventions, troubleshooting |
| [`docs/API.md`](docs/API.md) | Integrators | Sync-server REST API and the client-side snapshot/payload format |
| [`server/README.md`](server/README.md) | Operators | Deploying and configuring the self-hosted sync server |