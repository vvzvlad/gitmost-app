[Русская версия](README.ru.md)

# gitmost

A native macOS app that embeds the gitmost web UI for
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

`make build` builds the release binary with Swift Package Manager and wraps it
into `gitmost.app` with a correct `Info.plist` and an app icon, then ad-hoc signs
the bundle. `make run` builds the app and launches it.

You can also run the steps directly:

```sh
swift build       # SwiftPM debug build, no .app bundle
make build        # full release build and packaging into gitmost.app
open gitmost.app  # launch the built app
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

## Built-in JS/CSS

The app no longer injects any custom JavaScript or CSS — it shows the web UI
exactly as the server delivers it. The `js`/`css` constants in
`Sources/DocmostCore/UserScripts.swift` are now empty and remain only as an
extension point if custom injection is needed in the future.

## Development

All routine actions go through `make` (see `make help`):

| Command      | Purpose                                               |
|--------------|-------------------------------------------------------|
| `make`       | Show the list of targets (same as `make help`)        |
| `make build` | Release build of `gitmost.app` (compile+bundle+sign)  |
| `make run`   | Build and launch `gitmost.app`                        |
| `make test`  | Run the unit tests (`swift test`)                     |
| `make debug` | SwiftPM debug build (no `.app`)                       |
| `make icon`  | Regenerate the app icon (`Resources/AppIcon.icns`)    |
| `make clean` | Remove build artifacts                                |

The tests live in `Tests/DocmostCoreTests` and run via `make test`. They cover
the pure logic in `Sources/DocmostCore` (the server models and storage).

## Configuration

The app needs no environment variables or secrets: servers are configured in the
UI and stored locally in `UserDefaults`.
