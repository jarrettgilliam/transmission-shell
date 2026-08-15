#!/usr/bin/env bash
set -euo pipefail

# Assembles "dist/Transmission Shell.app". See README.md for the workflow.

APP_NAME="Transmission Shell"
# Must stay in step with CFBundleExecutable and the SPM product name.
EXECUTABLE_NAME="TransmissionShell"
BUNDLE_ID="com.jarrettgilliam.transmission-shell"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

VERSION=""
MAKE_DMG=false
INSTALL=false

while [ $# -gt 0 ]; do
    case "$1" in
        --dmg) MAKE_DMG=true ;;
        --install) INSTALL=true ;;
        --version) VERSION="${2:-}"; shift ;;
        --version=*) VERSION="${1#*=}" ;;
        -h|--help)
            echo "usage: build-app.sh [--version X.Y.Z] [--dmg] [--install]"
            exit 0
            ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

if [ -z "$VERSION" ]; then
    VERSION="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo "0.0.0")"
fi
VERSION="${VERSION#v}"

echo "Building $APP_NAME $VERSION"

swift build --package-path "$ROOT" -c release --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/arm64-apple-macosx/release/$EXECUTABLE_NAME" "$APP/Contents/MacOS/$EXECUTABLE_NAME"

sed "s/__VERSION__/$VERSION/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

ICON_PLIST="$(mktemp)"
xcrun actool "$ROOT/Resources/AppIcon.icon" \
    --compile "$APP/Contents/Resources" \
    --app-icon AppIcon \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --output-partial-info-plist "$ICON_PLIST" \
    --output-format human-readable-text >/dev/null
rm -f "$ICON_PLIST"

# Ad-hoc signature: enough for the app to run locally and for Gatekeeper to offer the
# right-click bypass. It is not notarized and cannot be.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "Built $APP"

if [ "$MAKE_DMG" = true ]; then
    DMG="$DIST/Transmission-Shell-$VERSION.dmg"
    STAGING="$(mktemp -d)"
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"

    rm -f "$DMG"
    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$STAGING" \
        -ov -format UDZO \
        "$DMG" >/dev/null
    rm -rf "$STAGING"

    echo "Built $DMG"
fi

if [ "$INSTALL" = true ]; then
    DEST="/Applications/$APP_NAME.app"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"

    # LaunchServices caches associations; without this the magnet handler may not
    # register until the app has been launched from /Applications.
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "$LSREGISTER" -f -R "$DEST"

    echo "Installed $DEST and refreshed LaunchServices"
fi
