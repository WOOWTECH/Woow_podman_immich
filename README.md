# Immich Docker Compose — Self-Hosted Photo & Video Management

[繁體中文](README_zh-TW.md) | English

A production-ready Docker Compose stack for [Immich](https://immich.app/) — a high-performance, self-hosted alternative to Google Photos with AI-powered features including facial recognition, smart search, and automatic tagging.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Host Machine                                               │
│                                                             │
│   Port 2283 ──► ┌──────────────────────┐                   │
│                  │   immich-server      │                   │
│                  │   (Web UI + API +    │                   │
│                  │    Background Jobs)  │                   │
│                  └──────────┬───────────┘                   │
│                             │                               │
│              ┌──────────────┼──────────────┐                │
│              ▼              ▼              ▼                 │
│   ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐   │
│   │   database   │ │    redis     │ │ machine-learning │   │
│   │  PostgreSQL  │ │   Valkey 9   │ │  CLIP / Face AI  │   │
│   │  + pgvector  │ │  (job queue) │ │  (smart search)  │   │
│   │  + VectorCh  │ │              │ │                  │   │
│   └──────┬───────┘ └──────────────┘ └──────────────────┘   │
│          │                                                  │
│          ▼                                                  │
│   ┌──────────────┐     ┌───────────────┐                   │
│   │ ./postgres/  │     │  ./library/   │                   │
│   │ (DB files)   │     │ (photos/vids) │                   │
│   └──────────────┘     └───────────────┘                   │
└─────────────────────────────────────────────────────────────┘
```

### Service Overview

| Service | Image | Purpose | Port |
|---------|-------|---------|------|
| `immich-server` | `ghcr.io/immich-app/immich-server` | Web UI, REST API, background jobs | 2283 |
| `immich-machine-learning` | `ghcr.io/immich-app/immich-machine-learning` | Face recognition, CLIP smart search, OCR | internal |
| `redis` | `valkey/valkey:9-alpine` | Job queue and caching layer | internal |
| `database` | `ghcr.io/immich-app/postgres:14-vectorchord` | PostgreSQL 14 with **pgvector** + VectorChord | internal |

> **pgvector is ON** — The database image ships with pgvector and VectorChord pre-installed and auto-enabled. This powers Immich's vector-similarity search for smart photo search and facial recognition embeddings.

## Deploy to Portainer

Deploy this project instantly using Portainer's Stack feature with our GitHub repository URL.

[![Deploy to Portainer](https://img.shields.io/badge/Deploy_to-Portainer-13BEF9?style=for-the-badge&logo=portainer&logoColor=white)](#deploy-to-portainer)

### Via Git Repository (Recommended)

1. Log in to your Portainer dashboard
2. Navigate to **Stacks** → **Add stack**
3. Select **Repository**
4. Fill in the following:

   | Field | Value |
   |-------|-------|
   | **Repository URL** | `https://github.com/WOOWTECH/Woow_podman_immich` |
   | **Repository reference** | `refs/heads/main` |
   | **Compose path** | `docker-compose.yml` |

5. Click **Deploy the stack**

### Via Web Editor

1. Copy the raw URL of `docker-compose.yml`:

   ```
   https://raw.githubusercontent.com/WOOWTECH/Woow_podman_immich/main/docker-compose.yml
   ```

2. Log in to Portainer → **Stacks** → **Add stack** → **Web editor**
3. Fetch the content from the URL above using `curl` or your browser, paste into the editor
4. Set environment variables (refer to `.env`)
5. Click **Deploy the stack**

## Prerequisites

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| Docker Engine | 20.10+ | 24.0+ |
| Docker Compose | v2.0+ (plugin) | v2.20+ |
| RAM | 4 GB | 6 GB+ |
| CPU | 2 cores | 4 cores |
| Disk | 10 GB (system) | SSD for database |
| Storage | Depends on library size | NAS/external for photos OK |

> **Important:** PostgreSQL data (`DB_DATA_LOCATION`) **must** be on local disk. NFS/network shares cause database corruption. Photo storage (`UPLOAD_LOCATION`) can be on NAS or network shares.

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/WOOWTECH/Woow_podman_immich.git
cd Woow_podman_immich
```

### 2. Configure Environment Variables

```bash
cp .env.example .env
```

Edit `.env` and **change at minimum**:

```bash
# REQUIRED — Set a strong random password (A-Za-z0-9 only)
DB_PASSWORD=your_secure_random_password_here

# RECOMMENDED — Set your timezone
TZ=Asia/Taipei

# OPTIONAL — Change storage locations
UPLOAD_LOCATION=./library
DB_DATA_LOCATION=./postgres
```

> **Security:** Never commit `.env` to version control. It's already in `.gitignore`.

### 3. Launch the Stack

```bash
docker compose up -d
```

### 4. Verify All Services Are Running

```bash
docker compose ps
```

Expected output — all 4 containers should be `Up (healthy)`:

```
NAME                    STATUS
immich_server           Up (healthy)
immich_machine_learning Up (healthy)
immich_redis            Up (healthy)
immich_postgres         Up (healthy)
```

### 5. Access the Web UI

Open your browser and navigate to:

```
http://<your-server-ip>:2283
```

The **first user** you register becomes the **admin** account with full control over settings, users, and libraries.

## Project Structure

```
.
├── docker-compose.yml      # Service definitions (4 containers)
├── .env.example            # Environment variable template
├── .env                    # Your actual config (git-ignored)
├── .gitignore              # Files excluded from version control
├── LICENSE                 # MIT License
├── README.md               # English documentation (this file)
├── README_zh-TW.md         # 繁體中文 documentation
├── DEPLOYMENT.md           # Quick deployment reference / skill card
├── library/                # Photo & video uploads (git-ignored)
└── postgres/               # PostgreSQL data files (git-ignored)
```

## Configuration Reference

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `UPLOAD_LOCATION` | `./library` | Host path for uploaded photos and videos |
| `DB_DATA_LOCATION` | `./postgres` | Host path for PostgreSQL data files (**local disk only**) |
| `IMMICH_VERSION` | `v2` | Image tag — pin to e.g. `v2.5.6` for stability |
| `TZ` | — | Timezone ([TZ list](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones)) |
| `IMMICH_PORT` | `2283` | Host port for web UI |
| `DB_PASSWORD` | — | **Required** — PostgreSQL password (A-Za-z0-9 only) |
| `DB_USERNAME` | `postgres` | PostgreSQL username |
| `DB_DATABASE_NAME` | `immich` | PostgreSQL database name |

### Database Extensions (pgvector)

The official Immich PostgreSQL image includes:

- **pgvector** (v0.7+) — Vector similarity search extension
- **VectorChord** (v0.4+) — Optimized vector index with lower RAM and better search quality

These are auto-detected and enabled at startup. No manual configuration needed. The `DB_VECTOR_EXTENSION` environment variable is optional — when not set, Immich auto-detects the best available extension.

### Hardware Acceleration (Optional)

For transcoding acceleration, create `hwaccel.transcoding.yml` and uncomment the `extends` section in `docker-compose.yml`. Options: `nvenc`, `quicksync`, `rkmpp`, `vaapi`.

For ML acceleration, create `hwaccel.ml.yml` and uncomment the ML `extends` section. Options: `cuda`, `rocm`, `openvino`, `armnn`, `rknn`.

See: https://docs.immich.app/features/ml-hardware-acceleration

## Operations

### Start / Stop / Restart

```bash
# Start all services
docker compose up -d

# Stop all services (preserves data)
docker compose down

# Restart all services
docker compose restart

# View real-time logs
docker compose logs -f

# View logs for a specific service
docker compose logs -f immich-server
```

### Update Immich

```bash
# Pull latest images
docker compose pull

# Recreate containers with new images
docker compose up -d

# Verify versions
docker compose ps
```

> **Tip:** Pin `IMMICH_VERSION` to a specific tag (e.g., `v2.5.6`) in production to avoid unexpected breaking changes during updates.

### Health Checks

```bash
# Check container status
docker compose ps

# Check PostgreSQL connectivity
docker compose exec database pg_isready -U postgres

# Check pgvector extension
docker compose exec database psql -U postgres -d immich -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('vector', 'vchord');"

# Check Redis
docker compose exec redis redis-cli ping
```

### Database Maintenance

```bash
# Connect to PostgreSQL
docker compose exec database psql -U postgres -d immich

# Check database size
docker compose exec database psql -U postgres -d immich \
  -c "SELECT pg_size_pretty(pg_database_size('immich'));"

# List tables and sizes
docker compose exec database psql -U postgres -d immich \
  -c "SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size FROM pg_tables WHERE schemaname = 'public' ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC LIMIT 20;"

# Verify pgvector is active
docker compose exec database psql -U postgres -d immich \
  -c "SELECT * FROM pg_extension WHERE extname = 'vector';"
```

## Backup & Restore

### Backup

```bash
# Full database backup (compressed)
docker compose exec -T database pg_dumpall -U postgres | gzip > "backup_immich_$(date +%Y%m%d_%H%M%S).sql.gz"

# Database-only backup (smaller)
docker compose exec -T database pg_dump -U postgres -d immich | gzip > "backup_immich_db_$(date +%Y%m%d_%H%M%S).sql.gz"
```

### Automated Backup (Cron)

Add to crontab (`crontab -e`):

```cron
# Daily Immich database backup at 3:00 AM
0 3 * * * cd /path/to/Woow_podman_immich && docker compose exec -T database pg_dumpall -U postgres | gzip > backups/backup_$(date +\%Y\%m\%d).sql.gz 2>&1
```

### Restore

```bash
# Stop Immich server first
docker compose stop immich-server immich-machine-learning

# Restore from backup
gunzip < backup_immich_20260313.sql.gz | docker compose exec -T database psql -U postgres

# Restart services
docker compose up -d
```

### Photo Backup

The `library/` directory contains all uploaded photos and videos. Back it up with your preferred method:

```bash
# Using rsync
rsync -av --progress ./library/ /backup/immich-library/

# Using tar
tar czf "library_backup_$(date +%Y%m%d).tar.gz" ./library/
```

## Troubleshooting

### Container Won't Start

```bash
# Check logs for errors
docker compose logs --tail=50 immich-server

# Check if ports are in use
ss -tlnp | grep 2283

# Verify .env is loaded
docker compose config
```

### Database Connection Issues

```bash
# Check PostgreSQL is running and healthy
docker compose ps database

# Test connectivity
docker compose exec database pg_isready -U postgres -d immich

# Check PostgreSQL logs
docker compose logs --tail=50 database
```

### pgvector / VectorChord Issues

```bash
# Verify extensions are installed
docker compose exec database psql -U postgres -d immich \
  -c "SELECT extname, extversion FROM pg_extension;"

# Check shared_preload_libraries
docker compose exec database psql -U postgres \
  -c "SHOW shared_preload_libraries;"
```

### Machine Learning Not Working

```bash
# Check ML container logs
docker compose logs --tail=50 immich-machine-learning

# Verify model cache
docker volume inspect immich_model-cache

# ML first-run downloads ~1-2GB of models — check progress
docker compose logs -f immich-machine-learning
```

### Reset Everything

```bash
# WARNING: This destroys ALL data!
docker compose down -v
rm -rf ./library ./postgres
docker compose up -d
```

## Mobile App Setup

1. Install "Immich" from [App Store](https://apps.apple.com/app/immich/id1613945686) or [Google Play](https://play.google.com/store/apps/details?id=app.alextran.immich)
2. Open the app and enter your server URL: `http://<server-ip>:2283/api`
3. Log in with your admin credentials
4. Enable automatic backup in app settings

## Reverse Proxy (Optional)

For HTTPS access, put Immich behind a reverse proxy. Example with Nginx:

```nginx
server {
    listen 443 ssl;
    server_name photos.example.com;

    ssl_certificate     /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    client_max_body_size 50000M;

    location / {
        proxy_pass http://127.0.0.1:2283;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

> Set `IMMICH_TRUSTED_PROXIES` in `.env` if using a reverse proxy.

## External Libraries

To index existing photo folders without copying files:

1. Add the folder as a volume in `docker-compose.yml`:
   ```yaml
   immich-server:
     volumes:
       - ${UPLOAD_LOCATION}:/data
       - /path/to/existing/photos:/data/external:ro
   ```
2. Restart: `docker compose up -d`
3. In Immich web UI: **Administration > External Libraries > Create Library**
4. Set the import path to `/data/external`

## References

- [Immich Official Documentation](https://docs.immich.app/)
- [Immich Docker Compose Guide](https://docs.immich.app/install/docker-compose/)
- [Immich Environment Variables](https://docs.immich.app/install/environment-variables/)
- [Immich GitHub Repository](https://github.com/immich-app/immich)
- [PostgreSQL pgvector Extension](https://github.com/pgvector/pgvector)
- [VectorChord Extension](https://github.com/tensorchord/VectorChord)
- [Immich Standalone PostgreSQL Guide](https://docs.immich.app/administration/postgres-standalone/)

## License

[MIT License](LICENSE) — Copyright (c) 2026 WOOWTECH

---

## Other deployment platforms

- **K3s/Kubernetes (Helm chart)** → [Woow_k3s_immich](https://github.com/WOOWTECH/Woow_k3s_immich)
- **Home Assistant add-on** → [Woow_ha_immich](https://github.com/WOOWTECH/Woow_ha_immich)
