# Obsidian LiveSync — Self-Hosted

A minimal Docker stack that runs a CouchDB backend for the [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) Obsidian plugin. One container, real-time diff-sync across desktop and mobile, no subscription.

## What this gives you

- Real-time sync of your Obsidian vault across desktop, mobile, and anything else that runs Obsidian.
- Diff-based sync (chunks, not whole files), so edits on a slow phone connection are cheap.
- Full control over the data — everything lives on your host, encrypted in transit (HTTPS) and optionally at rest (plugin-level E2E).
- Zero dependency on Obsidian's paid Sync service.

## Prerequisites

1. **A Linux host** with Docker and the Compose plugin. 1 vCPU and 1 GB RAM is enough for a personal vault.
2. **HTTPS for the public endpoint.** Obsidian Android refuses plain HTTP to external hosts. You provide TLS in one of two ways — see *Deployment modes* below.
3. A locally-synced **backup of your existing vault** before you touch anything. Copy the whole folder somewhere safe. Non-optional.

## Deployment modes

Two supported paths. Pick one.

### Mode A — Bring your own reverse proxy (default)

Use this when the host already runs a reverse proxy (Caddy, nginx, Traefik, …) for other services. The stack ships CouchDB only; your proxy owns TLS, certificates, and public DNS.

The CouchDB container joins a Docker network you already maintain (`EXTERNAL_NETWORK` in `.env`). Your proxy — which must also be on that network — targets the stable container name `obsidian-couchdb` on port `5984`.

### Mode B — Bundled Caddy (quickstart)

Use this on a fresh host with no existing proxy. A compose overlay adds a Caddy container that binds host ports 80/443 and does automatic Let's Encrypt on a dedicated domain. Requires a public A record pointing at the host.

## Repository layout

```
.
├── README.md
├── tech-specs.md                   ← machine-readable spec; don't edit unless you know why
├── .env.example                    ← copy to .env, fill in real values
├── .gitignore
├── docker-compose.yml              ← Mode A (CouchDB only)
├── docker-compose.caddy.yml        ← Mode B overlay (adds Caddy)
├── Caddyfile                       ← used only with the Caddy overlay
└── scripts/
    ├── healthcheck.sh              ← end-to-end verification
    └── backup.sh                   ← optional local CouchDB dump
```

`.env`, `data/`, `caddy_data/`, `caddy_config/`, and `backups/` are all gitignored. **Losing `caddy_data/` forces Let's Encrypt to re-issue certs** — don't nuke it casually, or you'll hit rate limits.

## Environment variables

Copy `.env.example` to `.env` and set:

### Always required

| Variable | Purpose |
|---|---|
| `COUCHDB_USER` | Admin username for CouchDB. Avoid `admin`. |
| `COUCHDB_PASSWORD` | Long random password. Generate with `openssl rand -base64 32`. |
| `COUCHDB_DATABASE` | Database name, e.g. `obsidian_vault`. |
| `EXTERNAL_NETWORK` | Docker network the CouchDB container joins. Must already exist. Your reverse proxy (Mode A) MUST also be on it. In Mode B, point it at the bridge defined in the overlay. |

### Mode B only

| Variable | Purpose |
|---|---|
| `DOMAIN` | Hostname clients connect to, e.g. `obsidian.yourdomain.tld`. Must have an A record pointing at the host. |
| `ACME_EMAIL` | Email for Let's Encrypt expiry notifications. |

## Deployment

### Mode A — BYO reverse proxy

```bash
# on the host
git clone <your-repo-url> obsidian-livesync
cd obsidian-livesync
cp .env.example .env
$EDITOR .env                              # fill in real values

docker network ls | grep $EXTERNAL_NETWORK      # confirm the network exists
docker compose up -d
```

Then wire your reverse proxy. The proxy MUST:

