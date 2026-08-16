#!/usr/bin/env bash
set -euo pipefail

# Local equivalent of .github/workflows/release.yml: test, build, publish.
#
# Operates on a tag that already exists — creating and pushing tags stays a deliberate
# act, not something this script does for you.
#
# Usage: Scripts/release.sh v1.2.3

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ $# -ne 1 ]; then
    echo "usage: release.sh <tag>" >&2
    exit 1
fi

TAG="$1"

if ! git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "tag $TAG does not exist. Create and push it first." >&2
    exit 1
fi

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "working tree is dirty; commit or stash before releasing" >&2
    exit 1
fi

echo "==> Tests"
swift test --package-path "$ROOT"
"$ROOT/Scripts/integration-test.sh"

echo "==> Build"
"$ROOT/Scripts/build-app.sh" --dmg --zip --version "$TAG"

echo "==> Publish"
gh release create "$TAG" \
    --title "$TAG" \
    --generate-notes \
    "$ROOT"/dist/*.dmg "$ROOT"/dist/*.zip "$ROOT"/dist/install.sh
