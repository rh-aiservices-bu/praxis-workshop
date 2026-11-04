# Praxis for AI: Praxis AI

How Praxis is used as an **AI gateway**. This builds on [CONCEPTS.md](CONCEPTS.md):
everything there (listeners, chains, pipelines, router vs load balancer,
reserved headers, hot reload) still applies.

Source: [praxis-proxy/ai](https://github.com/praxis-proxy/ai).

## What it is

**Praxis AI** is a separate repository and a separate binary, `praxis-ai`. It
is the Praxis core plus a set of AI-specific filters, compiled together:

```text
 ┌──────────────────────────────────────────────────────┐
 │ praxis-ai binary                                     │
 │  ┌────────────────────────────────────────────────┐  │
 │  │ AI filters: classify, translate, tokens,       │  │
 │  │ guardrails, MCP/A2A, Responses state, cloud    │  │
 │  │ auth                                           │  │
 │  └────────────────────────────────────────────────┘  │
 │  ┌────────────────────────────────────────────────┐  │
 │  │ Praxis core 0.7.5: listeners, TLS, router,     │  │
 │  │ load_balancer, rate_limit, health checks, ...  │  │
 │  └────────────────────────────────────────────────┘  │
 └──────────────────────────────────────────────────────┘
```

It is the framework idea from CONCEPTS.md in action: a bespoke proxy built
from Praxis primitives plus custom `HttpFilter`s. The config format is the
same YAML, so every core filter you used in the lab works inside a
`praxis-ai` config too.

Why separate repos: AI integrations change fast (new providers, new API
shapes, new agent protocols), while the core stays a general-purpose proxy.

**Status: alpha.** The README says APIs, config and behavior may change
before 1.0. The latest release tag is **0.9.0**. Several capabilities
(OpenAI Responses state, Conversations, the agentic loop, token rate limiting)
are **experimental and not in the default build**.

## Why AI traffic needs a different proxy

A normal reverse proxy routes on path and headers and counts requests. AI
traffic breaks those assumptions:

| Normal HTTP | AI inference / agent traffic |
|---|---|
| Routing signal is in the path or headers | Routing signal (`model`, tools, `stream`) is in the **JSON body** |
| One API shape per backend | Clients speak OpenAI Chat, OpenAI Responses or Anthropic Messages; backends speak a different one |
| Cost is per request | Cost is per **token**, known only after the response, and input and output tokens are priced differently |
| Short request/response | Long **streaming** (SSE) responses, multi-step tool loops |
| Stateless | OpenAI Responses and Conversations carry **server-side state** |
| Auth is one bearer token | Every provider has its own auth: API keys, AWS SigV4, Entra ID, Google ADC |
| Content is opaque | Prompts and completions may need **guardrail** checks |

Praxis core already has the building blocks to handle this: `StreamBuffer`
body inspection, client-unspoofable `x-praxis-*` headers, branch chains and
the `iterative_request_router`. Praxis AI adds the filters that understand
the AI formats.

## The core pattern: classify → promote → route

This is the same pattern as in core (`json_body_field` → header → `router`),
specialized for AI:

```text
request head ──► ai_operation          what API is this? (no body read)
                    │                   OpenAI Chat / Responses / Conversations
                    │                   / Anthropic Messages, plus the operation
request body ──► model_to_header       copy body "model" into a header,
                    │                   stripping any client-sent copy
                    ▼
                 router                match the header ─► cluster
                    ▼
                 load_balancer         pick an endpoint in that cluster
                    ▼
                 vLLM / KServe / OpenAI / Bedrock / ...
```

A minimal model-routing config, from
[model-to-header-routing.yaml](https://github.com/praxis-proxy/ai/blob/main/examples/configs/model-to-header-routing.yaml)
and annotated:

```yaml
filter_chains:
  - name: extract-model
    filters:
      # Reads "model" from the JSON body (StreamBuffer: it peeks without
      # forwarding) and sets X-AI-Model. A client-supplied X-AI-Model is
      # stripped, so routing cannot be spoofed.
      - filter: model_to_header
        header: X-AI-Model

  - name: routing
    filters:
      - filter: router          # the same core router you used in the lab
        routes:
          - path_prefix: "/"
            headers: { x-ai-model: "mistral-7b-instruct" }
            cluster: mistral
          - path_prefix: "/"
            headers: { x-ai-model: "granite-3.1-8b" }
            cluster: granite
          - path_prefix: "/"
            cluster: default
      - filter: load_balancer
        clusters:
          - name: mistral
            endpoints: ["10.0.1.1:8080", "10.0.1.2:8080"]
          - name: granite
            endpoints: ["10.0.2.1:8080", "10.0.2.2:8080"]
          - name: default
            endpoints: ["10.0.3.1:8080"]
```

Compare it with lab exercise 5 (header routing on `/v2`). The only new piece
is the filter that turns a body field into a header.

## Capability map

Filter names are what you put in `filter:`. The full list is in
[docs/filters/reference.md](https://github.com/praxis-proxy/ai/blob/main/docs/filters/reference.md).
"Exp." marks experimental filters that need an opt-in build feature.

### 1. Classify and route

| Filter | What it does |
|---|---|
| `ai_operation` | Identifies the API and operation from method, path and headers alone |
| `model_to_header` | Promotes body `model` to a routing header |
| `model_to_provider`, `provider_route` | Maps models to providers and routes to them |
| `intelligent_route` | Picks a cluster by scoring candidates (fresh over stale, local site over remote); replaces `router` |
| `mcp`, `a2a` | Classify and route MCP tool calls and A2A agent tasks |

### 2. Translate between API formats

Clients keep their native SDK and Praxis rewrites request, response and
**streaming** events:

| From (client) | To (backend) | Filters |
|---|---|---|
| Anthropic Messages (e.g. Claude Code) | OpenAI Chat Completions (e.g. vLLM) | `anthropic_messages_to_chat_completions`, `..._stream` |
| OpenAI Chat | Anthropic | `openai_chat_completions_to_anthropic`, `..._stream` |
| OpenAI Responses (e.g. Codex) | Chat Completions | `openai_responses_to_chat_completions` (exp.) |
| OpenAI Chat | Azure OpenAI, AWS Bedrock Converse, Vertex Gemini | `openai_chat_completions_to_azureai_chat_completions`, `..._to_bedrock_converse`, `..._to_vertexai_gemini` |

Translation is **strict by default**. Features with no equivalent on the
target (Anthropic prompt caching, extended thinking) fail with a 400 unless
you allowlist them with `allow_lossy_features`, in which case they're
stripped and reported.

### 3. Credentials per upstream

| Filter | What it does |
|---|---|
| `credential_inject` / core `credential_injection` | Strip the client's key, inject the backend's key |
| `aws_sigv4_sign` | Sign Bedrock requests with AWS SigV4 |
| `azure_ad` (exp.) | Entra ID tokens for Azure OpenAI |
| `gcp_adc` (exp.) | Google Application Default Credentials for Vertex |
| `identity_header_guard` | Strip or capture client identity headers so they can't be forged |

The [Claude Code → vLLM example](https://github.com/praxis-proxy/ai/blob/main/examples/configs/anthropic/messages-to-openai-vllm.yaml)
shows **three separate credentials at three boundaries**:

1. The client authenticates to the gateway with `basic_auth`, which strips
   the credential afterwards.
2. The client's Anthropic `x-api-key` is removed.
3. The gateway injects vLLM's own key.

No credential crosses a boundary.

### 4. Tokens: cost and capacity control

| Filter | What it does |
|---|---|
| `token_count` | Extracts token usage from OpenAI, Anthropic and Google responses, streaming included |
| `token_usage_headers` | Returns token counts in response headers, but only when usage is known before the headers are sent (Bedrock `InvokeModel`). For OpenAI and Anthropic, usage arrives in the body, too late for headers. |
| `token_usage_metrics` | `praxis_ai_tokens_total{tenant, model, kind}` Prometheus counters, with allowlisted labels to bound cardinality |
| `token_rate_limit` (exp.) | Token budgets: see below |
| `token_ceiling` (exp.) | Rejects requests whose token use would exceed a hard cap |
| `external_metering` | Reports usage to an external billing or metering service |
| `time_to_first_token` | Records TTFT, the key latency metric for streaming LLMs |
| `stream_usage_inject` | Asks streaming backends to include usage in the stream |

How `token_rate_limit` works: you can't know a request's token cost until the
model finishes. So it **reserves an estimate at admission**, rejects with 429
if the budget can't cover it, then **reconciles against actual usage** when
the response completes. Further details:

- Budgets are sliding windows (`window: 1h`).
- They can be keyed per tenant header, per authenticated subject, per model,
  per IP, or a combination.
- Token types can be weighted (cached input cheaper than fresh).
- State is in-process by default, or shared across replicas with Valkey or
  Redis (including Sentinel).

Compare it with the core `rate_limit` from lab exercise 6, which counts
requests, not tokens.

### 5. Safety

| Filter | What it does |
|---|---|
| `ai_guardrails` | Calls **NeMo Guardrails** on the request and/or response. Outcomes: pass, block (403 with the rails that fired), or modify (masked text forwarded). Fails closed. |
| `http_callout` (exp.) | Generic call-out to an external service mid-pipeline. The **Lakera Guard** example uses it with a branch chain that answers 403 when Lakera flags the prompt. It's a good illustration of composing core primitives. |
| `prompt_enrich` | Inject system prompts or context without changing the app |
| core `guardrails`, `policy` | Regex and PII rules and the policy engine, from core |

### 6. Stateful OpenAI APIs (experimental)

OpenAI's Responses API keeps conversation state server-side
(`previous_response_id`). Most self-hosted backends such as vLLM are
stateless. Praxis AI can **own that state at the gateway**:

- It stores responses in **SQLite or PostgreSQL**.
- It rehydrates history on follow-up requests.
- It serves the **Conversations** API locally.
- It can compact long histories.

A stateless Chat Completions backend then looks like a full Responses API to
clients.

### 7. Agents and tools

- **MCP broker** (`mcp`): serves tool discovery from a static catalog and
  routes `tools/call` to the right backend by tool name, using the MCP
  2026-07-28 stateless profile.
- **A2A** (`a2a`): routes agent-to-agent tasks and follow-ups to the agent
  that owns them.
- **Agentic loop** (`openai_agentic_loop`, exp.): the gateway runs the tool
  loop itself (model → MCP, web search or file search → model) so a simple
  client gets agentic behavior.

## The Red Hat / OpenShift AI angle

Several integrations point directly at the Red Hat AI stack. All of these
exist in the code; how they map to OpenShift AI product plans isn't
documented in the repo.

- **KServe `LLMInferenceService`** (`llmisvc_model_provider_resolver`):
  clients send a publisher ID such as
  `"model": "publishers/rhoai/models/granite-3.1-8b"`. The routing header
  keeps the full ID, and the body forwarded to KServe gets the short name
  `granite-3.1-8b`.
- **llm-d**: an `ext_proc` integration (`integrations/llmd`) calls llm-d's
  endpoint picker (EPP). The EPP chooses the best vLLM pod (KV-cache aware,
  load aware) and returns it in `x-gateway-destination-endpoint`. The core
  `endpoint_selector` filter then routes to that exact pod. Praxis acts as
  the gateway in front of llm-d.
- **vLLM**: the main self-hosted backend in tests and examples, including a
  GPU CI image (`ghcr.io/praxis-proxy/vllm-gpu`, Qwen3-8B) and native or
  translated paths for Codex, Claude Code and OpenCode.
- **Multi-tenant headers**: `state_owner` and `project_state_owner_headers`
  examples use `x-maas-tenant` and `x-maas-user` style headers, matching a
  models-as-a-service setup.
- **FIPS 140-3**: `-fips` images on UBI 9, like core.

## Builds and images

| Build | What you get |
|---|---|
| default (`full`) | All non-experimental filters: classify, route, translate, tokens (except rate limit), guardrails, MCP/A2A, credentials, AWS SigV4 |
| `--features openai-all,store-sqlite` | Adds experimental Responses, Conversations, agentic loop and a store |
| individual flags | `token-rate-limit-filter`, `azure-ad-filter`, `gcp-adc-filter`, `http-callout-filter`, `llmd-ext-proc`, `opentelemetry`, ... |

A config that names a filter the binary wasn't built with **fails at
startup** with "unknown filter type", so check which build you're running.

Published images at `ghcr.io/praxis-proxy/ai`:

- `:latest` and `:0.9.0`: the default build
- `-experimental` suffix: adds Responses and both stores
- `-fips` suffix: the FIPS build

**The images are amd64 only.** They run natively on a typical OpenShift
cluster, but only under emulation on an Apple Silicon Mac.

## Trying it

**Part 1 of the [OpenShift lab](openshift/README.md)** runs Praxis AI 0.9.0
in front of simulated models (llm-d-inference-sim, CPU only) served by
OpenShift AI as KServe InferenceServices:

- routing on body `model`, with client copies of the routing header stripped
- Anthropic Messages clients served by OpenAI Chat backends, streaming
  included, with strict refusal of untranslatable features
- per-model token counts and time-to-first-token metrics in OpenShift
  monitoring
- adding a new model with a hot reload and no restart

Things the lab found that aren't obvious from the docs:

- **Token headers don't work with OpenAI or Anthropic backends.**
  `token_usage_headers` can't add `Praxis-Token-*` headers for them, because
  their usage numbers arrive in the response body after the headers are
  sent. Use the `praxis_ai_*_tokens_total` metrics instead.
- **Experimental filters aren't in the published image.** `token_ceiling`,
  `token_rate_limit` and the Responses filters fail with "unknown filter
  type" there.

Next steps beyond the lab:

- Swap the simulator ServingRuntime for vLLM on a GPU node, keeping the same
  InferenceService names, so the gateway config doesn't change.
- Point Claude Code at the gateway (`allow_lossy_features` on the
  translation filter lets its prompt-caching and thinking requests through).
- Use an `-experimental` image or a custom build to try token budgets per
  tenant and OpenAI Responses state.

## Where to read next (in the ai repo)

- [README](https://github.com/praxis-proxy/ai/blob/main/README.md) and
  [docs/features.md](https://github.com/praxis-proxy/ai/blob/main/docs/features.md)
- [docs/architecture/ai-inference.md](https://github.com/praxis-proxy/ai/blob/main/docs/architecture/ai-inference.md):
  the classification pipeline in depth
- [docs/architecture/agentic-protocols.md](https://github.com/praxis-proxy/ai/blob/main/docs/architecture/agentic-protocols.md):
  MCP and A2A
- [docs/architecture/response-store.md](https://github.com/praxis-proxy/ai/blob/main/docs/architecture/response-store.md):
  Responses state
- [docs/developing/cli-vllm-through-praxis.md](https://github.com/praxis-proxy/ai/blob/main/docs/developing/cli-vllm-through-praxis.md):
  coding agents through Praxis to vLLM
- [examples/configs/](https://github.com/praxis-proxy/ai/tree/main/examples/configs):
  more than 50 annotated configs
