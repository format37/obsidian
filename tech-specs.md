# Obsidian LiveSync — Docker Deployment Tech Spec

## Purpose

Self-hosted CouchDB backend for the Obsidian **Self-hosted LiveSync** plugin (`vrtmrz/obsidian-livesync`), packaged as a Docker Compose stack. Goal: replace Obsidian Sync with a private, free, real-time diff-sync server for desktop + mobile clients.

## Scope

A Git repository containing:

1. A **default, headless CouchDB service** — no bundled TLS, no host ports, intended to sit behind a reverse proxy that the deployer owns. This is the primary supported mode.
2. An **optional bundled-Caddy override** — a Compose overlay that adds a Caddy service with automatic Let's Encrypt, for deployers without an existing reverse proxy.

Out of scope:
- Client-side Obsidian plugin configuration (user does that via GUI; see README).
- Deployment procedures for specific hosts / environments. Those are owned by the operator and, where applicable, by private ops documentation.

## Constraints

- **Public repository.** No secrets, no domain names, no host-specific identifiers in tracked files. `.env.example` uses placeholder values only.
- HTTPS is required end-to-end — Obsidian Android refuses plain HTTP to external hosts — but the stack does not presume who terminates it.
- Must run on a generic small host (1 vCPU, 1–2 GB RAM). No GPU, no special hardware.
- Must not fight with an existing reverse proxy: the default compose file MUST NOT publish host ports and MUST NOT attempt to issue certificates.

## Architecture

### Default mode — BYO reverse proxy

```
Reverse proxy (operator-owned) ──HTTP──► obsidian-couchdb (internal :5984)
                                                    │
                                                    └──► persistent volume
```

Single container on a pre-existing Docker network supplied by the operator. Reached by the proxy via its stable `container_name`. The proxy owns TLS termination, certificate management, and public DNS.

### Bundled-Caddy mode (optional overlay)

```
Internet ──HTTPS──► Caddy (ports 80/443) ──HTTP──► obsidian-couchdb (:5984)
                                                          │
                                                          └──► persistent volume
```

Activated by adding `docker-compose.caddy.yml` to the `-f` chain. Caddy binds host 80/443, does ACME HTTP-01 against `${DOMAIN}`, and proxies to the CouchDB container on a private bridge network. Use only on hosts that have no existing reverse proxy.

## Required files

```
.
├── README.md
├── tech-specs.md
├── .gitignore
├── .env.example
├── docker-compose.yml                 # default: CouchDB only
├── docker-compose.caddy.yml           # optional overlay: adds Caddy
├── Caddyfile                          # used only with the caddy overlay
└── scripts/
    ├── healthcheck.sh                 # internal checks, optional public-URL checks
    └── backup.sh                      # optional CouchDB dump via replication
```

## Environment variables

### Always required

| Variable | Purpose |
|---|---|
| `COUCHDB_USER` | Admin user. Avoid `admin`. |
| `COUCHDB_PASSWORD` | Long random password. Generate with `openssl rand -base64 32`. |
| `COUCHDB_DATABASE` | Vault database name, e.g. `obsidian_vault`. Plugin creates it on first sync if missing. |
| `EXTERNAL_NETWORK` | Name of an existing Docker network the CouchDB container joins. The operator's reverse proxy MUST also be attached to this network. |

### Bundled-Caddy mode only

