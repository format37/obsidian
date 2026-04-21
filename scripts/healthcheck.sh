#!/usr/bin/env bash
# End-to-end verification for the Obsidian LiveSync CouchDB stack.
#
# Internal checks (always run): reach the container over the shared Docker
# network from the host. Use Docker DNS via a throwaway helper container so
# we don't depend on the host having curl/jq.
#
# External checks (run when --public-url / PUBLIC_URL is supplied):
# verify the public endpoint through whatever reverse proxy is in front.
#
# Exits non-zero on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- CLI / env ---------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $0 [--public-url URL]

  --public-url URL   Also run external checks against this URL (no trailing slash).
                     Can also be passed via the PUBLIC_URL environment variable.

Reads .env from the repo root for COUCHDB_USER, COUCHDB_PASSWORD, EXTERNAL_NETWORK.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --public-url) PUBLIC_URL="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
    esac
done

if [[ -f "$REPO_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "$REPO_DIR/.env"
    set +a
fi

: "${COUCHDB_USER:?COUCHDB_USER not set (missing .env?)}"
: "${COUCHDB_PASSWORD:?COUCHDB_PASSWORD not set (missing .env?)}"
: "${EXTERNAL_NETWORK:?EXTERNAL_NETWORK not set (missing .env?)}"

CONTAINER_NAME="obsidian-couchdb"
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

pass() { echo "${GREEN}[ ok ]${NC} $*"; }
fail() { echo "${RED}[fail]${NC} $*" >&2; exit 1; }
info() { echo "${YELLOW}[info]${NC} $*"; }

docker_curl() {
    # Run curl inside a disposable container on the shared network so we can
    # reach obsidian-couchdb by name without needing curl on the host.
    docker run --rm --network "$EXTERNAL_NETWORK" curlimages/curl:latest "$@"
}

# ---- Internal checks ---------------------------------------------------------

info "Internal check 1/2 — welcome JSON on shared network"
# The base image sets require_valid_user=true, so even GET / needs credentials.
welcome=$(docker_curl -sf -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}" "http://${CONTAINER_NAME}:5984/" || true)
if [[ -z "$welcome" ]]; then
    fail "Could not reach http://${CONTAINER_NAME}:5984/ — is the container up and on network '${EXTERNAL_NETWORK}'?"
fi
echo "$welcome" | grep -q '"couchdb":"Welcome"' \
    || fail "Welcome payload missing \"couchdb\":\"Welcome\" — got: $welcome"
pass "CouchDB welcome JSON served on internal network"

info "Internal check 2/2 — admin auth against /_all_dbs"
dbs=$(docker_curl -sf -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}" "http://${CONTAINER_NAME}:5984/_all_dbs" || true)
if [[ -z "$dbs" ]]; then
    fail "Admin auth to /_all_dbs failed — check COUCHDB_USER / COUCHDB_PASSWORD in .env"
fi
echo "$dbs" | grep -qE '^\[.*\]$' \
    || fail "/_all_dbs did not return a JSON array — got: $dbs"
pass "Admin auth works, /_all_dbs is a JSON array"

# ---- External checks ---------------------------------------------------------

PUBLIC_URL="${PUBLIC_URL:-}"
if [[ -z "$PUBLIC_URL" ]]; then
    info "No --public-url given; skipping external checks."
    pass "All internal checks passed."
    exit 0
fi

PUBLIC_URL="${PUBLIC_URL%/}"
info "External check 1/3 — welcome JSON via ${PUBLIC_URL}/"
public_welcome=$(curl -sf -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}" "${PUBLIC_URL}/" || true)
if [[ -z "$public_welcome" ]]; then
    fail "Could not reach ${PUBLIC_URL}/ — proxy down, wrong route, or TLS broken?"
fi
echo "$public_welcome" | grep -q '"couchdb":"Welcome"' \
    || fail "Public endpoint didn't return CouchDB welcome — got: $public_welcome"
pass "TLS + proxy routing work"

info "External check 2/3 — CORS preflight for Obsidian origin"
headers=$(curl -sfI -X OPTIONS \
    -H "Origin: app://obsidian.md" \
    -H "Access-Control-Request-Method: GET" \
    "${PUBLIC_URL}/" || true)
if [[ -z "$headers" ]]; then
    fail "OPTIONS ${PUBLIC_URL}/ failed — proxy may strip OPTIONS or upstream didn't respond"
fi
echo "$headers" | grep -iq "Access-Control-Allow-Origin:[[:space:]]*app://obsidian.md" \
    || fail "CORS header missing/wrong — proxy may be stripping CORS. Got: $(echo "$headers" | tr -d '\r')"
pass "CORS preserved through the proxy"

info "External check 3/3 — TLS chain validates against system trust store"
# We already proved the endpoint responds (check 1/3 with auth). Here we only
# care that curl accepted the TLS chain. -sS (no -f) tolerates the 401 that
# HEAD without auth returns — TLS validation happens before any HTTP reply.
curl -sSI "${PUBLIC_URL}/" >/dev/null \
    || fail "TLS validation failed (self-signed / expired / wrong-name cert?)"
pass "TLS chain validates"

pass "All checks passed."
