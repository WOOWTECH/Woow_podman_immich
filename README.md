# Immich on rootless Podman (Quadlet + systemd)

Self-hosted photo and video management with [Immich](https://immich.app/), deployed as
**rootless Podman Quadlet units** driven by the user's systemd. The units are the deployment:
systemd starts the stack at boot (with linger), restarts a crashed container, and every
version is pinned in this repository.

[繁體中文版](README_zh-TW.md)

## Architecture

```
            systemctl --user start|stop|restart immich.target
                                  │
   ┌────────────────┬─────────────┴────────────┬─────────────────────────┐
   │                │                          │                         │
immich-postgres  immich-redis        immich-machine-learning       immich-server
 PostgreSQL 14    Valkey 9            (optional, ~1.5 GB)           API + web UI
 + VectorChord    ephemeral           volume immich_model-cache      │
   │                │                          │                     │
   │  HOST_POSTGRES_DIR                        └── alias immich-machine-learning
   │  (bind mount)                                                   │
   └──────────── network immich (aliases: database, redis) ──────────┘
                                                                     │
                                          HOST_LIBRARY_DIR -> /data (photos)
                                          PublishPort HOST_BIND:HOST_PORT -> 2283
```

| File | Unit | What it is |
|---|---|---|
| `quadlet/immich.network` | `immich-network.service` | bridge network `immich` |
| `quadlet/immich-postgres.container` | `immich-postgres.service` | PostgreSQL 14 + VectorChord + pgvecto.rs |
| `quadlet/immich-redis.container` | `immich-redis.service` | Valkey job queue (no volume by design) |
| `quadlet/immich-server.container` | `immich-server.service` | API, web UI, background jobs |
| `quadlet/optional/immich-machine-learning.container` | `immich-machine-learning.service` | face recognition, smart search |
| `quadlet/optional/immich-model-cache.volume` | `immich-model-cache-volume.service` | volume `immich_model-cache` |
| `systemd/immich.target` | `immich.target` | one handle for the whole stack |

Installed to `~/.config/containers/systemd/` (Quadlet), `~/.config/systemd/user/` (target) and
`~/.config/immich/immich.env` (settings, mode 0600). The database password is a podman secret.

## Requirements

- Ubuntu 24.04 or similar, **podman >= 4.9.3** rootless, systemd 255 user units
- linger for the service user (`sudo loginctl enable-linger $USER`)
- disk: about 1.5 GB for the images without machine learning, about 3 GB with it, plus the
  library and the database
- the PostgreSQL directory must be on **local disk** (never NFS or SMB); `install.sh` checks

## Install

```bash
git clone https://github.com/WOOWTECH/Woow_podman_immich ~/woow-quadlet/Woow_podman_immich
cd ~/woow-quadlet/Woow_podman_immich
tests/dryrun.sh                       # optional: validates the units, creates nothing
scripts/install.sh                    # first run: creates the env file and stops
$EDITOR ~/.config/immich/immich.env   # HOST_LIBRARY_DIR and HOST_POSTGRES_DIR above all
scripts/install.sh                    # installs, starts and runs the smoke test
```

Then open `http://127.0.0.1:2283` (or the address you published) and create the admin
account. **The first visitor becomes the admin**, so do not publish the instance before that
account exists, or put Cloudflare Access / an NPM access list in front of it.

Options: `--no-ml` (no machine learning), `--db-password-file F` (first install only),
`--no-start`, `--no-smoke`, `--smoke-timeout S`, `--dry-run`.

## Configuration

`~/.config/immich/immich.env`, mode 0600, `KEY=value` lines only — no quotes, no inline
comments. `HOST_*` keys are rendered into the unit files at install time (decision D2);
every other key is passed to the server and machine-learning containers, so any
[Immich environment variable](https://immich.app/docs/install/environment-variables) works.
Re-run `scripts/install.sh` after an edit: it restarts only what changed.

| Key | Default | Meaning |
|---|---|---|
| `HOST_BIND` | `127.0.0.1` | publish address; `0.0.0.0` also serves the LAN and the mobile app |
| `HOST_PORT` | `2283` | published port (Immich listens on 2283 inside the container) |
| `HOST_LIBRARY_DIR` | `%h/.local/share/immich/library` | photos and videos, mounted at `/data` |
| `HOST_POSTGRES_DIR` | `%h/.local/share/immich/postgres` | the PostgreSQL cluster, local disk only |
| `TZ` | `Asia/Taipei` | timezone of the containers |
| `IMMICH_MACHINE_LEARNING_ENABLED` | `true` | `false` runs Immich without the ML container |

`%h` is your home directory; both `_DIR` keys also accept an absolute path anywhere else.
Moving the data later is: stop the stack, move the directory, change the value, start again.

The database password is the podman secret `immich-db-password`, created on the first
install and never printed. Do not set `DB_PASSWORD`, `DB_USERNAME`, `DB_HOSTNAME` or
`IMMICH_PORT` in the env file; the units own them and `install.sh` warns about them.

**Machine learning** is installed by default. `scripts/install.sh --no-ml` removes it and
tells Immich to stop calling it; the image is about 1.5 GB and the models are downloaded on
first use. For hardware acceleration, change the tag in
`quadlet/optional/immich-machine-learning.container` to a suffixed one (`-cuda`, `-openvino`)
and add the device with `AddDevice=`; keep server and ML versions equal.

## Operations

```bash
systemctl --user status immich-server.service
systemctl --user restart immich.target
journalctl --user -u immich-server.service -f
podman exec immich_postgres psql -U postgres -d immich -c '\dx'   # extensions
tests/smoke.sh
tests/smoke.sh --public-url https://photos.example.com/
```

## Upgrade

The repository is the source of truth: bump `Image=` in `quadlet/immich-server.container`
**and** `quadlet/optional/immich-machine-learning.container` (same version), commit, then:

```bash
git pull
scripts/upgrade.sh              # --allow-major for v2 -> v3
```

It refuses a version skew between the server and ML, a downgrade, and a PostgreSQL major
change; pulls every image before anything stops; takes a cold backup; restarts; smokes with a
900 s timeout; and on failure puts the previous units **and the previous database directory**
back automatically, because Immich's migrations are forward-only.

**PostgreSQL major upgrade** (the DB image changing from 14 to a newer major) needs
`scripts/backup.sh --cold`, then a restore into a fresh cluster: `scripts/restore.sh` does
exactly that after you bump the image and re-run `scripts/install.sh`.

## Backup and restore

```bash
scripts/backup.sh                       # DB dump + library (without thumbs/encoded-video)
scripts/backup.sh --no-library          # DB only, for a library backed up by other means
scripts/backup.sh --cold                # also a byte copy of the PostgreSQL directory
scripts/restore.sh ~/backups/immich/<timestamp> [--with-library] [--yes]
```

A backup directory is mode 0700 with `SHA256SUMS`, which `restore.sh` verifies. It contains
the database password, so keep copies off this host and protect them. `restore.sh` replaces
the database in a fresh cluster (Immich's documented path) and leaves the previous data
directory next to it as `…​.pre-restore-<timestamp>` until you delete it.

A nightly database backup, as the service user:

```bash
systemd-run --user --on-calendar='*-*-* 03:00:00' --unit=immich-backup \
  ~/woow-quadlet/Woow_podman_immich/scripts/backup.sh --no-library
```

## Uninstall

```bash
scripts/uninstall.sh                  # stops and removes the units; keeps all data
scripts/uninstall.sh --purge --yes    # also deletes the model cache, the network, the secret
```

`--purge` never deletes the library or the database directory: it prints the commands for
that instead. The env file is always kept.

## Migrating an existing compose deployment

`scripts/migrate-legacy.sh` adopts the library, the PostgreSQL directory and the
`immich_model-cache` volume in place — **no photo is copied** — and keeps the old containers
and unit for rollback. Downtime is 3-5 minutes.

```bash
# 1. check and prepare while the old stack keeps running (no downtime)
scripts/migrate-legacy.sh --legacy-dir ~/Woow_immich_docker_compose_all --dry-run
scripts/migrate-legacy.sh --legacy-dir ~/Woow_immich_docker_compose_all --prepare-only

# 2. cutover (downtime starts)
scripts/migrate-legacy.sh --legacy-dir ~/Woow_immich_docker_compose_all --yes

# 3. if anything is wrong (about 2 minutes; both stacks share the same data)
scripts/migrate-legacy.sh --rollback --yes
```

The bind mounts are read from `podman inspect`, not guessed. The migration refuses to run
while `podman-restart.service` is enabled: the renamed legacy containers keep
`restart=always`, and a reboot would start a second PostgreSQL on the same data directory.

Changes the migration makes on purpose: the publish moves from `0.0.0.0` to `127.0.0.1`
(`--bind` overrides), the network becomes `immich` (the aliases keep the DNS names), the
database password moves from a world-readable `.env` into a podman secret, and the server and
ML containers get the healthchecks podman drops from OCI images.

**After the soak period** (a week, including one reboot):

```bash
podman rm immich_server-legacy-YYYYMMDD immich_machine_learning-legacy-YYYYMMDD \
          immich_postgres-legacy-YYYYMMDD immich_redis-legacy-YYYYMMDD
podman network rm immich_default
rm ~/.config/systemd/user/podman-immich.service && systemctl --user daemon-reload
```

Then move the data out of the old checkout, so a `git clean` can never reach it:

```bash
systemctl --user stop immich.target
install -d -m 700 ~/.local/share/immich
podman unshare mv ~/Woow_immich_docker_compose_all/postgres ~/.local/share/immich/postgres
mv ~/Woow_immich_docker_compose_all/library ~/.local/share/immich/library
$EDITOR ~/.config/immich/immich.env      # HOST_POSTGRES_DIR, HOST_LIBRARY_DIR
scripts/install.sh
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Unit immich-server.service not found` | the generator rejected a file. Run `tests/dryrun.sh`, then `systemctl --user daemon-reload` |
| install refuses: *legacy container* | a non-Quadlet container owns the name. Quadlet's `--replace` would delete it: rename it (the message prints the command) or use `migrate-legacy.sh` |
| the server restarts in a loop | look for a database error: `journalctl --user -u immich-server.service -n 100`. The `vchord`/`vector` extensions come from the pinned DB image; a different Postgres image will not work |
| machine learning never finishes | the first request downloads a model; check `journalctl --user -u immich-machine-learning.service` |
| the mobile app cannot reach the server | `HOST_BIND=127.0.0.1` only serves this host: use the public URL, or set `0.0.0.0` |
| the stack does not come back after a reboot | linger is off: `sudo loginctl enable-linger $USER` |

## Docker Compose

This repository is Quadlet-only. The last revision with `docker-compose.yml` and
`DEPLOYMENT.md` is tagged
[`compose-final`](https://github.com/WOOWTECH/Woow_podman_immich/tree/compose-final):

```bash
git clone --branch compose-final https://github.com/WOOWTECH/Woow_podman_immich
```

New Docker deployments should follow Immich's own
[Docker Compose instructions](https://immich.app/docs/install/docker-compose), which are the
source of the image pins used here.

## External libraries

Immich can index photos it does not own. Quadlet 4.9.3 has no drop-ins, so the extra mount
belongs in the unit: add `Volume=/path/to/photos:/external:ro` to
`quadlet/immich-server.container`, run `scripts/install.sh`, then add `/external` as an
external library in **Administration > External Libraries**.

## License

[MIT License](LICENSE) — Copyright (c) 2026 WOOWTECH

## References

- [Immich documentation](https://docs.immich.app/)
- [Immich environment variables](https://immich.app/docs/install/environment-variables)
- [Immich backup and restore](https://docs.immich.app/administration/backup-and-restore/)

## Other deployment platforms

- **K3s / Kubernetes (Helm chart)** → [Woow_k3s_immich](https://github.com/WOOWTECH/Woow_k3s_immich)
- **Home Assistant add-on** → [Woow_ha_immich](https://github.com/WOOWTECH/Woow_ha_immich)
