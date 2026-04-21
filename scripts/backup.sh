#!/usr/bin/env bash
# Simple local CouchDB dump. Copies the vault DB to backups/<db>-<UTC-timestamp>.json
# via the _all_docs?include_docs=true endpoint plus /_local docs.
#
# This is a logical dump sufficient for recovery; it does NOT back up design
# documents or attachments separately — the flat dump already contains them
# inline because the LiveSync plugin stores chunks as regular docs.
#
# Run this on the host (where docker-compose lives). Scheduling is your
# problem: cron, systemd timers, whatever.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR="${REPO_DIR}/backups"

if [[ -f "$REPO_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "$REPO_DIR/.env"
    set +a
fi

: "${COUCHDB_USER:?COUCHDB_USER not set (missing .env?)}"
: "${COUCHDB_PASSWORD:?COUCHDB_PASSWORD not set (missing .env?)}"
: "${COUCHDB_DATABASE:?COUCHDB_DATABASE not set (missing .env?)}"
: "${EXTERNAL_NETWORK:?EXTERNAL_NETWORK not set (missing .env?)}"

mkdir -p "$BACKUP_DIR"
STAMP=$(date -u +"%Y%m%dT%H%M%SZ")
OUT="${BACKUP_DIR}/${COUCHDB_DATABASE}-${STAMP}.json"

echo "[backup] dumping ${COUCHDB_DATABASE} -> ${OUT}"

docker run --rm --network "$EXTERNAL_NETWORK" curlimages/curl:latest \
    -sf -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}" \
    "http://obsidian-couchdb:5984/${COUCHDB_DATABASE}/_all_docs?include_docs=true&attachments=true" \
    > "$OUT"

if [[ ! -s "$OUT" ]]; then
    echo "[backup] empty dump — check that the DB exists and credentials are correct" >&2
    rm -f "$OUT"
    exit 1
fi

BYTES=$(wc -c < "$OUT")
echo "[backup] wrote ${BYTES} bytes to ${OUT}"
