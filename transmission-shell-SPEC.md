# Transmission Shell — Project Spec

Native macOS wrapper around the Transmission daemon's built-in web UI, adding
system-level magnet link and `.torrent` file handling via direct RPC calls.

## Goal

A remote-only Transmission client for macOS that:

- Runs natively on Apple Silicon (no Rosetta 2)
- Registers as the system handler for `magnet:` URLs
- Registers as the system handler for `.torrent` files
- Connects to an existing remote `transmission-daemon` — never runs a BitTorrent engine itself
- Displays the daemon's own web UI (no custom torrent list to maintain)

## Non-goals

- No embedded libtransmission, no local daemon, no seeding on the Mac
- No reimplementation of the torrent list / details / settings UI
- No JavaScript injection into the web UI (see Design Decisions)

---

## Design Decisions

### 1. WebView for display, native RPC for adding

The WebView is a dumb frame around `http://<host>:<port>/transmission/web/`.

Magnets and `.torrent` files are handled entirely in Swift by POSTing to
`/transmission/rpc`, then reloading the WebView to reflect the new torrent.

**Do not** inject JS to drive the web UI's "Add Torrent" dialog. That approach
breaks on every upstream UI refresh and is far more code than the RPC call.

### 2. Swift + WKWebView, not Electron/Tauri

- `WKWebView` ships with macOS — nothing to bundle
- Apple Silicon native by definition; the Rosetta question never arises
- Builds with Command Line Tools alone (`swift build`) — full Xcode not required
- Tauri handles deep links fine but file-type association is fiddlier
- Electron is ~200MB for a WebView already present on the system

### 3. Swift Package Manager, not an Xcode project

Use `Package.swift` + a `Scripts/build-app.sh` that assembles the `.app` bundle
(binary, `Info.plist`, icon, ad-hoc codesign). Keeps the repo buildable headless
and diffable in git.

---

## Architecture

```
Sources/
  TransmissionKit/          # UI-independent, unit-testable without a daemon
    RPCClient.swift         # session-id handshake, basic auth, torrent-add
    ServerConfig.swift      # host/port/path/scheme + Keychain-backed creds
    TorrentSource.swift     # enum { magnet(URL), file(Data) }
  TransmissionShell/        # the app
    AppDelegate.swift       # URL + file open handlers
    ShellWindow.swift       # WKWebView host
    SettingsView.swift      # server config UI
Scripts/
  build-app.sh              # → "dist/Transmission Shell.app"  [--dmg]
Package.swift
```

Keep `TransmissionKit` free of AppKit/SwiftUI imports so it can be exercised by a
plain `swift run KitTests` target (the CLT toolchain has no XCTest).

---

## RPC Implementation Notes

Endpoint: `POST {scheme}://{host}:{port}{path}` — default path `/transmission/rpc`.

Make the path configurable. Reverse-proxied setups often serve Transmission under
a subpath, and the default will be wrong for them.

### Session ID handshake (required)

The first POST returns **HTTP 409** with an `X-Transmission-Session-Id` response
header. Capture that value, set it as a request header, and retry the same body.

- Cache the session ID for the lifetime of the connection
- Any subsequent 409 means the ID rotated — re-handshake and retry **once**
- Guard the retry against infinite recursion

### Auth

HTTP Basic. Store the password in the **Keychain**, never in `UserDefaults` or a
plist. Handle the case where the daemon has auth disabled entirely.

### Adding a magnet

```json
{
  "method": "torrent-add",
  "arguments": { "filename": "magnet:?xt=urn:btih:..." },
  "tag": 1
}
```

Pass the magnet URI through verbatim as `filename`. Do not re-encode it.

### Adding a .torrent file

```json
{
  "method": "torrent-add",
  "arguments": { "metainfo": "<base64 of raw file bytes>" },
  "tag": 1
}
```

Read the file as `Data`, `.base64EncodedString()`, no line wrapping.

### Response handling

Success is `{"result": "success", "arguments": {...}}`. Check the `result` string —
a 200 status alone does not mean the add succeeded.

Two success shapes matter:

- `torrent-added` — new torrent
- `torrent-duplicate` — already present; treat as success, but say so in the
  notification rather than silently doing nothing

