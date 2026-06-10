# gw-proxy

A small, Dockerized nginx reverse proxy that routes requests to multiple upstream services
based on the first URL path segment, enforces an `x-api-key` allow-list per segment, and
strips the segment prefix and the API-key header before forwarding to the upstream.

Designed to be configured entirely through environment variables so it can be driven by
Kubernetes ConfigMaps and Secrets.

## Behavior

- `GET /<segment>/<path>` is forwarded to `<upstream>/<path>` (segment prefix stripped).
- `x-api-key` is required on every proxied request. Each segment has its own allow-list of
  accepted keys. Missing or unknown key → `401`. The header is stripped before the upstream
  call so backends never see the gateway-side secret.
- `GET /healthz` and `GET /readyz` always return `200` without auth (for K8s probes).

## Environment variable contract

Segments are defined by **contiguous** indexed env vars starting at `1`. The container
discovers segments by incrementing the index until a `SEGMENT_N_NAME` is missing.

For each segment `N`:

| Variable             | Required | Example                                    |
| -------------------- | -------- | ------------------------------------------ |
| `SEGMENT_N_NAME`     | yes      | `app1` (must match `[a-zA-Z0-9_]+`)        |
| `SEGMENT_N_UPSTREAM` | yes      | `http://app1-svc:8080` (`scheme://host[:port]`, no path) |
| `SEGMENT_N_API_KEYS` | yes      | `key-abc,key-def`                          |

Global (optional):

| Variable               | Default | Notes                                                  |
| ---------------------- | ------- | ------------------------------------------------------ |
| `LISTEN_PORT`          | `8080`  | Port nginx listens on. Default is unprivileged since the container runs as non-root. |
| `CLIENT_MAX_BODY_SIZE` | `10m`   | Inbound request body limit.                            |
| `RATE_LIMIT`           | `10r/s` | Per-client-IP request rate. Form `<int>r/s` or `<int>r/m`. |
| `RATE_LIMIT_BURST`     | `20`    | Burst allowance above the rate; excess → `429`.        |
| `UPSTREAM_KEEPALIVE`   | `32`    | Idle keepalive connections cached per upstream.        |
| `RESOLVER`             | _auto_  | DNS server for runtime upstream resolution. Defaults to the first `nameserver` in `/etc/resolv.conf` (CoreDNS in K8s). |
| `RESOLVER_VALID`       | `30s`   | How long resolved upstream IPs are cached before re-resolving. |

Rate limiting is per client IP (`$binary_remote_addr`), shared across all segments, and
applied to the proxied locations only — `/healthz` and `/readyz` are never limited.
Requests over the limit get `429`. Note: nginx sees the IP of whatever connects to it, so
behind a load balancer set `RATE_LIMIT` against the LB's `X-Forwarded-For` handling
expectations (see "Heavy load" below).

Each upstream is wired through a named `upstream` block with a keepalive connection pool,
so proxied requests reuse TCP connections to the backend instead of opening a fresh one
per request — the main throughput win under load. Tune the pool size with
`UPSTREAM_KEEPALIVE`.

Upstream hostnames are resolved **at runtime** (the `resolve` parameter, backed by
`RESOLVER`) and re-resolved every `RESOLVER_VALID`. This means the gateway starts even
when an upstream name doesn't resolve yet — requests to that segment get `502` instead of
nginx failing to boot — and it picks up Service IP changes without a restart. Auth and
rate limiting still apply before the upstream is contacted, so a down backend never
bypasses the key check.

Access logs use nginx's default `combined` format on stdout; the error log goes to stderr.

The container exits non-zero with a clear error if `SEGMENT_1_NAME` is unset, if a
present segment is missing its upstream or keys, if a name fails the regex, if an upstream
ends with `/`, or if an upstream is not `scheme://host[:port]` (http/https, no path).

## Local Docker

```bash
# Local single-arch build for your host:
docker build -t gw-proxy:1.2.1 .

# Multi-arch publish (amd64 + arm64) to a registry — what the released image uses:
#   docker buildx build --platform linux/amd64,linux/arm64 --provenance=false \
#     -t ghcr.io/<user>/gw-proxy:1.2.1 --push .

# Two upstreams for testing
docker run --rm -d --name up1 -p 9001:80 kennethreitz/httpbin
docker run --rm -d --name up2 -p 9002:80 kennethreitz/httpbin

# The image runs as non-root and listens on 8080, so map host 8080 -> container 8080.
docker run --rm -p 8080:8080 \
  -e SEGMENT_1_NAME=app1 \
  -e SEGMENT_1_UPSTREAM=http://host.docker.internal:9001 \
  -e SEGMENT_1_API_KEYS=k1a,k1b \
  -e SEGMENT_2_NAME=app2 \
  -e SEGMENT_2_UPSTREAM=http://host.docker.internal:9002 \
  -e SEGMENT_2_API_KEYS=k2a \
  gw-proxy:1.2.1
```

