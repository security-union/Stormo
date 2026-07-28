#!/bin/bash
# Cross-process E2E over the production Bonjour + QUIC path (tier 2.5):
# builds the Stromo CLI and runs host + joiner as SEPARATE processes.
#   Scenario 1: full discovery → invite → message → echo → departure cycle
#     (caught the QUIC FIN bug and the inbound-retention bug).
#   Scenario 2: silent peer death — kill -9 a lingering joiner; the host must
#     detect the loss via connection-level heartbeats ALONE (failure mode 9:
#     1 s QUIC PINGs, 5 s idle timeout). Only a separate killed process is
#     truly silent on the wire; in-process tests can't fake this.
set -euo pipefail

cd "$(dirname "$0")/.."
SERVICE="_pme2e$RANDOM._udp"  # unique per run, valid Bonjour type
LOGDIR="$(mktemp -d)"
HOST_PID=""; HOST2_PID=""; JOIN2_PID=""
trap 'kill $HOST_PID $HOST2_PID $JOIN2_PID 2>/dev/null || true; rm -rf "$LOGDIR"' EXIT

swift build > /dev/null
BIN="$(swift build --show-bin-path)/Stromo-cli"

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

# --- Scenario 2: silent peer death --------------------------------------
SERVICE2="_pme2k$RANDOM._udp"
"$BIN" host --name E2EHost2 --service "$SERVICE2" --timeout 90 --once \
    > "$LOGDIR/host2.log" 2>&1 &
HOST2_PID=$!
sleep 2

"$BIN" join --name E2EJoin2 --service "$SERVICE2" --peer E2EHost2 \
    --send "e2e-ping" --timeout 90 --linger > "$LOGDIR/join2.log" 2>&1 &
JOIN2_PID=$!

for _ in $(seq 1 30); do
  grep -q "LINGERING" "$LOGDIR/join2.log" 2>/dev/null && break
  sleep 1
done
grep -q "LINGERING" "$LOGDIR/join2.log" \
  || { echo "FAIL: joiner never reached linger"; cat "$LOGDIR/join2.log" "$LOGDIR/host2.log"; exit 1; }

{ kill -9 "$JOIN2_PID" && wait "$JOIN2_PID"; } 2>/dev/null || true  # reap quietly
JOIN2_PID=""
KILLED_AT=$(date +%s)

# Detection bound: 5 s idle (~5 missed PINGs) + margin. 20 s poll ceiling.
DETECTED=0
for _ in $(seq 1 20); do
  if ! kill -0 "$HOST2_PID" 2>/dev/null; then DETECTED=1; break; fi
  sleep 1
done
ELAPSED=$(( $(date +%s) - KILLED_AT ))
[ "$DETECTED" = "1" ] \
  || { echo "FAIL: host never detected the silent peer death"; cat "$LOGDIR/host2.log"; exit 1; }
if ! wait "$HOST2_PID"; then
  echo "FAIL: host exited nonzero after silent death"; cat "$LOGDIR/host2.log"; exit 1
fi
HOST2_PID=""
grep -q "SUCCESS (host, --once)" "$LOGDIR/host2.log" \
  || { echo "FAIL: host did not observe .left"; cat "$LOGDIR/host2.log"; exit 1; }
[ "$ELAPSED" -le 10 ] \
  || { echo "FAIL: detection took ${ELAPSED}s (heartbeat bound is ~5 s)"; exit 1; }

echo "PASS: silent peer death detected by heartbeats in ${ELAPSED}s"