- Terminate TLS with a valid cert for the public hostname.
- Forward **all** HTTP methods (including `COPY`, `PUT`, long `POST`).
- Allow request bodies of at least **256 MB** (`client_max_body_size` / `request_body max_size` / equivalent).
- Support WebSocket upgrades (LiveSync uses them for `_changes?feed=continuous`).
- Pass `Host` and `X-Forwarded-Proto` through unmodified.
- Not add its own basic-auth layer — CouchDB authenticates the client directly.

Target for the proxy: `http://obsidian-couchdb:5984` over the shared Docker network.

Then:

```bash
./scripts/healthcheck.sh --public-url https://<your-host>
```

### Mode B — bundled Caddy

```bash
# on the host
git clone <your-repo-url> obsidian-livesync
cd obsidian-livesync
cp .env.example .env
$EDITOR .env                              # fill in real values incl. DOMAIN, ACME_EMAIL

dig +short $(grep ^DOMAIN .env | cut -d= -f2)   # must return the host IP
sudo ufw allow 80/tcp && sudo ufw allow 443/tcp # or equivalent

docker compose -f docker-compose.yml -f docker-compose.caddy.yml up -d
docker compose logs -f caddy                    # wait for cert issuance (~30–60 s)
./scripts/healthcheck.sh --public-url https://$(grep ^DOMAIN .env | cut -d= -f2)
```

## Verifying it works

`scripts/healthcheck.sh` runs two layers of checks:

**Internal (always):**
1. CouchDB welcome JSON reachable on the Docker network.
2. Admin auth works against `/_all_dbs`.

**External (when `--public-url` is passed):**
3. HTTPS reachable, welcome JSON served through the proxy.
4. CORS headers present for the Obsidian origin.
5. Server presents a valid (non-self-signed) TLS chain.

All must be green before you touch the Obsidian plugin.

## Client setup — Desktop Obsidian (do this first)

**This is the source-of-truth device.** Whatever's in this vault when you first sync becomes the canonical version. Back up before proceeding.

1. In Obsidian → Settings → Community plugins → Browse → install **Self-hosted LiveSync** by `vrtmrz` → enable.
2. Open the plugin settings. On first launch there's a Setup Wizard — use it.
3. When prompted for the remote database:
   - **URI**: `https://<your public hostname>` (no trailing slash, no port)
   - **Username**: value of `COUCHDB_USER`
   - **Password**: value of `COUCHDB_PASSWORD`
   - **Database name**: value of `COUCHDB_DATABASE`
4. Click **Test database connection** — must go green.
5. Click **Check database configuration** — must go green. If it offers to apply fixes, accept.
6. Sync mode: **LiveSync** (real-time). Leave the other knobs at defaults for now.
7. Turn on **End-to-End Encryption**, set a passphrase, and remember it. This encrypts your notes at rest in CouchDB, so even a server compromise doesn't expose them. Do this *before* the first upload, not after.
8. When asked "is this device the one with the main vault?" — answer **yes**. This uploads the current vault to the server.
9. Wait for initial replication to finish. Status indicator is in the bottom-right status bar.

## Client setup — Android

Don't retype the config. Export it from desktop.

1. On **desktop**: plugin settings → Setup → **Copy setup URI**. Set a passphrase when asked.
2. The clipboard now has an `obsidian://setuplivesync?settings=...` URI. Get it onto your phone however you prefer (saved messages, password manager, encrypted note).
3. On Android: install **Obsidian** from Play Store. Create a **new empty vault**, same name as desktop for sanity.
4. Enable community plugins in the new vault. Install **Self-hosted LiveSync** → enable.
5. Open the setup URI on your phone — Android offers to open it in Obsidian. Accept, enter the passphrase.
6. When the plugin asks whether to **fetch from remote** or **overwrite remote**, pick **fetch from remote**. This is the step where people accidentally wipe their notes — pay attention.
7. Wait for initial download. Takes 1–5 minutes for a typical vault.

That's it. Edits now propagate in real time.

## Knobs worth knowing about

