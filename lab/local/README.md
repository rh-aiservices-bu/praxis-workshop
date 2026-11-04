# Praxis Lab: Local Appendix (podman)

> **Optional.** The main lab runs entirely on OpenShift: see
> [../openshift/README.md](../openshift/README.md). Its Part 0 covers the key
> features from this page. Use this version only to try Praxis offline on a
> laptop. It builds Praxis from source, which needs a lot of memory and
> has macOS-specific workarounds.

A hands-on tour of Praxis running in podman: one proxy, three echo backends,
and one config that shows a different feature on each path. Background:
[../CONCEPTS.md](../CONCEPTS.md).

```text
                         podman network: praxis-lab
 curl ─► :18080 ┌──────────────────────────────────┐
 (web)          │ praxis                           │─► backend-a (whoami)
 curl ─► :18081 │  listener web:     obs → edge → routing ─► backend-b (whoami)
 (rate-limited) │  listener limited: obs → throttle → edge → routing
 curl ─► :19902 │  admin: /healthy /ready /metrics │─► backend-c (whoami)
                └──────────────────────────────────┘
```

| Host port | Container port | What |
|---|---|---|
| 18080 | 8080 | main listener `web` |
| 18081 | 8081 | listener `limited`: same chains behind a rate limit |
| 19902 | 9902 | health and metrics |

Host ports avoid 8080, which is often already taken on a laptop. Override them
with `WEB_PORT`, `LIMITED_PORT` and `ADMIN_PORT`.

The backends are `traefik/whoami`, which echo the request back, so you can see
exactly what Praxis added or changed. Each prints `Name: backend-x`.

## 0. Build and start

This version builds Praxis from source, because its config uses a feature
newer than the latest release (load-balancer cluster entries that copy their
endpoints from a top-level cluster). Clone Praxis outside this repository and
build the image there:

```console
git clone https://github.com/praxis-proxy/praxis.git ~/src/praxis
cd ~/src/praxis
podman build -t localhost/praxis:dev -f Containerfile .   # see "Building on a small podman VM" below
```

Then, from the root of this repository:

```console
lab/local/up.sh
podman logs -f praxis      # in a second terminal
```

## 1. How the config fits together

Open [config/praxis.yaml](config/praxis.yaml). The shape to understand:

- **`listeners`**: what to bind and which **chains** to run, in order.
  `web` runs `[observability, edge, routing]`; `limited` runs the same
  chains with `throttle` added after `observability`.
- **`filter_chains`**: named lists of filters. At startup each listener's
  chains are concatenated into one flat **pipeline**. Request filters run top
  to bottom, response filters bottom to top.
- **`clusters`** (top level): endpoints plus health checks.
- **`router`** picks a *cluster* (where), **`load_balancer`** picks an
  *endpoint* inside it (which one). They are separate filters.

Check a config without starting the server. The image's entrypoint already
passes `-c`, so override it:

```console
podman run --rm --entrypoint praxis -v "$PWD/lab/local/config:/c:ro,Z" \
  localhost/praxis:dev -c /c/praxis.yaml --validate
```

