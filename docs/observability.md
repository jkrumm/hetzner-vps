# Observability — ClickStack + OTLP

End-to-end OpenTelemetry tracing across Traefik, every VPS service, and
browser-side SPAs. The whole pipeline runs on this VPS — single instance of
`clickhouse/clickstack-all-in-one` (ClickHouse + OTel Collector + HyperDX UI +
MongoDB) at `clickstack`, exposed publicly only via Traefik on `hyperdx.${DOMAIN}`
(Tailscale-only) and `otel.${DOMAIN}` (browser OTLP ingest).

## Architecture

```
                                         ┌─────────────────────────────────┐
                                         │  clickstack container           │
                                         │                                 │
   Browser SDK (any app frontend)        │   ┌─────────────────────────┐   │
   ───────────────────────────────►      │   │ otlp/hyperdx receiver   │   │
   <app>.${DOMAIN}/v1/traces             │   │   :4317 grpc  AUTHED    │   │
   <app>.${DOMAIN}/v1/logs               │   │   :4318 http  AUTHED    │   │
   (or otel.${DOMAIN}/v1/...)            │   └────────────┬────────────┘   │
                                         │                ▼                │
                                         │       traces/logs/metrics       │
                                         │           pipelines             │
                                         │                ▲                │
   Traefik (own request spans)           │                │                │
   argo-api (drizzle + tracedFetch)      │   ┌────────────┴────────────┐   │
   future internal services              │   │ otlp/internal receiver  │   │
   ────────────────────────────────►     │   │   :4319 http  NO AUTH   │   │
   clickstack:4319                       │   │   (docker bridge only)  │   │
                                         │   └─────────────────────────┘   │
                                         └─────────────────────────────────┘
```

**Two-tier ingest, two trust boundaries:**

| Tier | Port | Auth | Trust boundary | Used by |
|-|-|-|-|-|
| Public | `:4318` (http) / `:4317` (grpc) | `bearertokenauth` | Public ingress via Traefik + ingestion key | Browser SDKs (any frontend), future cross-host exports |
| Internal | `:4319` (http) | none | docker `monitoring-net` membership | Traefik, argo-api, imgproxy, future internal services |

The `:4319` port has no host binding and no Traefik label — it's reachable only
from other containers on `monitoring-net`. The trust boundary is the docker
network.

## Why the two tiers exist — the bugs that forced it

Two stuck upstream issues prevent Traefik from sending an OTLP auth header
reliably:

1. **Traefik static YAML does not substitute `${VAR}` in header values.** Empirically
   verified: with `tracing.otlp.http.headers.authorization: "${HYPERDX_API_KEY}"`,
   Traefik's debug config dump shows the loaded header value as the literal string
   `${HYPERDX_API_KEY}`, not the substituted token. (Traefik's YAML loader has
   never supported shell-style interpolation; only the dynamic *file provider* supports
   Go-template `{{ env "X" }}`.)

