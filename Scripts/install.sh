#!/usr/bin/env zsh
set -euo pipefail

# Downloads a released build and registers it. See README.md for the workflow.
#
# The version is stamped in at release time by Scripts/build-app.sh. Left as "latest",
# this resolves the newest release instead, which is what the copy in the repo does.

REPO="jarrettgilliam/transmission-shell"
APP_NAME="Transmission Shell"
EXECUTABLE_NAME="TransmissionShell"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

VERSION="latest"

die() {
    print -ru2 -- "$@"
    exit 1
}

if [[ "$(uname -m)" != arm64 ]]; then
    die "$APP_NAME requires Apple Silicon."
fi

OS_MAJOR="${$(sw_vers -productVersion)%%.*}"
if (( OS_MAJOR < 26 )); then
    die "$APP_NAME requires macOS 26 or later."
fi

if [[ "$VERSION" == latest ]]; then
    LATEST_URL="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
        "https://github.com/$REPO/releases/latest")" \
        || die "Could not reach GitHub to resolve the latest release."
    TAG="${LATEST_URL##*/}"
    VERSION="${TAG#v}"
else
    TAG="v$VERSION"
fi

if [[ "$TAG" != v* ]]; then
    die "Could not determine which version to install."
fi

SYSTEM_DEST="/Applications/$APP_NAME.app"
USER_DEST="$HOME/Applications/$APP_NAME.app"
STALE=""

if [[ -d "$SYSTEM_DEST" && -d "$USER_DEST" ]]; then
    DEST="$SYSTEM_DEST"
    STALE="$USER_DEST"
elif [[ -d "$SYSTEM_DEST" ]]; then
    DEST="$SYSTEM_DEST"
elif [[ -d "$USER_DEST" ]]; then
    DEST="$USER_DEST"
elif [[ -w /Applications ]]; then
    DEST="$SYSTEM_DEST"
else
    DEST="$USER_DEST"
fi

if [[ "$DEST" == "$SYSTEM_DEST" && ! -w /Applications ]]; then
    die "/Applications is not writable. Remove $SYSTEM_DEST or run as an admin user."
fi

if pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
    print -r -- "Quitting $APP_NAME"
    osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
    for _ in {1..20}; do
        if ! pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
            break
        fi
        sleep 0.25
    done
    if pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
        die "$APP_NAME is still running. Quit it and run this again."
    fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

print -r -- "Downloading $APP_NAME $VERSION"

# curl, never a browser or `open`: quarantine-aware downloaders stamp
# com.apple.quarantine, and Gatekeeper hard-blocks this bundle because it is ad-hoc
# signed rather than notarized. Fetching over curl is what makes the install work.
curl -fsSL --proto '=https' -o "$TMP/app.zip" \
    "https://github.com/$REPO/releases/download/$TAG/Transmission-Shell-$VERSION.zip" \
    || die "Download failed for $TAG."

ditto -x -k "$TMP/app.zip" "$TMP/extracted"

if [[ ! -d "$TMP/extracted/$APP_NAME.app" ]]; then
    die "The archive did not contain $APP_NAME.app."
fi

codesign --verify --strict "$TMP/extracted/$APP_NAME.app" \
    || die "Signature check failed; the download looks corrupt."

mkdir -p "${DEST:h}"
rm -rf "$DEST"
ditto "$TMP/extracted/$APP_NAME.app" "$DEST"

if [[ -n "$STALE" ]]; then
    "$LSREGISTER" -u "$STALE" >/dev/null 2>&1 || true
    rm -rf "$STALE"
    print -r -- "Removed a duplicate copy at $STALE"
fi

"$LSREGISTER" -f -R "$DEST"

print -r -- "Installed $DEST"
