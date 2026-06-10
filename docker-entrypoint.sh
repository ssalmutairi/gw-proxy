#!/usr/bin/env bash
set -euo pipefail

LISTEN_PORT="${LISTEN_PORT:-8080}"
CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-10m}"
# Rate limiting is opt-in and off by default (a proxy shouldn't throttle by default).
# Set RATE_LIMIT to e.g. '10r/s' or '600r/m' to enable a per-client-IP limit.
RATE_LIMIT="${RATE_LIMIT:-off}"
RATE_LIMIT_BURST="${RATE_LIMIT_BURST:-20}"
UPSTREAM_KEEPALIVE="${UPSTREAM_KEEPALIVE:-32}"
# DNS server for runtime upstream resolution. Default to the first nameserver in
# the container's resolv.conf (CoreDNS in Kubernetes, Docker's embedded DNS locally).
RESOLVER="${RESOLVER:-$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)}"
RESOLVER_VALID="${RESOLVER_VALID:-30s}"

TEMPLATE_DIR="/etc/nginx/templates-src"
OUT="/etc/nginx/conf.d/default.conf"

die() { echo "nginx-proxy: $*" >&2; exit 1; }

[[ -f "$TEMPLATE_DIR/nginx.conf.head" ]] || die "missing template: $TEMPLATE_DIR/nginx.conf.head"
[[ -f "$TEMPLATE_DIR/segment.conf.tmpl" ]] || die "missing template: $TEMPLATE_DIR/segment.conf.tmpl"

[[ -n "${SEGMENT_1_NAME:-}" ]] || die "no segments defined: SEGMENT_1_NAME is required"

if [[ "$RATE_LIMIT" != "off" ]]; then
    [[ "$RATE_LIMIT" =~ ^[0-9]+r/[sm]$ ]] \
        || die "RATE_LIMIT='${RATE_LIMIT}' invalid: use 'off' or a rate like '10r/s' or '600r/m'"
    [[ "$RATE_LIMIT_BURST" =~ ^[0-9]+$ ]] \
        || die "RATE_LIMIT_BURST='${RATE_LIMIT_BURST}' invalid: must be a non-negative integer"
fi
# Per-location directive, substituted into each segment block (empty when disabled).
if [[ "$RATE_LIMIT" != "off" ]]; then
    LIMIT_REQ_LINE="limit_req zone=perip burst=${RATE_LIMIT_BURST} nodelay;"
else
    LIMIT_REQ_LINE=""
fi
[[ "$UPSTREAM_KEEPALIVE" =~ ^[0-9]+$ ]] \
    || die "UPSTREAM_KEEPALIVE='${UPSTREAM_KEEPALIVE}' invalid: must be a non-negative integer"
[[ -n "$RESOLVER" ]] \
    || die "could not determine a DNS resolver from /etc/resolv.conf; set RESOLVER explicitly"

segment_tmpl="$(cat "$TEMPLATE_DIR/segment.conf.tmpl")"

