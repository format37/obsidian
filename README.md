# Obsidian LiveSync — Self-Hosted

A minimal Docker stack that runs a CouchDB backend for the
[Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync)
Obsidian plugin. One container, real-time sync across desktop and mobile, no
subscription.

Two deployment modes:

- **Mode A — BYO reverse proxy** (default) — you already run Caddy / nginx /
  Traefik on the host, and it will terminate TLS. This repo just adds CouchDB.
- **Mode B — Bundled Caddy** — fresh host with no existing proxy. An overlay
  adds a Caddy container that auto-issues Let's Encrypt certs.

For the full walk-through (architecture, security posture, troubleshooting
table, mobile setup gotchas) see [`README-detailed.md`](./README-detailed.md).
The tech spec is in [`tech-specs.md`](./tech-specs.md).

## Quickstart

### 1. Configure

```bash
git clone https://github.com/format37/obsidian.git
cd obsidian
cp .env.example .env
$EDITOR .env
```

Generate a strong password:

```bash
openssl rand -base64 32
```

Always-required values:

| Variable | What to put |
|---|---|
| `COUCHDB_USER` | admin username (not `admin`) |
| `COUCHDB_PASSWORD` | output of `openssl rand -base64 32` |
| `COUCHDB_DATABASE` | e.g. `obsidian_vault` |
| `EXTERNAL_NETWORK` | existing Docker network both CouchDB and your proxy are on |

For Mode B also set `DOMAIN` and `ACME_EMAIL`.

### 2. Bring up CouchDB

Mode A — default:

```bash
docker network ls | grep "$(grep ^EXTERNAL_NETWORK .env | cut -d= -f2)"   # must exist
docker compose up -d
```

Mode B — bundled Caddy (creates the network if you don't already have one):

```bash
docker network create "$(grep ^EXTERNAL_NETWORK .env | cut -d= -f2)"      # once
docker compose -f docker-compose.yml -f docker-compose.caddy.yml up -d
docker compose logs -f caddy   # wait ~60s for cert issuance
```

### 3. Wire your reverse proxy (Mode A only)

Your proxy must:

- terminate TLS with a valid cert for the public hostname;
- forward **all** HTTP methods (including `COPY`, long `PUT`/`POST`);
- allow request bodies ≥ **256 MB**;
- support WebSocket upgrades;
- pass `Host` and `X-Forwarded-Proto` through;
- **not** add its own basic-auth layer.

Target is `http://obsidian-couchdb:5984` over the shared Docker network. A
reference Caddy snippet for path-prefix routing:

```caddy
handle_path /obsidian* {
    request_body { max_size 256MB }
    reverse_proxy obsidian-couchdb:5984 {
        header_up Host {host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

### 4. Verify

```bash
./scripts/healthcheck.sh --public-url https://<your-public-url>
```

All internal + external checks must pass before you open the plugin.

## Client setup (quick)

Full guide — including the "which device wins on first sync" gotcha — is in
[`README-detailed.md`](./README-detailed.md#client-setup--desktop-obsidian-do-this-first).
In short:

1. **Desktop first.** Install the *Self-hosted LiveSync* community plugin.
   In its setup wizard, enter:
   - URI: `https://<your-public-url>` (the same URL `healthcheck.sh` liked)
   - Username / Password: the values from `.env`
   - Database name: `COUCHDB_DATABASE`
2. Turn on **End-to-End Encryption** with a passphrase — do this **before**
   the first upload.
3. Answer "yes" to *"is this the device with the main vault?"*
4. **Mobile.** Install Obsidian + Self-hosted LiveSync, create an empty vault,
   open the *Copy setup URI* link exported from desktop, and pick
   **fetch from remote** (never "overwrite remote") on first sync.

## Backups

`scripts/backup.sh` writes a JSON dump of the vault DB to `./backups/`. Run it
on a schedule (cron / systemd timer). Off-site copies are your problem.

Also: your desktop vault on disk is still the real backup — push it to a
private git repo, Syncthing, or rsync it somewhere.

## Layout

```
.
├── README.md                   ← this file (quickstart)
├── README-detailed.md          ← full walkthrough
├── tech-specs.md               ← spec; the source of truth
├── .env.example
├── .gitignore
├── docker-compose.yml          ← Mode A (CouchDB only)
├── docker-compose.caddy.yml    ← Mode B overlay (adds Caddy)
├── Caddyfile                   ← used only with Mode B
└── scripts/
    ├── healthcheck.sh
    └── backup.sh
```

`.env`, `data/`, `caddy_data/`, `caddy_config/`, and `backups/` are gitignored.
**Don't nuke `caddy_data/`** — losing it forces Let's Encrypt to re-issue and
can trip rate limits.

## Credits

Built on:

- [vrtmrz/obsidian-livesync](https://github.com/vrtmrz/obsidian-livesync) — the
  plugin that does the actual syncing
- [oleduc/docker-obsidian-livesync-couchdb](https://github.com/oleduc/docker-obsidian-livesync-couchdb)
  — pre-configured CouchDB image
- [Caddy](https://caddyserver.com/) — Mode B TLS
