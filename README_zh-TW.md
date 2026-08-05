# Immich Docker Compose — 自架式照片與影片管理系統

English | [繁體中文](README_zh-TW.md)

一套可直接用於生產環境的 Docker Compose 堆疊，部署 [Immich](https://immich.app/) — 高效能的自架式 Google Photos 替代方案，內建 AI 驅動的臉部辨識、智慧搜尋與自動標籤功能。

## 系統架構

```
┌─────────────────────────────────────────────────────────────┐
│  主機                                                       │
│                                                             │
│   Port 2283 ──► ┌──────────────────────┐                   │
│                  │   immich-server      │                   │
│                  │   (Web 介面 + API +  │                   │
│                  │    背景工作)          │                   │
│                  └──────────┬───────────┘                   │
│                             │                               │
│              ┌──────────────┼──────────────┐                │
│              ▼              ▼              ▼                 │
│   ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐   │
│   │   database   │ │    redis     │ │ machine-learning │   │
│   │  PostgreSQL  │ │   Valkey 9   │ │  CLIP / 臉部 AI  │   │
│   │  + pgvector  │ │  (工作佇列)   │ │  (智慧搜尋)      │   │
│   │  + VectorCh  │ │              │ │                  │   │
│   └──────┬───────┘ └──────────────┘ └──────────────────┘   │
│          │                                                  │
│          ▼                                                  │
│   ┌──────────────┐     ┌───────────────┐                   │
│   │ ./postgres/  │     │  ./library/   │                   │
│   │ (資料庫檔案)  │     │ (照片/影片)    │                   │
│   └──────────────┘     └───────────────┘                   │
└─────────────────────────────────────────────────────────────┘
```

### 服務概覽

| 服務 | 映像檔 | 用途 | 連接埠 |
|------|--------|------|--------|
| `immich-server` | `ghcr.io/immich-app/immich-server` | Web 介面、REST API、背景工作 | 2283 |
| `immich-machine-learning` | `ghcr.io/immich-app/immich-machine-learning` | 臉部辨識、CLIP 智慧搜尋、OCR | 內部 |
| `redis` | `valkey/valkey:9-alpine` | 工作佇列與快取層 | 內部 |
| `database` | `ghcr.io/immich-app/postgres:14-vectorchord` | PostgreSQL 14 搭配 **pgvector** + VectorChord | 內部 |

> **pgvector 已啟用** — 資料庫映像檔內建 pgvector 和 VectorChord，啟動時自動啟用。這為 Immich 的智慧照片搜尋和臉部辨識嵌入向量提供向量相似度搜尋能力。

## 一鍵部署至 Portainer

使用 Portainer 的 Stack 功能，可透過 GitHub Repository 網址快速部署本專案。

[![Deploy to Portainer](https://img.shields.io/badge/Deploy_to-Portainer-13BEF9?style=for-the-badge&logo=portainer&logoColor=white)](#一鍵部署至-portainer)

### 使用 Git Repository 部署（推薦）

1. 登入你的 Portainer 管理介面
2. 進入 **Stacks** → **Add stack**
3. 選擇 **Repository**
4. 填入以下資訊：

   | 欄位 | 值 |
   |------|-----|
   | **Repository URL** | `https://github.com/WOOWTECH/Woow_podman_immich` |
   | **Repository reference** | `refs/heads/main` |
   | **Compose path** | `docker-compose.yml` |

5. 點擊 **Deploy the stack**

### 使用 Web Editor 部署

1. 複製 `docker-compose.yml` 的 Raw URL：

   ```
   https://raw.githubusercontent.com/WOOWTECH/Woow_podman_immich/main/docker-compose.yml
   ```

2. 登入 Portainer → **Stacks** → **Add stack** → **Web editor**
3. 使用 `curl` 或瀏覽器取得上述 URL 的內容，貼入編輯器
4. 設定環境變數（參考 `.env`）
5. 點擊 **Deploy the stack**

## 系統需求

| 項目 | 最低需求 | 建議配置 |
|------|---------|---------|
| Docker Engine | 20.10+ | 24.0+ |
| Docker Compose | v2.0+（plugin） | v2.20+ |
| 記憶體 | 4 GB | 6 GB+ |
| CPU | 2 核心 | 4 核心 |
| 磁碟 | 10 GB（系統） | 資料庫使用 SSD |
| 儲存空間 | 依相片庫大小而定 | 照片可放 NAS/外接 |

> **重要：** PostgreSQL 資料（`DB_DATA_LOCATION`）**必須**存放在本機磁碟。NFS/網路共享會導致資料庫損壞。照片儲存（`UPLOAD_LOCATION`）可以放在 NAS 或網路共享空間。

## 快速開始

### 1. 複製儲存庫

```bash
git clone https://github.com/WOOWTECH/Woow_podman_immich.git
cd Woow_podman_immich
```

### 2. 設定環境變數

```bash
cp .env.example .env
```

編輯 `.env`，**至少須修改以下項目**：

```bash
# 必填 — 設定一組強隨機密碼（僅限 A-Za-z0-9）
DB_PASSWORD=your_secure_random_password_here

# 建議 — 設定你的時區
TZ=Asia/Taipei

# 選填 — 更改儲存位置
UPLOAD_LOCATION=./library
DB_DATA_LOCATION=./postgres
```

> **安全提醒：** 切勿將 `.env` 提交至版本控制，`.gitignore` 已排除此檔案。

### 3. 啟動服務堆疊

```bash
docker compose up -d
```

### 4. 確認所有服務運行中

```bash
docker compose ps
```

預期輸出 — 全部 4 個容器皆為 `Up (healthy)`：

```
NAME                    STATUS
immich_server           Up (healthy)
immich_machine_learning Up (healthy)
immich_redis            Up (healthy)
immich_postgres         Up (healthy)
```

### 5. 存取 Web 介面

開啟瀏覽器前往：

```
http://<你的伺服器 IP>:2283
```

**第一位註冊的使用者**將自動成為**管理員帳號**，擁有設定、使用者與相片庫的完整控制權。

## 專案結構

```
.
├── docker-compose.yml      # 服務定義（4 個容器）
├── .env.example            # 環境變數範本
├── .env                    # 你的實際設定（已被 git 忽略）
├── .gitignore              # 版本控制排除規則
├── LICENSE                 # MIT 授權條款
├── README.md               # 英文說明文件
├── README_zh-TW.md         # 繁體中文說明文件（本文件）
├── DEPLOYMENT.md           # 快速部署參考 / 技能卡
├── library/                # 照片與影片上傳目錄（已被 git 忽略）
└── postgres/               # PostgreSQL 資料檔案（已被 git 忽略）
```

## 組態參考

### 環境變數

| 變數 | 預設值 | 說明 |
|------|--------|------|
| `UPLOAD_LOCATION` | `./library` | 上傳照片與影片的主機路徑 |
| `DB_DATA_LOCATION` | `./postgres` | PostgreSQL 資料檔案的主機路徑（**僅限本機磁碟**） |
| `IMMICH_VERSION` | `v2` | 映像檔標籤 — 可固定為例如 `v2.5.6` 以維持穩定 |
| `TZ` | — | 時區（[時區列表](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones)） |
| `IMMICH_PORT` | `2283` | Web 介面的主機連接埠 |
| `DB_PASSWORD` | — | **必填** — PostgreSQL 密碼（僅限 A-Za-z0-9） |
| `DB_USERNAME` | `postgres` | PostgreSQL 使用者名稱 |
| `DB_DATABASE_NAME` | `immich` | PostgreSQL 資料庫名稱 |

### 資料庫擴充功能（pgvector）

官方 Immich PostgreSQL 映像檔包含：

- **pgvector**（v0.7+）— 向量相似度搜尋擴充功能
- **VectorChord**（v0.4+）— 最佳化向量索引，更低記憶體用量與更佳搜尋品質

這些擴充功能在啟動時自動偵測並啟用，無需手動設定。`DB_VECTOR_EXTENSION` 環境變數為選填 — 未設定時 Immich 會自動偵測最佳可用擴充功能。

### 硬體加速（選填）

轉碼加速：建立 `hwaccel.transcoding.yml` 並取消 `docker-compose.yml` 中 `extends` 區塊的註解。選項：`nvenc`、`quicksync`、`rkmpp`、`vaapi`。

機器學習加速：建立 `hwaccel.ml.yml` 並取消 ML `extends` 區塊的註解。選項：`cuda`、`rocm`、`openvino`、`armnn`、`rknn`。

參考：https://docs.immich.app/features/ml-hardware-acceleration

## 日常操作

### 啟動 / 停止 / 重啟

```bash
# 啟動所有服務
docker compose up -d

# 停止所有服務（保留資料）
docker compose down

# 重啟所有服務
docker compose restart

# 即時查看日誌
docker compose logs -f

# 查看特定服務日誌
docker compose logs -f immich-server
```

### 更新 Immich

```bash
# 拉取最新映像檔
docker compose pull

# 以新映像檔重建容器
docker compose up -d

# 驗證版本
docker compose ps
```

> **建議：** 在生產環境中將 `IMMICH_VERSION` 固定為特定標籤（例如 `v2.5.6`），避免更新時產生非預期的破壞性變更。

### 健康檢查

```bash
# 檢查容器狀態
docker compose ps

# 檢查 PostgreSQL 連線
docker compose exec database pg_isready -U postgres

# 檢查 pgvector 擴充功能
docker compose exec database psql -U postgres -d immich -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('vector', 'vchord');"

# 檢查 Redis
docker compose exec redis redis-cli ping
```

### 資料庫維護

```bash
# 連線至 PostgreSQL
docker compose exec database psql -U postgres -d immich

# 檢查資料庫大小
docker compose exec database psql -U postgres -d immich \
  -c "SELECT pg_size_pretty(pg_database_size('immich'));"

# 列出資料表及大小
docker compose exec database psql -U postgres -d immich \
  -c "SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size FROM pg_tables WHERE schemaname = 'public' ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC LIMIT 20;"

# 驗證 pgvector 已啟用
docker compose exec database psql -U postgres -d immich \
  -c "SELECT * FROM pg_extension WHERE extname = 'vector';"
```

## 備份與還原

### 備份

```bash
# 完整資料庫備份（壓縮）
docker compose exec -T database pg_dumpall -U postgres | gzip > "backup_immich_$(date +%Y%m%d_%H%M%S).sql.gz"

# 僅資料庫備份（較小）
docker compose exec -T database pg_dump -U postgres -d immich | gzip > "backup_immich_db_$(date +%Y%m%d_%H%M%S).sql.gz"
```

### 自動備份（Cron）

加入排程任務（`crontab -e`）：

```cron
# 每日凌晨 3:00 執行 Immich 資料庫備份
0 3 * * * cd /path/to/Woow_podman_immich && docker compose exec -T database pg_dumpall -U postgres | gzip > backups/backup_$(date +\%Y\%m\%d).sql.gz 2>&1
```

### 還原

```bash
# 先停止 Immich 伺服器
docker compose stop immich-server immich-machine-learning

# 從備份還原
gunzip < backup_immich_20260313.sql.gz | docker compose exec -T database psql -U postgres

# 重啟服務
docker compose up -d
```

### 照片備份

`library/` 目錄包含所有上傳的照片和影片，請使用你慣用的方式備份：

```bash
# 使用 rsync
rsync -av --progress ./library/ /backup/immich-library/

# 使用 tar
tar czf "library_backup_$(date +%Y%m%d).tar.gz" ./library/
```

## 疑難排解

### 容器無法啟動

```bash
# 檢查錯誤日誌
docker compose logs --tail=50 immich-server

# 檢查連接埠是否被佔用
ss -tlnp | grep 2283

# 驗證 .env 是否正確載入
docker compose config
```

### 資料庫連線問題

```bash
# 檢查 PostgreSQL 是否正常運行
docker compose ps database

# 測試連線
docker compose exec database pg_isready -U postgres -d immich

# 檢查 PostgreSQL 日誌
docker compose logs --tail=50 database
```

### pgvector / VectorChord 問題

```bash
# 驗證擴充功能已安裝
docker compose exec database psql -U postgres -d immich \
  -c "SELECT extname, extversion FROM pg_extension;"

# 檢查 shared_preload_libraries
docker compose exec database psql -U postgres \
  -c "SHOW shared_preload_libraries;"
```

### 機器學習功能異常

```bash
# 檢查 ML 容器日誌
docker compose logs --tail=50 immich-machine-learning

# 驗證模型快取
docker volume inspect immich_model-cache

# ML 首次啟動會下載約 1-2GB 模型 — 檢查進度
docker compose logs -f immich-machine-learning
```

### 完全重設

```bash
# 警告：此操作將銷毀所有資料！
docker compose down -v
rm -rf ./library ./postgres
docker compose up -d
```

## 手機 App 設定

1. 從 [App Store](https://apps.apple.com/app/immich/id1613945686) 或 [Google Play](https://play.google.com/store/apps/details?id=app.alextran.immich) 安裝「Immich」
2. 開啟 App 並輸入伺服器網址：`http://<伺服器 IP>:2283/api`
3. 使用管理員帳號登入
4. 在 App 設定中啟用自動備份

## 反向代理（選填）

如需 HTTPS 存取，可將 Immich 放在反向代理後方。Nginx 範例：

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

        # WebSocket 支援
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

> 使用反向代理時，請在 `.env` 中設定 `IMMICH_TRUSTED_PROXIES`。

## 外部相片庫

若要索引現有的照片資料夾而不複製檔案：

1. 在 `docker-compose.yml` 中新增該資料夾為掛載卷：
   ```yaml
   immich-server:
     volumes:
       - ${UPLOAD_LOCATION}:/data
       - /path/to/existing/photos:/data/external:ro
   ```
2. 重啟：`docker compose up -d`
3. 在 Immich Web 介面中：**管理 > 外部相片庫 > 建立相片庫**
4. 設定匯入路徑為 `/data/external`

## 參考資料

- [Immich 官方文件](https://docs.immich.app/)
- [Immich Docker Compose 指南](https://docs.immich.app/install/docker-compose/)
- [Immich 環境變數](https://docs.immich.app/install/environment-variables/)
- [Immich GitHub 儲存庫](https://github.com/immich-app/immich)
- [PostgreSQL pgvector 擴充功能](https://github.com/pgvector/pgvector)
- [VectorChord 擴充功能](https://github.com/tensorchord/VectorChord)
- [Immich 獨立 PostgreSQL 指南](https://docs.immich.app/administration/postgres-standalone/)

## 授權條款

[MIT License](LICENSE) — Copyright (c) 2026 WOOWTECH

---

## 其他部署平台

- **K3s/Kubernetes(Helm chart)** → [Woow_k3s_immich](https://github.com/WOOWTECH/Woow_k3s_immich)
- **Home Assistant add-on** → [Woow_ha_immich](https://github.com/WOOWTECH/Woow_ha_immich)