Two warnings are expected: the `rate` key "resembles" `name` (a false
positive; the project's own rate-limiting example triggers it too), and the
metrics listener is on `0.0.0.0`.

## 2. Static response: no upstream

```console
curl -i localhost:18080/
curl -i localhost:18080/nope      # 404: no route matched
```

`static_response` with a `when: path: "/"` condition answers directly and
short-circuits the pipeline: the router never runs.

## 3. Round robin and header injection

```console
for i in 1 2 3 4; do curl -s localhost:18080/app | grep Name; done
curl -s localhost:18080/app/hello                 # full echo
curl -si localhost:18080/app | grep -i -E 'x-powered-by|x-request-id'
```

Expected:

- `Name` alternates `backend-a`, `backend-b`.
- In the echoed request: `X-Via: praxis-lab` (from `headers.request_add`),
  `X-Request-Id` (from `request_id`), and `Via: 1.1 praxis` (added by the
  proxy itself).
- In the response: `x-powered-by: praxis` and `X-Request-Id`.

## 4. Weighted canary split

```console
for i in $(seq 1 20); do curl -s localhost:18080/canary | grep Name; done | sort | uniq -c
```

The `canary` cluster weights backend-a 3 and backend-c 1. Weighted round
robin is deterministic, so you get exactly 15 and 5.

## 5. Header-based routing

```console
curl -s localhost:18080/v2 | grep Name                       # backend-a or b
curl -s -H 'x-version: v2' localhost:18080/v2 | grep Name    # backend-c
```

Two routes share `path_prefix: /v2`; the one with `headers:` wins when the
header matches.

## 6. Rate limiting

```console
for i in $(seq 1 8); do curl -s -o /dev/null -w '%{http_code} ' localhost:18081/app; done; echo
curl -si localhost:18081/app | grep -i -E '^HTTP|ratelimit|retry-after'
for i in $(seq 1 8); do curl -s -o /dev/null -w '%{http_code} ' localhost:18080/app; done; echo
```

Expected: `200 200 200 200 429 429 429 429` on 18081 (burst of 4), with
`Retry-After` and `X-RateLimit-*` headers on the 429. Port 18080 is never
limited.

Why a separate listener instead of a `when: path_prefix: /limited` condition
on one listener? Praxis classes `rate_limit` as a **security filter**, and
refuses to start if a security filter has a condition, because a condition
is a bypass:

```text
security filter 'rate_limit' at position 2 has request conditions;
it will be bypassed for non-matching requests
```

You can opt in with
`insecure_options.skip_pipeline_checks.conditional_security`, but a separate
listener keeps the limit unconditional. It also shows two listeners reusing
the same chains.

## 7. Client-unspoofable headers

```console
curl -si -H 'x-praxis-anything: 1' localhost:18080/app | head -1    # 400
```

`x-praxis-*` headers can only be set by filters, so a client sending one is
rejected. That is what makes them safe to route on.

## 8. Observability

```console
podman logs praxis 2>&1 | grep access_log | tail -3   # one access line per request
curl -s localhost:19902/healthy
curl -s localhost:19902/ready                         # per-cluster health (verbose: true)
curl -s localhost:19902/metrics | grep '^praxis_' | cut -d'{' -f1 | sort -u
```

Metrics to look at:

- `praxis_http_requests_total`, `praxis_http_request_duration_seconds`
- `praxis_upstream_requests_total`, `praxis_upstream_healthy_endpoints`
- `praxis_rate_limit_limited_total`
- `praxis_filter_duration_seconds`, per filter (`metrics.filter_duration: true`)
- `praxis_config_reload_total{result=...}`

## 9. Active health checks

The `app` cluster probes `GET /health` every 2s. whoami lets you change what
its `/health` returns with a POST. The whoami image has no shell, so send it
from the praxis container, which has busybox `wget`:

```console
podman exec praxis wget -qO- --post-data=500 http://backend-a/health   # make it fail
sleep 5
curl -s localhost:19902/ready             # app: healthy 1, unhealthy 1
for i in 1 2 3 4; do curl -s localhost:18080/app | grep Name; done     # only backend-b
podman logs praxis 2>&1 | grep transitioned
podman exec praxis wget -qO- --post-data=200 http://backend-a/health   # recover
```

## 10. Hot reload

Edit [config/praxis.yaml](config/praxis.yaml), for example change the
`X-Powered-By` value to `praxis-reloaded`, save, then:

```console
lab/local/reload.sh                     # macOS only, see below
curl -si localhost:18080/app | grep -i x-powered-by
```

The log shows a reload audit (what changed) and
`config reload complete swapped=["web", "limited"]`. It also warns that the
rate limiter's state was reset.

Now break it: point the `/canary` route at `cluster: does-not-exist` and
reload. The reload is rejected, the old pipeline keeps serving `/canary`,
and `praxis_config_reload_total{result="failure"}` goes up. Put it back
afterwards.

**Why `reload.sh`:** the podman VM's shared folder does not forward macOS
file-change events, so the watcher inside the container never sees a save
made on the host. `reload.sh` rewrites the file from inside the VM (copy plus
atomic rename, the same pattern a Kubernetes ConfigMap update uses), which
fires the event. On Linux, or on OpenShift, saving is enough.

Routes, filters, clusters and weights reload live. Listener addresses,
protocol and TLS on/off need a restart.

## Clean up

```console
lab/local/down.sh
```

## Gotchas found while building this lab

1. **The image's entrypoint already sets `-c`.** Passing another `-c` fails
   with "cannot be used multiple times"; use `--entrypoint praxis`.
2. **Private backends need an allowlist.** Container DNS names resolve to
   10.89.x.x. Praxis refuses private upstream addresses at connection time
   (502, "resolved to private/reserved IP address") unless the host is in
   `trusted_private_endpoints`, or you set the global
   `insecure_options.allow_private_upstreams`.
3. **Connection settings belong on the `load_balancer` cluster entry.** A
   `load_balancer` cluster named after a top-level cluster is a *reference*
   and inherits **only the endpoints**. `trusted_private_endpoints` set only
   on the top-level cluster is accepted without a warning but never applies
   to proxied traffic; the top-level copy only lets the health checker probe.
   The lab sets it in both places.
4. **Conditions on security filters are refused** (see section 6).
5. **Hot reload on macOS needs `reload.sh`** (see section 10).

## Building on a small podman VM

The release profile (`lto = true`, `codegen-units = 1`) needs well over
4 GB of RAM to link. On a 4 GB podman machine the build is killed (SIGKILL,
exit 101). Either resize the VM (`podman machine set --memory 8192`, which
restarts it and every running container) or build with lighter settings,
which produce a functionally identical, slightly less optimized binary. From
your Praxis clone:

```console
podman build \
  --env CARGO_BUILD_JOBS=2 \
  --env CARGO_PROFILE_RELEASE_LTO=thin \
  --env CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 \
  -t localhost/praxis:dev -f Containerfile .
```

Note that `--env` also bakes those variables into the final image. That's
harmless here, but rebuild without them for anything you ship.
