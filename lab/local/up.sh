#!/usr/bin/env bash
# Start the Praxis lab: three whoami backends + praxis on a podman network.
set -euo pipefail
cd "$(dirname "$0")"

NET=praxis-lab
IMAGE=${PRAXIS_IMAGE:-localhost/praxis:dev}
WHOAMI=docker.io/traefik/whoami:v1.10
# Host ports; container ports are fixed by config/praxis.yaml.
WEB_PORT=${WEB_PORT:-18080}
LIMITED_PORT=${LIMITED_PORT:-18081}
ADMIN_PORT=${ADMIN_PORT:-19902}

podman network exists "$NET" || podman network create "$NET" >/dev/null

for b in backend-a backend-b backend-c; do
  podman rm -f "$b" >/dev/null 2>&1 || true
  podman run -d --name "$b" --network "$NET" "$WHOAMI" --name "$b" >/dev/null
done

podman rm -f praxis >/dev/null 2>&1 || true
# The config directory is mounted (not the file) so editors that replace the
# file on save still trigger hot reload.
podman run -d --name praxis --network "$NET" \
  -p "$WEB_PORT:8080" -p "$LIMITED_PORT:8081" -p "$ADMIN_PORT:9902" \
  -v "$PWD/config:/etc/praxis-lab:ro,Z" \
  -e PRAXIS_LOG_FORMAT=${PRAXIS_LOG_FORMAT:-text} \
  --entrypoint praxis \
  "$IMAGE" -c /etc/praxis-lab/praxis.yaml >/dev/null

echo "Lab is up. Proxy: http://localhost:$WEB_PORT  Rate-limited: http://localhost:$LIMITED_PORT  Admin: http://localhost:$ADMIN_PORT"
echo "Logs: podman logs -f praxis"
