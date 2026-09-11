#!/bin/bash

# Nuclear rebuild - complete teardown, volume wipe, and rebuild with no cache
#
# Wipes sewn-volume-dev entirely (sewn-db/ — registry, HNSW, documents).
# Use before deploying the HNSW storage redesign to start from a clean slate
# rather than exercising the legacy migration path.

set -e

echo "=== Nuclear Rebuild ==="

echo "Stopping and removing containers..."
docker compose down

echo "Removing dangling images..."
docker image prune -f

# sewn-volume-dev is declared `external: true` in docker-compose.yml, so
# `docker compose down -v` does NOT remove it. We do it explicitly here.
echo "Removing sewn-volume-dev (wipes sewn-db/)..."
docker volume rm sewn-volume-dev 2>/dev/null || echo "  (volume did not exist — skipping)"

echo "Recreating sewn-volume-dev..."
docker volume create sewn-volume-dev

echo "Building from scratch (no cache)..."
docker compose build --no-cache

echo "Starting containers..."
docker compose up -d

echo "Waiting for container to be healthy..."
attempts=0
max_attempts=60
healthy=false

while [ $attempts -lt $max_attempts ]; do
    # Check if container is running
    if docker compose ps 2>/dev/null | grep -q "Up" 2>/dev/null; then
        # Try health endpoint or root
        if curl -sf http://localhost:8080/health >/dev/null 2>&1 || \
           curl -sf http://localhost:8080 >/dev/null 2>&1; then
            echo ""
            echo "✓ Container is healthy"
            healthy=true
            break
        fi
    fi
    echo -n "."
    sleep 2
    attempts=$((attempts + 1))
done

if [ "$healthy" = false ]; then
    echo ""
    echo "⚠ Warning: Container didn't respond within 2 minutes"
    echo "Container may still be compiling Swift code..."
fi

echo ""
echo "=== Status ==="
docker compose ps

echo ""
echo "=== Recent Logs ==="
docker compose logs --tail=20

echo ""
echo "✓ Nuclear rebuild complete"
echo "View logs: docker compose logs -f"