2. **The env-var route for header maps is broken in Traefik 3.3–3.6.** Setting
   `TRAEFIK_TRACING_OTLP_HTTP_HEADERS_authorization=<token>` does not populate the
   headers map at all — the `headers` key is absent from the loaded static config.
   See [traefik-helm-chart#1361](https://github.com/traefik/traefik-helm-chart/issues/1361)
   — acknowledged as a bug, closed for inactivity, unfixed in 3.6.

Meanwhile, ClickStack's `:4318` receiver enforces `bearertokenauth/hyperdx` and
the base config is locked by OpAMP — no env var to disable it, no override
(only merge — see below). Inlining the token in `traefik.yml` was rejected
because the VPS repo is public on GitHub and the token wouldn't be rotatable
without a code edit.

**Resolution**: add a *second* unauthed receiver instance on `:4319` bound only to
the docker bridge. The trust boundary moves from "the bearer token" to "membership
in `monitoring-net`", which is acceptable for a single-host VPS where every container
is ours.

## ClickStack custom config — merge semantics

ClickStack supports merging a custom collector config:

```yaml
# compose.monitoring.yml — clickstack service
environment:
  CUSTOM_OTELCOL_CONFIG_FILE: /etc/otelcol-contrib/custom.config.yaml
volumes:
  - ./clickstack/otel-custom.yaml:/etc/otelcol-contrib/custom.config.yaml:ro
```

**Critical constraint**: the merge **cannot override or extend** existing base
components. Concretely, this fails:

```yaml
# DOES NOT WORK — base `traces` pipeline keeps its original receivers list,
# this declaration is silently ignored.
service:
  pipelines:
    traces:
      receivers: [otlp/hyperdx, otlp/internal]
```

What does work: defining **parallel** pipelines that target the same downstream
exporters:

```yaml
# clickstack/otel-custom.yaml — applied form
receivers:
  otlp/internal:
    protocols:
      http:
        endpoint: 0.0.0.0:4319

service:
  pipelines:
    traces/internal:
      receivers: [otlp/internal]
      processors: [memory_limiter, batch]
      exporters: [clickhouse]
    logs/in-internal:
      receivers: [otlp/internal]
      exporters: [routing/logs]
    metrics/internal:
      receivers: [otlp/internal]
      processors: [memory_limiter, batch]
      exporters: [clickhouse]
```

Verify the merged result inside the container:

```bash
docker exec clickstack cat /etc/otel/supervisor-data/effective.yaml | grep -A 6 "traces"
```

## How each component is wired

### Traefik (`compose.networking.yml` + `traefik/traefik.yml`)

```yaml
# traefik/traefik.yml — static config
tracing:
  otlp:
    http:
      endpoint: http://clickstack:4319    # unauthed internal port
  serviceName: traefik
  sampleRate: 1.0

metrics:
  otlp:
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true
    http:
      endpoint: http://clickstack:4319
```

Traefik must be on `monitoring-net` (already wired). One trace per inbound
request hitting any router. Request-duration metrics per router/entrypoint/service
land in `default.otel_metrics_*` tables for HyperDX.

### Backend services (argo-api as canonical example)

```yaml
# apps/argo/compose.yml
environment:
  OTEL_EXPORTER_OTLP_ENDPOINT: http://clickstack:4319
  OTEL_SERVICE_NAME: argo-api
```

No `OTEL_EXPORTER_OTLP_HEADERS`. The SDK in the app (typically
`@opentelemetry/sdk-node`) appends `/v1/traces` and `/v1/logs` to the endpoint.

### Third-party containers (imgproxy as canonical example)

An off-the-shelf image may honour the standard `OTEL_*` vars for *where* to send
telemetry while keeping its own flag for *whether* to send any. imgproxy is
exactly this — v4 dropped `IMGPROXY_OPEN_TELEMETRY_{ENDPOINT,PROTOCOL}` in
favour of `OTEL_*`, but kept the enable flags:

```yaml
# apps/imgproxy/compose.yml
environment:
  IMGPROXY_OPEN_TELEMETRY_ENABLE: "true"          # without this, the rest is inert
  IMGPROXY_OPEN_TELEMETRY_ENABLE_METRICS: "true"
  IMGPROXY_OPEN_TELEMETRY_ENABLE_LOGS: "true"
  OTEL_EXPORTER_OTLP_ENDPOINT: http://clickstack:4319
  OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
  OTEL_SERVICE_NAME: imgproxy
```

Setting only the `OTEL_*` vars produces no error and no data — the service
starts happily and exports nothing. **Always confirm at the container's own
startup line rather than assuming**, then confirm rows actually land:

```
msg="OpenTelemetry monitoring" enabled=true logs=true metrics=true
```

### Browser-side SPAs (argo-dashboard as canonical example)

Browser SDKs cannot reach `:4319` (no public route). They go through Traefik's
public path to `:4318`:

```
Browser → <app>.${DOMAIN}/v1/traces → Traefik → clickstack-otel@docker → clickstack:4318
                                                                          (authed)
```

Routing labels on the app's frontend container:

```yaml
# apps/argo/compose.yml — argo-dashboard service labels
- "traefik.http.routers.<app>-otel-traces.rule=Host(`<app>.${DOMAIN}`) && Path(`/v1/traces`)"
- "traefik.http.routers.<app>-otel-traces.service=clickstack-otel@docker"
- "traefik.http.routers.<app>-otel-logs.rule=Host(`<app>.${DOMAIN}`) && Path(`/v1/logs`)"
- "traefik.http.routers.<app>-otel-logs.service=clickstack-otel@docker"
```

The browser SDK needs the ingestion key in its bundle (`VITE_HYPERDX_API_KEY`
for Vite, etc.). This is **public-by-design** — same pattern as Sentry DSN,
Datadog client token, PostHog public key.

The key lives at `op://vps/argo/HYPERDX_API_KEY_PROD` and is fanned out to every
GitHub repo via dotfiles' `make github-config` (single source of truth, rotation
= update 1P + re-run + redeploy consumers).

## Adding a new service that exports OTLP

### Backend container on monitoring-net

1. Add to `monitoring-net` in its compose service block
2. Set two env vars:
   ```yaml
   OTEL_EXPORTER_OTLP_ENDPOINT: http://clickstack:4319
   OTEL_SERVICE_NAME: <your-service-name>
   ```
3. Wire your app's OTel SDK to honor `OTEL_EXPORTER_OTLP_ENDPOINT` (standard
   for `@opentelemetry/sdk-node`, Python, Go, etc.)

That's it. No auth wiring, no secrets.

