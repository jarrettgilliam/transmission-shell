# Transmission Shell

A remote-only Transmission client for macOS: the daemon's own web UI in a native
window, plus system handling of `magnet:` links and `.torrent` files via direct RPC.

Requires macOS 26 or later, Apple Silicon. It never runs a BitTorrent engine — it
talks to a `transmission-daemon` you already have.

## Install

```sh
curl -fsSL https://github.com/jarrettgilliam/transmission-shell/releases/latest/download/install.sh | zsh
```

Installs to `/Applications`, falling back to `~/Applications`, and registers the
`magnet:` and `.torrent` associations. The script is attached to every release if you
want to read it first.

The `.dmg` on [Releases](../../releases) is the alternative if you'd rather not pipe a
script to a shell — drag the app to Applications, then see
[Known friction](#known-friction), because a downloaded build needs a detour past
Gatekeeper that the install script avoids.

Either way, open Settings (⌘,) and enter your server's address.

## Run from source

```sh
swift build
swift run TransmissionShell
```

`swift run` produces a bare executable rather than an app bundle, which means no
magnet or `.torrent` associations and no notifications — the results of adds go to
the unified log instead. Use the bundle for anything beyond UI work. Its configuration is
completely independent of the other: pointing one at a test daemon leaves the
other alone.

## Test

```sh
swift test                      # unit tests; the live-daemon suite skips
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

## Bundle

```sh
./Scripts/build-app.sh                    # → "dist/Transmission Shell.app"
./Scripts/build-app.sh --dmg              # + dist/Transmission-Shell-<version>.dmg
./Scripts/build-app.sh --zip              # + that .zip and a version-stamped install.sh
./Scripts/build-app.sh --install          # + copy to /Applications, refresh LaunchServices
./Scripts/build-app.sh --version 1.2.3    # override the version
```

Without `--version` the version comes from `git describe --tags --always --dirty`,
falling back to `0.0.0` outside a repository. The script builds release, assembles the
bundle, compiles the icon, and ad-hoc signs.

`--install` is the quickest way to make magnet links actually route here: it copies to
`/Applications` and runs `lsregister`, which is what registers the associations.

## Publish

Releases are cut from tags. Pushing a `v*` tag runs
[`.github/workflows/release.yml`](.github/workflows/release.yml), which re-runs the
full test suite, builds the `.dmg`, `.zip`, and installer, and creates the GitHub
release with all three attached.

```sh
git tag -a v1.2.3 -m "v1.2.3"
git push origin v1.2.3
```

`Scripts/release.sh v1.2.3` does the same thing locally via `gh`, for when you'd
rather not wait on CI. Both act on a tag that already exists — neither creates or
pushes one.

Builds are **not** notarized, which needs a paid Apple Developer ID. The consequence
is the Gatekeeper prompt below; everything else works normally.

## Server address

One field, matching the daemon's own `rpc-url` setting — the directory `rpc` and
`web/` are served beneath. `ServerConfig` normalizes what you type, so pasting the URL
out of a browser's address bar works: a trailing `web/`, `index.html`, or `rpc` is
dropped, a missing scheme becomes `http`, and a missing path becomes `/transmission/`.
A missing port stays missing and means the scheme's default, so reverse-proxied setups
on 80/443 work without inventing 9091.

The password lives in the keychain. The settings form never reads it back — leave the
field blank to keep what's stored, or use "Remove stored password" to clear it.

## Known friction

1. **Gatekeeper.** Ad-hoc signed builds are not notarized, so a `.dmg` downloaded from
   Releases is quarantined and refuses to launch: "Apple could not verify ... is free of
   malware". Open it once to get the refusal, then go to System Settings → Privacy &
   Security and click "Open Anyway", which appears there for a short while afterward.
   Or drop the flag directly:
   ```sh
   xattr -d com.apple.quarantine "/Applications/Transmission Shell.app"
   ```
   Quarantine comes from the download, so neither the install script nor a locally built
   copy is ever affected.
2. **LaunchServices caching.** Magnet and `.torrent` associations may not take effect
   until the app has been launched once from `/Applications`, or until you run:
   ```sh
   /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "/Applications/Transmission Shell.app"
   ```
   `Scripts/build-app.sh --install` does this for you.
3. **Browser handler preferences.** Chrome and Firefox cache protocol-handler choices
   independently of LaunchServices. If magnets still open somewhere else, clear the
   per-site protocol permission in the browser's own settings.
4. **Web UI behind an auth proxy.** The window feeds your stored credentials to the
   web UI when challenged, using the same username and password as the RPC client. If
   the proxy wants different credentials, the page will show a rejection notice rather
   than looping on the prompt.
5. **First add prompts.** macOS asks for notification and local-network permission the
   first time a torrent is added, which may be a magnet click with no window open.
   Both are one-time.
6. **Keychain access prompt.** Expect one "wants to use your confidential information"
   dialog per installed build. The keychain gates the stored password on a *partition
   list*, which macOS pins to `teamid:` only when the signature carries a team
   identifier and otherwise pins to the build's `cdhash:`. Without a paid Apple
   Developer ID there is no team identifier, so each build is pinned to its own hash,
   and "Always Allow" does not help: that answer reaches only the trusted-application
   list, which is a separate gate. Code signing with a self-signed certificate does not
   change this, nor does writing the item with an explicit `SecAccess`. It is once per
   *build*, though, not once per launch.

## Disclaimer

This is an unofficial, independent project. It is not affiliated with, endorsed by, or
supported by the Transmission project or its maintainers. "Transmission" and the
Transmission logo belong to their respective owners; the name is used here only to
describe what this client connects to. Please report issues here, not to Transmission.
