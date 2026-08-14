# TransmissionShell

A remote-only Transmission client for macOS: the daemon's own web UI in a native
window, plus system handling of `magnet:` links and `.torrent` files via direct RPC.
See [transmission-shell-SPEC.md](transmission-shell-SPEC.md) for the design.

**Status:** `TransmissionKit` only — server config, keychain storage, and the RPC
client. The app bundle, web view, and system associations aren't built yet.

## Build and test

```sh
swift build
swift test                     # unit tests; the live-daemon suite skips
./Scripts/integration-test.sh   # starts a throwaway daemon, runs everything, tears it down
```

The integration suite needs `transmission-daemon` (`brew install transmission-cli`).
The script runs it on port 19091 with authentication enabled, using temporary config
and download directories, so it never touches a daemon or settings you care about.
To point the same tests at a daemon you already have:

```sh
TS_INTEGRATION_BASE_URL=http://nas.local:9091/transmission/ \
TS_INTEGRATION_USERNAME=you \
TS_INTEGRATION_PASSWORD=secret \
swift test
```

## Server address

One field, matching the daemon's own `rpc-url` setting — the directory `rpc` and
`web/` are served beneath. `ServerConfig` normalizes what you type, so pasting the
URL out of a browser's address bar works: a trailing `web/`, `index.html`, or `rpc`
is dropped, a missing scheme becomes `http`, and a missing path becomes
`/transmission/`. A missing port stays missing and means the scheme's default, so
reverse-proxied setups on 80/443 work without inventing 9091.