### Frontend SPA with browser ingest

1. Add the four Traefik routers + auth on the SPA's compose service:
   ```yaml
   - "traefik.http.routers.<app>-otel-traces.rule=Host(`<app>.${DOMAIN}`) && Path(`/v1/traces`)"
   - "traefik.http.routers.<app>-otel-traces.entrypoints=websecure"
   - "traefik.http.routers.<app>-otel-traces.tls.certresolver=letsencrypt"
   - "traefik.http.routers.<app>-otel-traces.priority=200"
   - "traefik.http.routers.<app>-otel-traces.service=clickstack-otel@docker"
   - (same four for /v1/logs)
   ```
2. In your build, pull the public ingestion key from `${{ secrets.HYPERDX_API_KEY_PROD }}`
   and pass to the bundler (e.g. `--build-arg VITE_HYPERDX_API_KEY=...`)
3. SDK init: point `url` at `window.location.origin` (same-origin, no CORS preflight)

### Cross-host (homelab → VPS)

Use the public path: `https://otel.${DOMAIN}/v1/traces` with `Authorization: <ingestion-key>`.
Same key, same threat model as browser ingest.

## Verification commands

```bash
# Recent spans by service
echo "SELECT ServiceName, count() AS spans FROM default.otel_traces \
      WHERE Timestamp > now() - INTERVAL 5 MINUTE GROUP BY ServiceName \
      ORDER BY spans DESC FORMAT PrettyCompact" \
  | docker exec -i clickstack clickhouse-client

# Receiver-level counters (acceptance vs refusal)
docker exec clickstack curl -s localhost:8888/metrics | \
  grep -E "otelcol_receiver_(accepted|refused|failed)_(spans|metric|log)"

# Live merged collector config
docker exec clickstack cat /etc/otel/supervisor-data/effective.yaml | less

# Probe the unauthed internal port from inside another monitoring-net container
docker exec <some-container-on-monitoring-net> sh -lc \
  'wget -qS --post-data="{}" --header="Content-Type:application/json" \
   http://clickstack:4319/v1/traces 2>&1 | head'
# Expected: HTTP/1.1 400 Bad Request (empty body is invalid protobuf — but auth OK)

# Probe the authed public port — same body, with auth header
docker exec <container> sh -lc \
  'wget -qS --post-data="{}" --header="Content-Type:application/json" \
   --header="authorization:<key>" http://clickstack:4318/v1/traces 2>&1 | head'
# Without the auth header you get 401.
```

## Key rotation

The HyperDX ingestion key (`op://vps/argo/HYPERDX_API_KEY_PROD`) is used by:
- Any frontend SPA whose build embeds it (currently: argo-dashboard)
- Any cross-host service that sends OTLP to the public ingress (currently: none on VPS)

To rotate:

```bash
op item edit "argo" "HYPERDX_API_KEY_PROD=<new-value>" --account tkrumm
cd ~/SourceRoot/dotfiles && make github-config   # fans out to all 47 repos
cd ~/SourceRoot/argo && git commit --allow-empty -m "chore: redeploy after HyperDX key rotation" && git push
# Repeat the empty-commit-push for any other frontend that embeds the key.
```

Internal services on `:4319` don't need rotation — they don't use the key.

## Deploy regression to know about

**`make argo-up` was a foot-gun** — `${IMAGE_TAG:-...:latest}` fell back to
`:latest`, and RollHook never updates `:latest` (it tags by git SHA only). So a
naive `up -d` would roll the running containers back to whatever was at `:latest`
when the registry was first seeded.

Current state: `make argo-up` reads the *currently running* image SHAs out of
docker and pins them via `ARGO_API_IMAGE` / `ARGO_DASHBOARD_IMAGE`, so compose
recreate-with-config-change works without pulling.

To deploy new code, always go through RollHook: push to argo's master, or use
`make argo-redeploy` on the dev box (empty commit + push). RollHook builds the
SHA-tagged image, pushes, and rolling-restarts the containers.

## References

- [Traefik OTLP tracing config (3.x)](https://doc.traefik.io/traefik/observability/tracing/opentelemetry/)
- [Traefik OTLP metrics config (3.x)](https://doc.traefik.io/traefik/observability/metrics/opentelemetry/)
- [Traefik helm-chart #1361 — env-var header bug](https://github.com/traefik/traefik-helm-chart/issues/1361)
- [Traefik #11992 — v3.5 OTLP regression](https://github.com/traefik/traefik/issues/11992)
- [ClickStack collector customization](https://clickhouse.com/docs/use-cases/observability/clickstack/ingesting-data/otel-collector)
- [OTel collector otlpreceiver — multi-instance + auth](https://github.com/open-telemetry/opentelemetry-collector/blob/main/receiver/otlpreceiver/README.md)
