#!/bin/bash

# Stop containers

set -e

echo "=== Stopping Containers ==="

docker compose down

echo ""
echo "=== Status ==="
docker compose ps

echo ""
echo "✓ Containers stopped and removed"