Verify:

```bash
curl -i localhost:8080/healthz                                      # 200
curl -i localhost:8080/app1/get                                     # 401
curl -i -H 'x-api-key: wrong' localhost:8080/app1/get               # 401
curl -i -H 'x-api-key: k1a'   localhost:8080/app1/get               # 200 (upstream sees /get, no x-api-key)
curl -i -H 'x-api-key: k1a'   localhost:8080/app2/get               # 401 (key valid for app1 only)
curl -i -H 'x-api-key: k2a'   localhost:8080/app2/get               # 200
```

## Kubernetes

Only two manifests: `k8s/deployment.yaml` and `k8s/service.yaml`, both in the `gw-proxy`
namespace. All config — including the per-segment `SEGMENT_N_API_KEYS` — is inline in the
Deployment's `env:` for simplicity.

```bash
kubectl create namespace gw-proxy
kubectl apply -f k8s/deployment.yaml -f k8s/service.yaml
```

To add a segment: append `SEGMENT_N_NAME` / `SEGMENT_N_UPSTREAM` / `SEGMENT_N_API_KEYS` to
the Deployment's `env:`, then `kubectl rollout restart deploy/gw-proxy -n gw-proxy`.

> **Important:** `SEGMENT_N_API_KEYS` in `deployment.yaml` ship as non-functional
> placeholders (`CHANGE_ME_*`) — replace them before deploying, or the gateway only accepts
> a value that's public in this repo. For anything beyond testing, move the keys into a
> Kubernetes Secret (referenced via `envFrom: secretRef`) and keep them out of version
> control.

### Pod hardening

The deployment runs locked down: non-root (`runAsUser: 101`), all Linux capabilities
dropped, `allowPrivilegeEscalation: false`, and the `RuntimeDefault` seccomp profile.
Non-root means the container can't bind port 80, so it listens on `8080` and the Service
maps `80 → http(8080)`.

The pod is **stateless and mounts no volumes**. The image is built so the only paths
nginx writes to are owned by the `nginx` user (uid 101) — `/etc/nginx/conf.d` (rendered
config) and `/var/cache/nginx` (temp files) — and the pid file is relocated to `/tmp`.
Everything lands on the container's own ephemeral writable layer, so pods carry no state
and can be freely added, removed, or rescheduled. To scale under heavy load, raise
`replicas`:

```bash
kubectl scale deploy/gw-proxy --replicas=10
```

The trade-off of the no-volumes design is that `readOnlyRootFilesystem` is *not* enabled,
since a read-only root would require mounting writable volumes for the scratch paths
above.

### Heavy load

The proxy is built to scale horizontally for heavy traffic. The pieces that matter:

- **Upstream keepalive.** Each segment proxies through a named `upstream` block with a
  keepalive pool (`proxy_http_version 1.1` + cleared `Connection` header), so backend TCP
  connections are reused instead of reopened per request. Size the pool with
  `UPSTREAM_KEEPALIVE`.
- **No CPU limit.** The deployment sets a CPU *request* (a guaranteed floor) but no CPU
  *limit*, so the proxy isn't CFS-throttled and can burst into spare node capacity under
  load. A memory limit is kept to bound a runaway pod.
- **Replica count.** The pod is stateless, so scaling is just `kubectl scale` (or a higher
  `replicas` in the manifest). Size it to your peak RPS; a PodDisruptionBudget is worth
  adding so rollouts/drains don't take all replicas at once.
- **Rate limit vs. shared source IPs.** `RATE_LIMIT` is per client IP. Behind a NAT or an
  L4 load balancer that hides the real client, many users share one IP and can trip `429`.
  Terminate XFF correctly (or set the limit high) in those topologies.

## How it works

`docker-entrypoint.sh` runs before nginx starts. It:

1. Iterates `SEGMENT_N_*` env vars until a gap is found.
2. Per segment, emits an `upstream backend_<segment> { ... keepalive ...}` block and a
   `map $http_x_api_key $valid_key_<segment> { ... }`.
3. Emits one `location /<segment>/ { ... }` per segment that returns `401` unless the map
   resolved to `1`, then forwards via `proxy_pass <scheme>://backend_<segment>/;` (trailing
   slash strips the prefix) with `X-Api-Key` cleared and upstream keepalive enabled.
4. Runs `nginx -t` to validate the rendered config, then `exec nginx -g 'daemon off;'`.

## License

[MIT](LICENSE)