---

## System Integration

### Info.plist — magnet scheme

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>Magnet Link</string>
    <key>CFBundleURLSchemes</key>
    <array><string>magnet</string></array>
    <key>LSHandlerRank</key>
    <string>Owner</string>
  </dict>
</array>
```

### Info.plist — .torrent files

```xml
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key>
    <string>BitTorrent Document</string>
    <key>CFBundleTypeRole</key>
    <string>Viewer</string>
    <key>LSHandlerRank</key>
    <string>Owner</string>
    <key>LSItemContentTypes</key>
    <array><string>org.bittorrent.torrent</string></array>
    <key>CFBundleTypeExtensions</key>
    <array><string>torrent</string></array>
  </dict>
</array>
```

Include both `LSItemContentTypes` and `CFBundleTypeExtensions` — the UTI alone is
unreliable for files that arrive without proper type metadata.

### AppDelegate hooks

- `application(_:open:)` — receives both `magnet:` URLs and `file:` URLs for
  `.torrent` documents on modern macOS. Branch on `url.scheme`.
- Also implement `application(_:openFile:)` as a fallback for older delivery paths.
- Handle **launch-time** opens: if the app is cold-started by a magnet click, the
  callback can fire before the window and config are ready. Queue pending sources
  and drain them once `ServerConfig` has loaded.
- Handle **multiple** files in one drop (`application(_:open:)` receives an array).

### After a successful add

1. Post a `UNUserNotification` (torrent name if returned, else "Torrent added")
2. Reload the WebView so the new torrent appears
3. Do **not** force the window to the front on every add — it's hostile when
   queueing several magnets from a browser

---

## Configuration

Settings window with:

- Scheme (`http` / `https`)
- Host
- Port (default `9091`)
- RPC path (default `/transmission/rpc`)
- Web UI path (default `/transmission/web/`)
- Username / password (Keychain)
- "Test Connection" button → calls `session-get`, reports success/failure

Derive the WebView URL from the same config so there's one source of truth.

Allow self-signed certs behind a clearly-labelled opt-in toggle if the daemon is
fronted by a reverse proxy with an internal CA.

---

## Build & Distribution

```sh
swift build                          # compile
swift run TransmissionShell          # dev run
./Scripts/build-app.sh               # → "dist/Transmission Shell.app"
./Scripts/build-app.sh --dmg         # + portable .dmg
```

Ad-hoc codesign in the build script. Without an Apple Developer ID:

- First launch requires right-click → Open
- Run `lsregister -f -R "/Applications/Transmission Shell.app"` if LaunchServices
  doesn't pick up the associations
  (`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`)

---

## Known Friction (document in README)

1. **Gatekeeper** — ad-hoc signed builds need right-click → Open on first launch.
2. **LaunchServices caching** — associations may not register until `lsregister -f -R`
   is run, or until the app is launched once from `/Applications`.
3. **Browser-side handler prefs** — Chrome and Firefox cache protocol-handler
   choices independently of LaunchServices. If magnets still open elsewhere,
   clear the per-site protocol permission in the browser's settings.
4. **Web UI session** — if the daemon is behind an auth proxy, the WebView needs
   the same credentials as the RPC client. Feed basic auth into the WebView via
   `WKNavigationDelegate`'s authentication challenge handler.

---

## Testing

`swift run KitTests` should cover, without a live daemon:

- 409 handshake: first request 409s, second carries the session header
- Session-ID rotation triggers exactly one re-handshake, not a loop
- `torrent-add` envelope shape for magnet vs. metainfo
- Base64 encoding of a known small `.torrent` fixture
- `torrent-duplicate` is classified as success
- URL construction from `ServerConfig` across scheme/port/subpath permutations

Manual smoke test against a real daemon:

```sh
brew install transmission-cli
transmission-daemon --foreground --port 9091
```

---

## Build Order

1. `ServerConfig` + Keychain storage
2. `RPCClient` with the 409 handshake, verified by `session-get`
3. `KitTests`
4. WebView shell window + Settings
5. `Info.plist` associations + `AppDelegate` open handlers
6. `build-app.sh`, ad-hoc signing, `lsregister`
7. Notifications, multi-file open, cold-start queueing
