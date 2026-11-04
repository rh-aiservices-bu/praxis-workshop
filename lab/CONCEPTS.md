# Praxis Concepts

Background for the [lab](README.md). Read this first, or alongside the
exercises. Links point into this repo's docs for the full detail.

## What Praxis is

Praxis is a **framework for building proxy servers**, written in Rust, plus a
ready-to-run proxy binary (`praxis`) built from it. You can use it in two ways:

1. **As a product:** run the stock binary and configure it entirely in YAML.
   This is what the lab does.
2. **As a framework:** write your own filters in Rust, compile them into a
   custom binary, and use them from the same YAML.

Target use cases: ingress / API gateway, egress, east/west sidecar, security
gateway, and AI inference/agent gateway. The AI gateway lives in a separate
repo, [praxis-proxy/ai](https://github.com/praxis-proxy/ai), and builds a
`praxis-ai` binary on this core. See [AI.md](AI.md).

The project is young: the latest release at the time of writing is **0.7.5**
(2026-10-21). See [CHANGELOG.md](https://github.com/praxis-proxy/praxis/blob/main/CHANGELOG.md).

## The layers

```text
 ┌───────────────────────────────────────────────┐
 │ server   – binary, config load, hot reload    │
 │ protocol – HTTP/TCP adapters, admin endpoints │
 │ filter   – filter traits, pipeline engine,    │
 │            all built-in filters               │
 │ core     – config types, validation, health   │
 │ tls      – certificates, SNI, cert reload     │
 └───────────────────────────────────────────────┘
          ▼ built on
   Pingora (Cloudflare's Rust proxy library, used here as a fork)
```

Praxis deliberately **avoids owning low-level protocol logic**. Pingora
handles:

- HTTP/1 and HTTP/2 framing
- connection pooling
- request-smuggling defenses
- WebSocket upgrades

Praxis handles everything above that:

- the filter pipeline
- routing and load-balancing decisions
- retries
- header hygiene and `X-Forwarded-*`
- config and hot reload

The dependency between crates flows
`server → protocol → filter → core → tls`. See
[docs/architecture/crate-layout.md](https://github.com/praxis-proxy/praxis/blob/main/docs/architecture/crate-layout.md).

## What Pingora is

[Pingora](https://github.com/cloudflare/pingora) is an open-source Rust
library from **Cloudflare** for building fast, reliable network services,
especially HTTP proxies. Cloudflare built it to replace NGINX in its own
edge, where it carries a large share of their traffic, and open-sourced it
in 2024 under Apache 2.0. It is a **library, not a product**: there is no
Pingora binary or config file. You write a Rust program that uses it.

What Pingora provides:

- **Async networking on tokio**: listeners, a multi-threaded runtime, and
  graceful shutdown and restart.
- **HTTP/1.1 and HTTP/2** on both the client and upstream sides, plus gRPC
  and WebSocket upgrades.
- **TLS** termination and upstream TLS. Praxis uses the rustls variant with
  an OpenSSL crypto provider.
- **Upstream connection pooling** and reuse across threads.
- **Protocol safety**: strict HTTP parsing that defends against request
  smuggling, and HTTP/2 flow control and backpressure.
- **A hook-based proxy API**: you implement a Rust trait called `ProxyHttp`,
  and Pingora calls your methods at each stage of a request.

What Pingora does **not** give you: a config language, routing tables,
filter chains, health-check policy, rate limits, metrics conventions, hot
reload of routing, or security defaults. That is the layer Praxis adds.

### How Praxis plugs into Pingora

An analogy: Pingora is to Praxis roughly what the NGINX core event loop and
HTTP engine are to an NGINX config plus its modules. Pingora moves bytes
correctly and fast. Praxis decides *what should happen* to each request.

Pingora calls into Praxis at a few points in every request, and Praxis runs
its filters there:

```text
1. Request arrives        Praxis runs the request filters
                          (route, rate limit, add headers, ...)
2. Pick the backend       Praxis says which cluster and endpoint
3. Pingora connects       pooled connection, retries on failure
4. Response comes back    Praxis runs the response filters
5. Request finished       Praxis records metrics and logs
```

You saw this in the lab. The rate limiter's 429 came from step 1, so no
backend was ever contacted. The private-IP 502 came from step 2, before
Pingora tried to connect.

The project draws the line explicitly (see
[security-hardening.md](https://github.com/praxis-proxy/praxis/blob/main/docs/operating/security-hardening.md)):

| Pingora handles | Praxis handles |
|---|---|
| Request-smuggling prevention | Hop-by-hop header stripping |
| HTTP/2 backpressure | Host validation, `X-Forwarded-*` |
| Connection pool safety | Retry logic |
| HTTP/1.1 upgrade detection and forwarding (WebSocket) | Filter pipeline, routing, load balancing |

## The core idea: everything is a filter

Routing, load balancing, rate limiting, auth, header rewriting and static
replies are all **filters**. Built-in filters and your own filters implement
the same Rust traits:

- **`HttpFilter`**: `on_request`, `on_response`, and optional request and
  response body hooks
- **`TcpFilter`**: `on_connect` and `on_disconnect`, for layer 4

### Chains become a pipeline

Three terms, from the config inward:

| Term | What it is | Where it lives |
|---|---|---|
| **Listener** | An address and port Praxis accepts connections on, plus the list of chains to run | `listeners:` in YAML |
| **Filter chain** | A named, reusable list of filters. Only exists in config. | `filter_chains:` in YAML |
| **Pipeline** | The flat list of filters a listener actually runs | Built in memory at startup |

#### What you write

Each chain groups filters by concern. In the Part 0 lab config,
[openshift/06-praxis-basics.yaml](openshift/06-praxis-basics.yaml),
simplified:

```yaml
filter_chains:
  - name: observability          # who, what, when
    filters:
      - filter: request_id
      - filter: access_log

  - name: throttle               # protect the backends
    filters:
      - filter: rate_limit

  - name: edge                   # shape requests and responses
    filters:
      - filter: headers
      - filter: static_response

  - name: routing                # decide where it goes
    filters:
      - filter: router
      - filter: load_balancer

listeners:
  - name: web
    address: "0.0.0.0:8080"
    filter_chains: [observability, edge, routing]

  - name: limited
    address: "0.0.0.0:8081"
    filter_chains: [observability, throttle, edge, routing]
```

#### What Praxis builds

At startup Praxis takes each listener's chains **in the order listed** and
joins their filters end to end into one flat list:

```text
listener web:
  observability       edge                        routing
  [request_id, access_log] + [headers, static_response] + [router, load_balancer]
     → pipeline: [request_id, access_log, headers, static_response, router, load_balancer]

listener limited:
  observability            throttle       edge                        routing
  [request_id, access_log] + [rate_limit] + [headers, static_response] + [router, load_balancer]
     → pipeline: [request_id, access_log, rate_limit, headers, static_response, router, load_balancer]
```

The only difference between the two listeners is one extra chain name. No
filter config is duplicated.

#### How a pipeline runs

```text
Request:   request_id → access_log → headers → static_response → router → load_balancer → backend
Response:  request_id ← access_log ← headers ←──────────────────────────────────────────── backend
```

- **Request filters run left to right**, in pipeline order.
- **Response filters run right to left.** A filter that set something up on
  the way in, such as `request_id` assigning an ID, gets the last word on
  the way out, such as echoing that ID to the client.
- **Any filter can answer the request itself** and stop the pipeline.
  `static_response` does this for `/`, so `router` and `load_balancer` never
  run and no backend is contacted. `rate_limit` does the same with a 429.
- **A filter's conditions decide whether it runs.** A filter with
  `when`/`unless` conditions is skipped when they don't match, and the
  pipeline moves on to the next one. That's how `static_response` only
  answers `/` and lets everything else through.

One thing observed in the lab: when a filter answers early, the response
filters of earlier filters do not run on that reply. `curl -i $B/` (Part 0)
has no `X-Powered-By` or `X-Request-Id`, while `$B/app`, which reaches a
backend, has both. Don't rely on response-phase headers
being added to proxy-generated replies such as 404s, 429s and static
responses.

#### Why chains are useful

- **Reuse without copy-paste.** Write a `security` chain once and put it on
  every public listener. Internal listeners simply leave it out.
- **Separation of concerns.** Each chain has one job: observability,
  security, shaping, routing. That keeps a large config readable, and lets
  different people own different chains.
- **Order is explicit.** The listener's `filter_chains:` list is the
  execution order, so "rate limit before routing" is visible in one line.

#### Rules and consequences

- **Chain boundaries disappear at runtime.** Only the flat list remains, so
  you can't tell from a running pipeline which chain a filter came from. It
  also means filter `name:` labels span the whole pipeline: a branch in one
  chain can jump to a named filter in another.
- **Each listener gets its own copy of the filters.** `web` and `limited`
  both include `observability`, but each builds its own instances. Filters
  that keep state, like `rate_limit`, keep it per listener: putting the
  `throttle` chain on two listeners gives two separate buckets.
- **A whole chain can be gated.** A chain-level `conditions:` block applies
  to every filter in it, for example running a chain only for `/api`.
- **The pipeline is checked before it runs**, at startup and on every
  reload. Praxis refuses to start, or rejects the reload, if:
  - `router` doesn't come before `load_balancer`
  - a route points at a cluster the `load_balancer` doesn't know (as you saw
    in the hot-reload exercise)
  - a security filter such as `rate_limit` has a condition (that's a
    bypass)
  - a filter doesn't match the listener's protocol (HTTP filters on a TCP
    listener)
- **Reload rebuilds every pipeline.** Editing a chain changes every listener
  that uses it, swapped in atomically. That's also why the reload log warned
  that the rate limiter's state was reset.

### Routing and pipelining are different things

The project is careful to keep these apart:

- **Pipelining**, at config time, decides *what processing* a request gets.
- **Routing**, at request time, is the `router` filter choosing *which
  cluster* a request goes to. Then `load_balancer` picks *which endpoint* in
  that cluster. They are two separate filters.

See [docs/architecture/pipeline-concepts.md](https://github.com/praxis-proxy/praxis/blob/main/docs/architecture/pipeline-concepts.md).

## Life of a request

1. Pingora accepts the connection. If TLS is on, Praxis picks the certificate
   by SNI (the hostname the client asks for).
2. The handler takes a **snapshot of the current pipeline**. That snapshot
   stays fixed for the whole request, which is what makes hot reload safe.
3. **Request filters run top to bottom.** For each filter:
   - Check its `when`/`unless` conditions (path, method, headers) and skip the
     filter if they don't match.
   - Run `on_request`. The filter can modify the request, set `ctx.cluster`
     (router), set `ctx.upstream` (load balancer), write *filter results*, or
     end the request early (a static response, a 429, a 403).
   - Evaluate any **branch chains**, which can jump forward, loop back, or
     stop based on those filter results.
4. If any filter asked for body access, body chunks go through the body
   filters.
5. Pingora connects to the chosen upstream, using pooled connections.
6. **Response filters run in reverse**, and only filters that ran on the
   request side run here.
7. The response goes back to the client and the upstream connection returns
   to the pool.

```text
Request:   [F0] -> [F1] -> [F2] -> [F3] -> upstream
Response:  [F3] <- [F2] <- [F1] <- [F0] <- upstream
```

See [docs/architecture/life-of-a-request.md](https://github.com/praxis-proxy/praxis/blob/main/docs/architecture/life-of-a-request.md).

## Features that set it apart

- **Body processing without full buffering.** The default is pure streaming.
  A mode called `StreamBuffer` lets filters inspect body chunks as they arrive
  while holding them back from the upstream until the filter approves. That
  is how these work without buffering everything up front:
  - JSON-RPC parsing
  - routing on a JSON body field (`json_body_field` copies a field into a
    header the router can match)
  - guardrails that scan payloads

  See [docs/architecture/payload-processing.md](https://github.com/praxis-proxy/praxis/blob/main/docs/architecture/payload-processing.md).
- **Client-unspoofable headers.** Headers starting with `x-praxis-*`,
  `x-ext-protocol-*` or `x-ext-agent-*` can only be set by filters. If a
  client sends one, the request is rejected with 400, and these headers are
  stripped before going upstream. That makes them safe to route or make
  security decisions on.
- **Branch chains.** Conditional paths inside a pipeline: skip ahead, stop,
  or retry a filter up to N times, driven by results earlier filters wrote.
  See [docs/filters/branch-chains.md](https://github.com/praxis-proxy/praxis/blob/main/docs/filters/branch-chains.md).
- **Hot reload.** A file watcher (500 ms debounce) validates the new config,
  rebuilds the pipelines, and swaps them in atomically. In-flight requests
  finish on the old pipeline. An invalid config is rejected and the old one
  stays. Listener addresses, protocol and TLS on/off need a restart.
- **Strict security defaults:**
  - Backends at loopback, link-local or cloud-metadata addresses are refused.
  - Private IPs need an explicit allowlist, such as
    `trusted_private_endpoints`, which the lab uses.
  - The admin API must bind to loopback.
  - It refuses to run as root.
  - Upstream TLS verification is on.
  - Every insecure switch lives under `insecure_options` and logs a warning.

  See [docs/operating/security-hardening.md](https://github.com/praxis-proxy/praxis/blob/main/docs/operating/security-hardening.md).
- **Policy engine.** An optional `policy` filter, on by default, embeds an
  authorization engine supporting Cedar, CEL and OPA. It handles identity,
  token exchange and audit events. Its `cedar-policy-core` dependency is the
  heaviest part of the build.
- **FIPS 140-3 build.** A separate UBI 9 image does all cryptography through
  the system OpenSSL (`make container-fips`). See
  [docs/operating/fips.md](https://github.com/praxis-proxy/praxis/blob/main/docs/operating/fips.md).

## What's built in

| Area | Filters and features |
|---|---|
| Traffic | `router` (path, host, header), `load_balancer` (round-robin, least-connections, consistent hash, maglev, P2C, weighted, zone-aware, priority, subset), `rate_limit`, `circuit_breaker`, `timeout`, retries and hedged requests, `redirect`, `static_response`, sticky sessions |
| Health | active HTTP, TCP and gRPC probes; passive failure tracking; `/ready` reports per-cluster status |
| Security | `cors`, `csrf`, `ip_acl`, `guardrails`, `basic_auth`, `credential_injection`, `forwarded_headers`, `policy`, SPIFFE peer identity |
| Transformation | `headers`, `path_rewrite`, `url_rewrite`, `grpc_status` |
| Payload | `json_body`, `json_body_field`, `json_rpc`, `grpc_web`, `compression` |
| Observability | `request_id`, `access_log` (stdout, file or syslog), `trace_context`, OpenTelemetry tracing, Prometheus `/metrics`, CloudEvents |
| Protocols | HTTP/1.1, HTTP/2, gRPC, WebSocket, SSE, TCP/L4, TLS termination, re-encryption, mTLS, SNI routing |

Full reference: [docs/filters/reference.md](https://github.com/praxis-proxy/praxis/blob/main/docs/filters/reference.md).
Working configs for every feature: [examples/configs/](https://github.com/praxis-proxy/praxis/tree/main/examples/configs).

## Extending it

You write a crate that implements `HttpFilter` and declares its filters with
`export_filters!`. When you add that crate as a dependency of the server, the
build automatically discovers and registers it. You then use it in YAML like
any built-in filter. Filters are compiled into the binary, not loaded at
runtime as plugins.

See [docs/filters/http-filter-tutorial.md](https://github.com/praxis-proxy/praxis/blob/main/docs/filters/http-filter-tutorial.md)
and [docs/filters/extensions.md](https://github.com/praxis-proxy/praxis/blob/main/docs/filters/extensions.md).

## What this means for OpenShift

- **No Kubernetes controller.** This repo has no operator, Gateway API
  controller or Helm chart. Praxis is purely the data plane, configured by a
  YAML file. On OpenShift that means:
  - a `Deployment`, with the config in a `ConfigMap`
  - a `Service`, plus a `Route` to expose it
  - `trusted_private_endpoints` listing your backend Service DNS names, set
    on the `load_balancer` cluster entries (see finding 1 in the
    [OpenShift lab](openshift/README.md#findings-from-building-this-lab))
- **ConfigMap updates hot-reload.** Mount the ConfigMap as a directory (not
  `subPath`). When Kubernetes updates it, Praxis reloads without a pod
  restart, usually within a minute. Verified in the lab.
- **Restricted security context works unmodified.** The images run under
  OpenShift's default `restricted-v2`: random non-root UID, read-only root
  filesystem, all capabilities dropped. Praxis only rejects UID 0. Verified
  in the lab.
- **Probes and metrics.** Point liveness at `/healthy` on the metrics port
  (9902), and scrape `/metrics` with Prometheus. `/ready` works as a
  readiness probe for a gateway with one backend cluster, but not for an AI
  gateway with many models: it fails as soon as any one cluster has no
  healthy endpoints, and in 0.7.5 it doesn't follow hot reloads. Use
  `/healthy` for readiness there.
- **Models on OpenShift AI.** KServe serves each InferenceService at
  `<name>-predictor.<namespace>.svc.cluster.local`. In the default
  RawDeployment mode that Service is headless, so Praxis connects to the
  model container's port (8000 for the lab's simulator), and the name goes in
  `trusted_private_endpoints` like any other private backend.