- **Use the trash bin for deleted files** (plugin settings): turn ON. LiveSync propagates deletes aggressively — a misclick on mobile otherwise nukes notes across all devices.
- **Customization sync**: optional. Syncs your plugins, themes, snippets across devices too. Set up *after* note sync is confirmed working; it's a separate database internally.
- **Hatch pane**: command palette → "LiveSync: Show hatch pane". Shows sync status, pending ops, conflicts. First thing to check when something feels wrong.
- **Monthly hygiene**: once a month, run *Rebuild everything (remote)* from your most-trusted device, then *Fetch from remote* on the others. Compacts CouchDB revision history. Back up the vault locally first.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Internal healthcheck fails | Container not on `${EXTERNAL_NETWORK}`, or wrong `container_name` | `docker network inspect $EXTERNAL_NETWORK`; confirm `obsidian-couchdb` is listed |
| External healthcheck 502 (Mode A) | Proxy can't reach the container, or proxy not on `${EXTERNAL_NETWORK}` | Attach the proxy to the shared network; confirm it resolves `obsidian-couchdb` |
| External healthcheck fails, cert never issues (Mode B) | Let's Encrypt can't reach port 80 for HTTP-01 | Open port 80, check `docker compose logs caddy` |
| "Check database configuration" fails in plugin | Stale database state from a prior attempt | Delete DB via Fauxton (`https://<host>/_utils`) and let plugin recreate it |
| Android shows "connecting" forever | TLS problem — Android is stricter than desktop | `curl -v https://<host>/` from a laptop; if cert is self-signed or expired, fix it upstream of the stack |
| Large attachments fail to sync | Proxy body-size limit too low | Raise `client_max_body_size` / equivalent to ≥ 256 MB |
| Notes don't sync but no error | Stuck WebSocket | Confirm proxy forwards WebSocket upgrades; toggle LiveSync off/on; check Hatch pane |
| Conflicts piling up | Simultaneous edits faster than sync | Open Hatch pane, resolve via built-in merge UI; don't ignore — they don't self-heal |
| Catastrophic corruption / duplicated notes everywhere | Plugin or DB state drift | *Rebuild everything (remote)* from your clean backup device → *Fetch from remote* on the others |

## Backups

`scripts/backup.sh` does a local CouchDB dump to `./backups/` using replication. Run it via cron on the host. Off-site replication (S3, a second host, a home NAS) is not included — set that up yourself based on your threat model.

Also: the real backup is still your **desktop vault on disk**. That's a normal folder of markdown files. Sync it to Syncthing, rsync it to another machine, push it to a private git repo — whatever. The CouchDB server is for live sync, not archival.

## Uninstall / reset

```bash
docker compose down                 # or: down -f docker-compose.yml -f docker-compose.caddy.yml
sudo rm -rf data/ caddy_data/ caddy_config/ backups/
```

Back up your vault first. This destroys the server-side copy completely.

## Security notes

- CouchDB sits behind your TLS terminator and its own basic auth. That's the standard setup; don't add oauth2-proxy on top unless you know why.
- The repo is public, but all secrets are in `.env` which is gitignored. Double-check with `git status` before every `git push` that `.env` isn't staged. If it ever leaks, **rotate the CouchDB password immediately** — change `.env` on the host, `docker compose restart couchdb`, then re-enter the new password in the plugin on all devices.
- Plugin-level E2E encryption means even if someone dumps the CouchDB data volume, they see encrypted chunks. Turn it on.

## License and credit

Built on:
- [vrtmrz/obsidian-livesync](https://github.com/vrtmrz/obsidian-livesync) — the plugin doing the real work
- [oleduc/docker-obsidian-livesync-couchdb](https://github.com/oleduc/docker-obsidian-livesync-couchdb) — pre-configured CouchDB image
- [Caddy](https://caddyserver.com/) — HTTPS termination for Mode B

Your repo, your license. MIT or Apache-2.0 are reasonable defaults.
