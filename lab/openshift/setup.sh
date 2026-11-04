#!/usr/bin/env bash
# Deploy the Praxis OpenShift lab into the "praxis" namespace.
# Everything stays in that namespace; nothing requests a GPU.
#
# Requires OpenShift AI 3.x with KServe (see prereqs/ to install it).
set -euo pipefail
cd "$(dirname "$0")"

if ! oc get crd inferenceservices.serving.kserve.io >/dev/null 2>&1; then
  echo "OpenShift AI with KServe is not installed. See lab/openshift/prereqs/." >&2
  exit 1
fi

oc apply -f 00-namespace.yaml
oc apply -f 05-echo.yaml
oc apply -f 06-praxis-basics.yaml
oc apply -f 10-serving-runtime.yaml
oc apply -f 11-models.yaml
oc apply -f 20-praxis-ai.yaml

# Optional: the Perses dashboard, if the Cluster Observability Operator is
# installed with Perses enabled (prereqs/03 and 04).
if oc get crd persesdashboards.perses.dev >/dev/null 2>&1; then
  oc apply -f 07-perses-dashboard.yaml
else
  echo "Perses isn't installed; skipping the dashboard (see prereqs/)." >&2
fi

for d in backend-a backend-b backend-c praxis-basics praxis-ai; do
  oc -n praxis rollout status "deployment/$d" --timeout=180s
done
oc -n praxis wait --for=condition=Ready inferenceservice --all --timeout=300s

host() { oc -n praxis get route "$1" -o jsonpath='{.spec.host}'; }
echo
echo "Part 0  basics:        https://$(host praxis-basics)"
echo "        rate-limited:  https://$(host praxis-basics-limited)"
echo "Part 1  AI gateway:    https://$(host praxis-ai)"
