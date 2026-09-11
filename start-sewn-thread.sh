#!/usr/bin/env bash
# start-sewn-thread.sh — launches a local Thread + Sewn stack for end-to-end testing.
#
# Ports
#   Thread HTTP  : 8081   (embed → POST /v1/batch/embeddings)
#   Thread gRPC  : 9090   (ThreadQuery — Sewn fans out to here)
#   Sewn  HTTP  : 8080   (search/chat → POST /v1/search)
#   Sewn  gRPC  : 9091   (ThreadRegistration — Thread registers here)
#
# Demo app settings:
#   Sewn URL  → http://127.0.0.1:8080
#   Thread URL → http://127.0.0.1:8081

set -euo pipefail

SEWN_DIR="$(cd "$(dirname "$0")" && pwd)"
THREAD_DIR="/Users/ritesh/Documents/rao/repositories/Thread"
LOG_DIR="/tmp/sewn-thread-logs"

mkdir -p "$LOG_DIR"

cleanup() {
    echo ""
    echo "Shutting down…"
    kill "$THREAD_PID" "$SEWN_PID" 2>/dev/null || true
    wait "$THREAD_PID" "$SEWN_PID" 2>/dev/null || true
    echo "Done."
}
trap cleanup INT TERM

echo "==> Building Thread…"
(cd "$THREAD_DIR" && swift build -c release 2>&1) | tail -5

echo "==> Building Sewn…"
(cd "$SEWN_DIR" && swift build -c release 2>&1) | tail -5

echo ""
echo "==> Starting Thread  (HTTP :8081, gRPC :9090)"
(
  cd "$THREAD_DIR"
  .build/release/thread \
    --port 8081 \
    --grpc-port 9090 \
    --mothership-host 127.0.0.1 \
    --mothership-grpc-port 9091
) > "$LOG_DIR/thread.log" 2>&1 &
THREAD_PID=$!
echo "    PID $THREAD_PID  →  $LOG_DIR/thread.log"

# Give Thread a moment to bind its gRPC port before Sewn starts.
sleep 2

echo "==> Starting Sewn   (HTTP :8080, gRPC :9091)"
(
  cd "$SEWN_DIR"
  .build/release/sewn-server \
    --port 8080 \
    --grpc-port 9091 \
    --enable-threads
) > "$LOG_DIR/sewn.log" 2>&1 &
SEWN_PID=$!
echo "    PID $SEWN_PID  →  $LOG_DIR/sewn.log"

echo ""
echo "Stack is up. Waiting for Thread registration…"
sleep 3

# Quick health checks
SEWN_OK=$(curl -sf http://127.0.0.1:8080/health && echo "ok" || echo "FAIL")
THREAD_OK=$(curl -sf http://127.0.0.1:8081/health && echo "ok" || echo "FAIL")
echo "  Sewn  health: $SEWN_OK"
echo "  Thread health: $THREAD_OK"

echo ""
echo "  Embed  → POST http://127.0.0.1:8081/v1/batch/embeddings"
echo "  Search → POST http://127.0.0.1:8080/v1/search"
echo "  Threads → GET  http://127.0.0.1:8080/v1/threads"
echo ""
echo "Press Ctrl-C to stop both services."

wait "$THREAD_PID" "$SEWN_PID"