| Variable | Purpose |
|---|---|
| `DOMAIN` | Hostname clients connect to. Must have an A record pointing at the host before first start (Let's Encrypt HTTP-01 requirement). |
| `ACME_EMAIL` | Let's Encrypt expiry-notification email. |

`.env.example` MUST use placeholders (`CHANGE_ME`, `your.domain.tld`) and MUST NOT contain real credentials or hostnames.

## Compose requirements — `docker-compose.yml` (default)

- Single service named `couchdb` with `container_name: obsidian-couchdb`. The stable name is part of the public contract: the operator's proxy targets this name.
- Image: `oleduc/docker-obsidian-livesync-couchdb:master`. This image pre-applies all `local.ini` settings LiveSync requires: CORS origins for `app://obsidian.md` and `capacitor://localhost`, chunked transfer, `require_valid_user`, etc. Do NOT substitute plain `couchdb:3.x` — the manual config is tedious and error-prone.
- **No `ports:` stanza.** The container is only reachable over the Docker network.
- Volumes:
  - `./data/couchdb:/opt/couchdb/data` — primary data persistence.
  - `./data/couchdb-etc:/opt/couchdb/etc/local.d` — ad-hoc config that must survive image upgrades.
- `restart: unless-stopped`.
- Joins `${EXTERNAL_NETWORK}`, declared with `external: true` in the top-level `networks:` section.
- Healthcheck: `curl -sf http://localhost:5984/ | grep -q '"couchdb":"Welcome"'`.
- Logging: `json-file`, `max-size: 10m`, `max-file: 3`.
- `env_file: .env`.

## Compose requirements — `docker-compose.caddy.yml` (overlay)

Invoked as `docker compose -f docker-compose.yml -f docker-compose.caddy.yml up -d`.

- Adds a service `caddy` (`caddy:2-alpine`) that publishes `80:80` and `443:443`.
- Declares an internal bridge network and attaches both `caddy` and `couchdb` to it (in addition to `couchdb` staying on `${EXTERNAL_NETWORK}` from the base file; or, if the overlay is being used, `EXTERNAL_NETWORK` can alias the internal bridge — document in README whichever is simpler).
- Caddy volumes: `./caddy_data:/data`, `./caddy_config:/config`. Losing `caddy_data` forces LE re-issuance and risks rate-limit lockout — `.gitignore` must cover both, and README must warn.
- Caddy healthcheck: `wget --spider -q http://localhost:2019/config/`.
- `restart: unless-stopped`, same logging rotation as CouchDB.

## Caddyfile requirements (bundled mode only)

- One site block for `${DOMAIN}` via env substitution.
- `reverse_proxy couchdb:5984`.
- `request_body { max_size 256MB }` — the default 10 MB silently truncates large attachments.
- No `basicauth` directive — CouchDB handles its own auth; do not double-layer.
- ACME email from `${ACME_EMAIL}` via the `email` global option or site-level.
- Optional: rate-limit `POST /_session` to mitigate credential stuffing. Skip if it complicates things.

## `.gitignore` minimum

```
.env
data/
caddy_data/
caddy_config/
backups/
*.log
```

## Validation (acceptance criteria)

`scripts/healthcheck.sh` MUST support two layers of checks.

**Internal checks (always):** run from the host, using Docker DNS to reach the container over `${EXTERNAL_NETWORK}`.

1. `curl -sf http://obsidian-couchdb:5984/ | jq .couchdb` returns `"Welcome"`.
2. `curl -sf -u ${COUCHDB_USER}:${COUCHDB_PASSWORD} http://obsidian-couchdb:5984/_all_dbs` returns a JSON array.

**External checks (when a public URL is provided):** pass via `--public-url <url>` or `PUBLIC_URL` env.

3. `curl -sf ${PUBLIC_URL}/ | jq .couchdb` returns `"Welcome"` — TLS + proxy routing works.
4. `curl -sfI -H "Origin: app://obsidian.md" -X OPTIONS ${PUBLIC_URL}/` includes `Access-Control-Allow-Origin: app://obsidian.md` — CORS preserved through the proxy.
5. The server presents a chain that validates against the system trust store (i.e. a real CA, not self-signed). The specific issuer is not checked — deployer's choice.

Exit non-zero on any failure. Internal checks run by default; external checks run only when `--public-url` / `PUBLIC_URL` is supplied.

## Security posture

- Admin password is long-random, stored only in `.env` on the host.
- `require_valid_user = true` is applied by the base image; no anonymous reads.
- TLS is the deployer's responsibility. This repo does not ship keys or certs.
- `_utils` (Fauxton) is not locked down — useful for debugging and already behind auth. README mentions that disabling it is an option for paranoid users.
- Optional plugin-side E2E encryption is documented in README; not enforced server-side.

## Non-goals / explicit exclusions

- No automated off-site backups in v1. `scripts/backup.sh` may produce a local dump; scheduling is the operator's problem.
- No clustering / multi-node CouchDB. Single node only.
- No authentication proxy (Authelia, oauth2-proxy). CouchDB's basic auth over TLS is sufficient for single-user use.
- No Docker Swarm / Kubernetes manifests. Compose only.
- No Prometheus exporter in v1.
- No opinion on which reverse proxy to use. nginx, Traefik, HAProxy, an existing Caddy, a cloud load balancer — any of them is fine provided it meets the "what the proxy must do" requirements below.

## What the operator's reverse proxy must do (default mode)

1. Terminate TLS with a cert valid for the public hostname.
2. Forward to `http://obsidian-couchdb:5984` over the shared Docker network (join `${EXTERNAL_NETWORK}`).
3. Forward **all** HTTP methods, including `COPY`, `PUT`, long `POST`. Some proxies gate methods by default; explicitly allow.
4. Permit request bodies of at least **256 MB** (`client_max_body_size` / `request_body max_size` / equivalent).
5. Support WebSocket upgrades (LiveSync's `_changes?feed=continuous` uses them).
6. Pass `Host` and `X-Forwarded-Proto` through unmodified.
7. Not add its own basic-auth layer — CouchDB authenticates the client directly.

## Expected deployment sequence

### Default mode

1. Operator ensures `${EXTERNAL_NETWORK}` exists and their reverse proxy is attached to it.
2. Clone repo on the host.
3. `cp .env.example .env`, fill required values.
4. `docker compose up -d`.
5. Add a proxy route pointing at `obsidian-couchdb:5984`, reload the proxy.
6. `scripts/healthcheck.sh --public-url https://<your-host>`.

### Bundled-Caddy mode

1. Confirm `dig +short ${DOMAIN}` resolves to the host.
2. Clone repo, `cp .env.example .env`, fill values including `DOMAIN` and `ACME_EMAIL`.
3. Open host firewall 80/443.
4. `docker compose -f docker-compose.yml -f docker-compose.caddy.yml up -d`.
5. Wait ~60 s for Let's Encrypt issuance; tail `docker compose logs caddy` until cert obtained.
6. `scripts/healthcheck.sh --public-url https://${DOMAIN}`.

## References

- Plugin repo: https://github.com/vrtmrz/obsidian-livesync
- Base image: https://github.com/oleduc/docker-obsidian-livesync-couchdb
- CouchDB docs: https://docs.couchdb.org/en/stable/
- Caddy docs (bundled mode only): https://caddyserver.com/docs/
