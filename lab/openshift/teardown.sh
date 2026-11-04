#!/usr/bin/env bash
# Remove the Praxis OpenShift lab: deletes the "praxis" namespace and
# everything in it. Touches nothing outside that namespace.
set -euo pipefail
read -r -p "Delete namespace 'praxis' and everything in it? [y/N] " answer
[[ "$answer" == [yY] ]] || { echo "Aborted."; exit 1; }
oc delete namespace praxis