{
    cat "$TEMPLATE_DIR/nginx.conf.head"
    echo

    # DNS resolver for runtime upstream resolution (the `resolve` parameter on the
    # upstream servers below). Lets the gateway start even when an upstream name
    # doesn't resolve yet — such requests get 502 instead of nginx failing to boot.
    echo "resolver ${RESOLVER} valid=${RESOLVER_VALID} ipv6=off;"
    echo

    # Per-client request rate limit (opt-in via RATE_LIMIT). Keyed on the client IP
    # so a single source can't brute-force API keys. Rejected requests get 429.
    if [[ "$RATE_LIMIT" != "off" ]]; then
        echo "limit_req_zone \$binary_remote_addr zone=perip:10m rate=${RATE_LIMIT};"
        echo "limit_req_status 429;"
        echo
    fi

    # Emit one map per segment so each location can check $valid_key_<segment>.
    n=1
    while :; do
        name_var="SEGMENT_${n}_NAME"
        name="${!name_var:-}"
        [[ -z "$name" ]] && break

        upstream_var="SEGMENT_${n}_UPSTREAM"
        keys_var="SEGMENT_${n}_API_KEYS"
        upstream="${!upstream_var:-}"
        keys="${!keys_var:-}"

        [[ "$name" =~ ^[a-zA-Z0-9_]+$ ]] \
            || die "SEGMENT_${n}_NAME='${name}' invalid: must match [a-zA-Z0-9_]+"
        [[ -n "$upstream" ]] || die "SEGMENT_${n}_UPSTREAM is required for segment '${name}'"
        [[ -n "$keys" ]] || die "SEGMENT_${n}_API_KEYS is required for segment '${name}'"
        [[ "$upstream" != */ ]] || die "SEGMENT_${n}_UPSTREAM='${upstream}' must not end with '/'"

        # Split scheme from host:port for the upstream block (keepalive needs a named
        # upstream). Must be scheme://host[:port] with no path component.
        scheme="${upstream%%://*}"
        hostport="${upstream#*://}"
        [[ "$scheme" =~ ^https?$ ]] \
            || die "SEGMENT_${n}_UPSTREAM='${upstream}' must start with http:// or https://"
        [[ "$hostport" != */* ]] \
            || die "SEGMENT_${n}_UPSTREAM='${upstream}' must be scheme://host[:port] with no path"

        # Named upstream with a keepalive connection pool, so proxied requests reuse
        # TCP connections to the backend instead of opening a new one each time.
        # `resolve` (needs `zone` + the `resolver` above) defers DNS to runtime and
        # re-resolves periodically, so a missing/not-yet-ready upstream yields 502
        # rather than blocking nginx from starting.
        echo "upstream backend_${name} {"
        echo "    zone backend_${name} 64k;"
        echo "    server ${hostport} resolve;"
        echo "    keepalive ${UPSTREAM_KEEPALIVE};"
        echo "}"
        echo

        echo "map \$http_x_api_key \$valid_key_${name} {"
        echo "    default 0;"
        IFS=',' read -ra key_arr <<< "$keys"
        for k in "${key_arr[@]}"; do
            # Trim surrounding whitespace.
            k="${k#"${k%%[![:space:]]*}"}"
            k="${k%"${k##*[![:space:]]}"}"
            [[ -n "$k" ]] || continue
            # Escape backslashes and double-quotes for safe quoting in nginx config.
            k_escaped="${k//\\/\\\\}"
            k_escaped="${k_escaped//\"/\\\"}"
            echo "    \"${k_escaped}\" 1;"
        done
        echo "}"
        echo

        n=$((n + 1))
    done

    echo "server {"
    echo "    listen ${LISTEN_PORT};"
    echo "    server_name _;"
    echo "    client_max_body_size ${CLIENT_MAX_BODY_SIZE};"
    # Emit relative redirects so the auto 301 for a bare /<segment> doesn't leak
    # the internal listen port/scheme (e.g. http://host:8080/app1/).
    echo "    absolute_redirect off;"
    echo
    echo "    location = /healthz { access_log off; return 200 \"ok\\n\"; }"
    echo "    location = /readyz  { access_log off; return 200 \"ok\\n\"; }"
    echo

    # Emit one location per segment.
    n=1
    while :; do
        name_var="SEGMENT_${n}_NAME"
        name="${!name_var:-}"
        [[ -z "$name" ]] && break
        upstream_var="SEGMENT_${n}_UPSTREAM"
        upstream="${!upstream_var}"
        scheme="${upstream%%://*}"

        block="$segment_tmpl"
        block="${block//__SEGMENT__/$name}"
        block="${block//__SCHEME__/$scheme}"
        block="${block//__LIMIT_REQ__/$LIMIT_REQ_LINE}"
        echo "$block"
        echo

        n=$((n + 1))
    done

    echo "}"
} > "$OUT"

nginx -t

exec "$@"
