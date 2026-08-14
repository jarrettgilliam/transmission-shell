#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-19091}"
USERNAME="test"
PASSWORD="test"

DAEMON="$(command -v transmission-daemon || true)"
if [ -z "$DAEMON" ]; then
    echo "transmission-daemon not found. brew install transmission-cli" >&2
    exit 1
fi

WORKDIR="$(mktemp -d)"
DAEMON_PID=""

cleanup() {
    if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        kill "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

mkdir -p "$WORKDIR/config" "$WORKDIR/downloads"

"$DAEMON" \
    --foreground \
    --config-dir "$WORKDIR/config" \
    --download-dir "$WORKDIR/downloads" \
    --port "$PORT" \
    --auth --username "$USERNAME" --password "$PASSWORD" \
    --log-level=error \
    >"$WORKDIR/daemon.log" 2>&1 &
DAEMON_PID=$!

echo "Waiting for transmission-daemon on port $PORT..."
for _ in $(seq 1 50); do
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/transmission/rpc"; then
        break
    fi
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
        echo "Daemon exited during startup:" >&2
        cat "$WORKDIR/daemon.log" >&2
        exit 1
    fi
    sleep 0.2
done

export TS_INTEGRATION_BASE_URL="http://127.0.0.1:$PORT/transmission/"
export TS_INTEGRATION_USERNAME="$USERNAME"
export TS_INTEGRATION_PASSWORD="$PASSWORD"

swift test "$@"
