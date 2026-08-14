# Connexia

An SSH client and terminal emulator written in Flutter — one
codebase for **Windows, macOS, Linux, iOS and Android**.

Connexia combines a full-featured host/key manager, an interactive terminal
with dozens of color schemes, multi-session tabs, an SFTP file browser and an
encrypted vault, all offline-first with an optional zero-knowledge sync server.

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
self-hosted, zero-knowledge backend. Run it in minutes:

```bash
cd server
npm start
```

It listens on `http://0.0.0.0:8047`, stores only scrypt password hashes and
AES-256-GCM encrypted snapshots, and never sees your plaintext data.
See [`server/README.md`](server/README.md) for setup, TLS and backups.
