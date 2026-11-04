#!/usr/bin/env bash
# Deploy the Praxis OpenShift lab into the "praxis" namespace.
# Everything stays in that namespace; nothing requests a GPU.
set -euo pipefail
cd "$(dirname "$0")"

oc apply -f 00-namespace.yaml
oc apply -f 05-echo.yaml
oc apply -f 06-praxis-basics.yaml
oc apply -f 10-models.yaml
oc apply -f 20-praxis-ai.yaml

for d in backend-a backend-b backend-c praxis-basics qwen praxis-ai; do
  oc -n praxis rollout status "deployment/$d" --timeout=180s
done
oc -n praxis rollout status statefulset/granite --timeout=180s

host() { oc -n praxis get route "$1" -o jsonpath='{.spec.host}'; }
echo
echo "Part 0  basics:        https://$(host praxis-basics)"
echo "        rate-limited:  https://$(host praxis-basics-limited)"
echo "Part 1  AI gateway:    https://$(host praxis-ai)"
