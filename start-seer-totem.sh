#!/usr/bin/env bash
# start-seer-totem.sh — launches a local Totem + Seer stack for end-to-end testing.
#
# Ports
#   Totem HTTP  : 8081   (embed → POST /v1/batch/embeddings)
#   Totem gRPC  : 9090   (TotemQuery — Seer fans out to here)
#   Seer  HTTP  : 8080   (search/chat → POST /v1/search)
#   Seer  gRPC  : 9091   (TotemRegistration — Totem registers here)
#
# Demo app settings:
#   Seer URL  → http://127.0.0.1:8080
#   Totem URL → http://127.0.0.1:8081

set -euo pipefail

SEER_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTEM_DIR="/Users/ritesh/Documents/rao/repositories/Totem"
LOG_DIR="/tmp/seer-totem-logs"

mkdir -p "$LOG_DIR"

cleanup() {
    echo ""
    echo "Shutting down…"
    kill "$TOTEM_PID" "$SEER_PID" 2>/dev/null || true
    wait "$TOTEM_PID" "$SEER_PID" 2>/dev/null || true
    echo "Done."
}
trap cleanup INT TERM

echo "==> Building Totem…"
(cd "$TOTEM_DIR" && swift build -c release 2>&1) | tail -5

echo "==> Building Seer…"
(cd "$SEER_DIR" && swift build -c release 2>&1) | tail -5

echo ""
echo "==> Starting Totem  (HTTP :8081, gRPC :9090)"
(
  cd "$TOTEM_DIR"
  .build/release/totem \
    --port 8081 \
    --grpc-port 9090 \
    --mothership-host 127.0.0.1 \
    --mothership-grpc-port 9091
) > "$LOG_DIR/totem.log" 2>&1 &
TOTEM_PID=$!
echo "    PID $TOTEM_PID  →  $LOG_DIR/totem.log"

# Give Totem a moment to bind its gRPC port before Seer starts.
sleep 2

echo "==> Starting Seer   (HTTP :8080, gRPC :9091)"
(
  cd "$SEER_DIR"
  .build/release/seer-server \
    --port 8080 \
    --grpc-port 9091 \
    --enable-totems
) > "$LOG_DIR/seer.log" 2>&1 &
SEER_PID=$!
echo "    PID $SEER_PID  →  $LOG_DIR/seer.log"

echo ""
echo "Stack is up. Waiting for Totem registration…"
sleep 3

# Quick health checks
SEER_OK=$(curl -sf http://127.0.0.1:8080/health && echo "ok" || echo "FAIL")
TOTEM_OK=$(curl -sf http://127.0.0.1:8081/health && echo "ok" || echo "FAIL")
echo "  Seer  health: $SEER_OK"
echo "  Totem health: $TOTEM_OK"

echo ""
echo "  Embed  → POST http://127.0.0.1:8081/v1/batch/embeddings"
echo "  Search → POST http://127.0.0.1:8080/v1/search"
echo "  Totems → GET  http://127.0.0.1:8080/v1/totems"
echo ""
echo "Press Ctrl-C to stop both services."

wait "$TOTEM_PID" "$SEER_PID"
