#!/usr/bin/env bash
# Nudge Praxis's config watcher after editing config/praxis.yaml on macOS.
#
# The podman VM's shared folder does not forward macOS file-change events, so
# the watcher in the container never sees edits made on the host. Re-writing
# the file from inside the VM (copy + atomic rename, the same pattern a
# Kubernetes ConfigMap update uses) produces the event. Not needed on Linux.
set -euo pipefail
F="$(cd "$(dirname "$0")" && pwd)/config/praxis.yaml"
podman machine ssh "cp '$F' '$F.tmp' && mv '$F.tmp' '$F'"
sleep 1
podman logs --since 5s praxis 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -i -E "reload|rejected|error" || echo "no reload logged yet; check: podman logs praxis"
