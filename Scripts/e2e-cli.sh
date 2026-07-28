#!/bin/bash
# Cross-process E2E over the production Bonjour + QUIC path (tier 2.5):
# builds the Stormo CLI, runs a host and a joiner as SEPARATE processes,
# and requires a full discovery → invite → message → echo → departure cycle.
# This is the rung between in-process loopback tests and physical devices —
# it caught the QUIC FIN bug and the inbound-retention bug.
set -euo pipefail

cd "$(dirname "$0")/.."
SERVICE="_pme2e$RANDOM._udp"  # unique per run, valid Bonjour type
LOGDIR="$(mktemp -d)"
trap 'kill $HOST_PID 2>/dev/null || true; rm -rf "$LOGDIR"' EXIT

swift build > /dev/null
BIN="$(swift build --show-bin-path)/stormo-cli"

# GNU timeout is absent on stock macOS (incl. GitHub runners); perl is not.
with_timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }

"$BIN" host --name E2EHost --service "$SERVICE" --timeout 60 --once \
    > "$LOGDIR/host.log" 2>&1 &
HOST_PID=$!
sleep 2

if ! with_timeout 45 "$BIN" join --name E2EJoin --service "$SERVICE" \
    --peer E2EHost --send "e2e-ping" > "$LOGDIR/join.log" 2>&1; then
  echo "FAIL: joiner did not complete"; cat "$LOGDIR/join.log" "$LOGDIR/host.log"; exit 1
fi

if ! wait $HOST_PID; then
  echo "FAIL: host did not exit cleanly"; cat "$LOGDIR/host.log"; exit 1
fi

grep -q 'recv "pong: e2e-ping"' "$LOGDIR/join.log" \
  || { echo "FAIL: echo not received"; cat "$LOGDIR/join.log"; exit 1; }
grep -q "SUCCESS (host, --once): peer departed after exchange" "$LOGDIR/host.log" \
  || { echo "FAIL: host lifecycle incomplete"; cat "$LOGDIR/host.log"; exit 1; }

echo "PASS: cross-process Bonjour+QUIC exchange complete"
