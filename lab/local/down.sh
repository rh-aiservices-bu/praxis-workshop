#!/usr/bin/env bash
# Tear down the Praxis lab.
podman rm -f praxis backend-a backend-b backend-c >/dev/null 2>&1
podman network rm praxis-lab >/dev/null 2>&1
echo "Lab removed."
