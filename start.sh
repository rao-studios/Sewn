#!/bin/bash

# Clean rebuild - stops, removes, rebuilds, and restarts containers

set -e

echo "=== Clean Rebuild ==="

echo "Stopping and removing containers..."
docker compose down

echo "Rebuilding image..."
docker compose up -d --build

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
echo "✓ Clean rebuild complete"
echo "View logs: docker compose logs -f"
