[Русская версия](README.ru.md)

# Docmost

A native macOS app that embeds the [Docmost](https://docmost.com/) web UI for
several of your own servers. Each server is a tab in a single window; switching
tabs switches servers, and sessions (logins) persist across launches.

## Requirements

- macOS 14.0 or newer
- A Swift toolchain (Xcode 15+ or the Command Line Tools)

## Build & run

The primary path is `make`:

```sh
make build
make run
```

`make build` runs `./build-app.sh`, which builds the release binary with Swift
Package Manager and wraps it into `Docmost.app` with a correct `Info.plist` and
an app icon, then ad-hoc signs the bundle. `make run` builds the app and
launches it.

You can also run the same steps directly:

```sh
swift build       # SwiftPM debug build, no .app bundle
./build-app.sh    # full release build and packaging into Docmost.app
open Docmost.app  # launch the built app
```

## Adding servers

Open “Servers…” in the tab bar (or press Cmd+N — “Add Server…”), then enter a
name and an address. If you omit the scheme, `https://` is prepended
automatically. The server list is stored locally.

## Features

- Per-domain persistent sessions: cookies and logins survive restarts via
  WebKit's persistent data store, isolated per domain.
- External link clicks (a link to a different domain) open in the default
  browser. Redirects and SSO/OAuth flows stay inside the app.
- Files that can't be shown inline download to `~/Downloads` and are revealed
  in Finder.
- A native file picker (NSOpenPanel) is used for uploads.
- Page zoom via ⌘+ / ⌘− / ⌘0; the zoom level is persisted.

## Development

All routine actions go through `make` (see `make help`):

| Command      | Purpose                                               |
|--------------|-------------------------------------------------------|
| `make`       | Show the list of targets (same as `make help`)        |
| `make build` | Release build of `Docmost.app` via `build-app.sh`     |
| `make run`   | Build and launch `Docmost.app`                        |
| `make test`  | Run the unit tests (`swift test`)                     |
| `make debug` | SwiftPM debug build (no `.app`)                       |
| `make icon`  | Regenerate the app icon (`Resources/AppIcon.icns`)    |
| `make clean` | Remove build artifacts                                |

The tests live in `Tests/DocmostCoreTests` and run via `make test`. They cover
the pure logic in `Sources/DocmostCore` (the server models and storage).

## Configuration

The app needs no environment variables or secrets: servers are configured in the
UI and stored locally in `UserDefaults`.
