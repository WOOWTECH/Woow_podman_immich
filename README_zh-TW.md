# Immich on rootless Podman（Quadlet + systemd）

以 **rootless Podman Quadlet unit** 部署自架相片與影片管理系統 [Immich](https://immich.app/)，
由使用者的 systemd 管理。unit 就是部署本身：開機自動啟動（需要 linger）、容器當掉時自動重啟，
所有版本都釘選在這個 repo 裡。

[English version](README.md)

## 架構

```
            systemctl --user start|stop|restart immich.target
                                  │
   ┌────────────────┬─────────────┴────────────┬─────────────────────────┐
   │                │                          │                         │
immich-postgres  immich-redis        immich-machine-learning       immich-server
 PostgreSQL 14    Valkey 9            （選配，約 1.5 GB）           API 與網頁介面
 + VectorChord    無持久化             volume immich_model-cache      │
   │                │                          │                     │
   │  HOST_POSTGRES_DIR                        └── alias immich-machine-learning
   │  （bind mount）                                                  │
   └──────────── network immich（alias：database、redis）────────────┘
                                                                     │
                                          HOST_LIBRARY_DIR -> /data（相片）
                                          PublishPort HOST_BIND:HOST_PORT -> 2283
```

| 檔案 | unit | 內容 |
|---|---|---|
| `quadlet/immich.network` | `immich-network.service` | bridge 網路 `immich` |
| `quadlet/immich-postgres.container` | `immich-postgres.service` | PostgreSQL 14 + VectorChord + pgvecto.rs |
| `quadlet/immich-redis.container` | `immich-redis.service` | Valkey 佇列（依上游設計不做持久化） |
| `quadlet/immich-server.container` | `immich-server.service` | API、網頁介面、背景工作 |
| `quadlet/optional/immich-machine-learning.container` | `immich-machine-learning.service` | 人臉辨識、智慧搜尋 |
| `quadlet/optional/immich-model-cache.volume` | `immich-model-cache-volume.service` | volume `immich_model-cache` |
| `systemd/immich.target` | `immich.target` | 一次操作整個堆疊 |

安裝位置：`~/.config/containers/systemd/`（Quadlet）、`~/.config/systemd/user/`（target）、
`~/.config/immich/immich.env`（設定，權限 0600）。資料庫密碼使用 podman secret。

## 系統需求

- Ubuntu 24.04 或同級系統，**podman >= 4.9.3** rootless，systemd 255 使用者 unit
- 服務帳號啟用 linger（`sudo loginctl enable-linger $USER`）
- 磁碟：不含機器學習約 1.5 GB 映像檔，含機器學習約 3 GB，另外還要放相片庫與資料庫
- PostgreSQL 目錄必須放在**本機磁碟**（不可用 NFS 或 SMB），`install.sh` 會檢查

## 安裝

```bash
git clone https://github.com/WOOWTECH/Woow_podman_immich ~/woow-quadlet/Woow_podman_immich
cd ~/woow-quadlet/Woow_podman_immich
tests/dryrun.sh                       # 選用：驗證所有 unit，不會建立任何東西
scripts/install.sh                    # 第一次執行：建立設定檔後停下
$EDITOR ~/.config/immich/immich.env   # 最重要的是 HOST_LIBRARY_DIR 與 HOST_POSTGRES_DIR
scripts/install.sh                    # 安裝、啟動並執行 smoke 測試
```

接著打開 `http://127.0.0.1:2283`（或你設定的位址）建立管理者帳號。
**第一個造訪的人就會成為管理者**，所以在帳號建立之前不要對外公開，或先加上 Cloudflare Access
與 NPM 的存取清單。

其他選項：`--no-ml`（不安裝機器學習）、`--db-password-file F`（僅第一次安裝）、
`--no-start`、`--no-smoke`、`--smoke-timeout S`、`--dry-run`。

## 設定

`~/.config/immich/immich.env`，權限 0600，只能寫 `KEY=value`：不要加引號，也不要在值後面接
`# 註解`。`HOST_*` 會在安裝時寫進 unit 檔（決策 D2），其餘的鍵會傳給 server 與
machine-learning 容器，因此任何
[Immich 環境變數](https://immich.app/docs/install/environment-variables)都能在這裡設定。
改完之後重新執行 `scripts/install.sh`，它只會重啟有變動的部分。

| 鍵 | 預設 | 說明 |
|---|---|---|
| `HOST_BIND` | `127.0.0.1` | 發布位址；`0.0.0.0` 才能讓區網與手機 App 直接連 |
| `HOST_PORT` | `2283` | 對外埠號（容器內 Immich 固定聽 2283） |
| `HOST_LIBRARY_DIR` | `%h/.local/share/immich/library` | 相片與影片，掛載到 `/data` |
| `HOST_POSTGRES_DIR` | `%h/.local/share/immich/postgres` | PostgreSQL 資料目錄，只能放本機磁碟 |
| `TZ` | `Asia/Taipei` | 容器時區 |
| `IMMICH_MACHINE_LEARNING_ENABLED` | `true` | `false` 代表不使用機器學習容器 |

`%h` 代表家目錄；兩個 `_DIR` 也可以填其他絕對路徑。之後要搬移資料的步驟是：停止服務、搬移
目錄、修改設定值、重新啟動。

資料庫密碼是 podman secret `immich-db-password`，第一次安裝時建立且永不列印。請勿在設定檔裡
設定 `DB_PASSWORD`、`DB_USERNAME`、`DB_HOSTNAME` 或 `IMMICH_PORT`，這些由 unit 決定，
`install.sh` 也會提出警告。

**機器學習**預設會安裝。`scripts/install.sh --no-ml` 會移除它並讓 Immich 不再呼叫；映像檔約
1.5 GB，模型會在第一次使用時下載。要使用硬體加速，請把
`quadlet/optional/immich-machine-learning.container` 的 tag 換成對應版本（`-cuda`、
`-openvino`）並用 `AddDevice=` 加上裝置，同時保持 server 與 ML 版本一致。

## 日常操作

```bash
systemctl --user status immich-server.service
systemctl --user restart immich.target
journalctl --user -u immich-server.service -f
podman exec immich_postgres psql -U postgres -d immich -c '\dx'   # 擴充功能
tests/smoke.sh
tests/smoke.sh --public-url https://photos.example.com/
```

## 升級

repo 是版本的唯一來源：同時修改 `quadlet/immich-server.container` 與
`quadlet/optional/immich-machine-learning.container` 的 `Image=`（版本要一致），commit 之後：

```bash
git pull
scripts/upgrade.sh              # 跨大版本（v2 -> v3）需要 --allow-major
```

它會拒絕 server 與 ML 版本不一致、降版、以及 PostgreSQL 大版本變動；在停止任何服務之前先拉取
所有映像檔；做一次冷備份；重啟；以 900 秒逾時執行 smoke 測試；失敗時自動還原舊 unit
**以及升級前的資料庫目錄**，因為 Immich 的 migration 只能往前。

**PostgreSQL 大版本升級**（資料庫映像檔由 14 換成更新的大版本）需要先
`scripts/backup.sh --cold`，改好映像檔並重新執行 `scripts/install.sh` 之後，再用
`scripts/restore.sh` 還原到全新的叢集。

## 備份與還原

```bash
scripts/backup.sh                       # 資料庫 dump + 相片庫（不含 thumbs/encoded-video）
scripts/backup.sh --no-library          # 只備份資料庫，相片庫另行備份時使用
scripts/backup.sh --cold                # 另外對 PostgreSQL 目錄做位元層級複製
scripts/restore.sh ~/backups/immich/<timestamp> [--with-library] [--yes]
```

備份目錄權限 0700 並附上 `SHA256SUMS`，`restore.sh` 會先驗證。裡面含有資料庫密碼，請另存到
本機以外的地方並妥善保護。`restore.sh` 依照 Immich 官方做法在全新叢集上還原資料庫，舊的資料
目錄會保留為 `….pre-restore-<timestamp>`，確認無誤後再自行刪除。

每日備份資料庫（以服務帳號執行）：

```bash
systemd-run --user --on-calendar='*-*-* 03:00:00' --unit=immich-backup \
  ~/woow-quadlet/Woow_podman_immich/scripts/backup.sh --no-library
```

## 移除

```bash
scripts/uninstall.sh                  # 停止並移除 unit，資料全部保留
scripts/uninstall.sh --purge --yes    # 另外刪除模型快取 volume、網路與 secret
```

`--purge` 永遠不會刪除相片庫與資料庫目錄，只會把對應指令印出來讓你自行決定。設定檔一律保留。

## 從既有 compose 部署遷移

`scripts/migrate-legacy.sh` 會就地沿用相片庫、PostgreSQL 目錄與 `immich_model-cache` volume
（**不會複製任何相片**），並保留舊容器與舊 unit 以便回滾，停機約 3-5 分鐘。

```bash
# 1. 舊堆疊繼續運作時先檢查與準備（不停機）
scripts/migrate-legacy.sh --legacy-dir ~/Woow_immich_docker_compose_all --dry-run
scripts/migrate-legacy.sh --legacy-dir ~/Woow_immich_docker_compose_all --prepare-only

# 2. 切換（開始停機）
scripts/migrate-legacy.sh --legacy-dir ~/Woow_immich_docker_compose_all --yes

# 3. 有問題時回滾（約 2 分鐘，兩邊共用同一份資料）
scripts/migrate-legacy.sh --rollback --yes
```

bind mount 的來源是從 `podman inspect` 讀出來的，不是用猜的。若 `podman-restart.service`
處於啟用狀態，遷移會直接中止：改名後的舊容器仍然是 `restart=always`，重開機後會有第二個
PostgreSQL 對同一份資料目錄啟動。

遷移刻意造成的變更：發布位址由 `0.0.0.0` 改為 `127.0.0.1`（可用 `--bind` 覆寫）、網路改名為
`immich`（alias 保留原本的 DNS 名稱）、資料庫密碼從所有人可讀的 `.env` 移到 podman secret，
以及補上 podman 會忽略的 OCI 映像檔健康檢查。

**觀察期結束後**（約一週，含一次重開機）：

```bash
podman rm immich_server-legacy-YYYYMMDD immich_machine_learning-legacy-YYYYMMDD \
          immich_postgres-legacy-YYYYMMDD immich_redis-legacy-YYYYMMDD
podman network rm immich_default
rm ~/.config/systemd/user/podman-immich.service && systemctl --user daemon-reload
```

接著把資料搬出舊的 git clone，避免 `git clean` 之類的操作波及：

```bash
systemctl --user stop immich.target
install -d -m 700 ~/.local/share/immich
podman unshare mv ~/Woow_immich_docker_compose_all/postgres ~/.local/share/immich/postgres
mv ~/Woow_immich_docker_compose_all/library ~/.local/share/immich/library
$EDITOR ~/.config/immich/immich.env      # HOST_POSTGRES_DIR、HOST_LIBRARY_DIR
scripts/install.sh
```

## 疑難排解

| 現象 | 原因與處理 |
|---|---|
| `Unit immich-server.service not found` | 產生器拒絕了某個檔案。執行 `tests/dryrun.sh`，再 `systemctl --user daemon-reload` |
| 安裝被擋下並顯示 legacy container | 同名容器不是 Quadlet 建立的。Quadlet 的 `--replace` 會刪掉它：依訊息指示改名，或改用 `migrate-legacy.sh` |
| server 不斷重啟 | 先看資料庫錯誤：`journalctl --user -u immich-server.service -n 100`。`vchord`／`vector` 擴充來自釘選的資料庫映像檔，換成其他 Postgres 映像檔不會動 |
| 機器學習一直沒有結果 | 第一次請求會下載模型，查看 `journalctl --user -u immich-machine-learning.service` |
| 手機 App 連不到 | `HOST_BIND=127.0.0.1` 只服務本機：請使用公開網址，或改成 `0.0.0.0` |
| 重開機後服務沒有回來 | linger 沒開：`sudo loginctl enable-linger $USER` |

## Docker Compose

本 repo 只保留 Quadlet 部署。最後一個含 `docker-compose.yml` 與 `DEPLOYMENT.md` 的版本標記為
[`compose-final`](https://github.com/WOOWTECH/Woow_podman_immich/tree/compose-final)：

```bash
git clone --branch compose-final https://github.com/WOOWTECH/Woow_podman_immich
```

全新的 Docker 部署建議直接參考 Immich 官方的
[Docker Compose 說明](https://immich.app/docs/install/docker-compose)，本 repo 釘選的映像檔
版本也是以它為準。

## 外部相片庫

Immich 可以索引不屬於它的相片。Quadlet 4.9.3 沒有 drop-in，因此額外掛載要寫進 unit：在
`quadlet/immich-server.container` 加入 `Volume=/path/to/photos:/external:ro`，執行
`scripts/install.sh`，再到 **Administration > External Libraries** 新增 `/external`。

## 授權

[MIT License](LICENSE) — Copyright (c) 2026 WOOWTECH

## 參考資料

- [Immich 官方文件](https://docs.immich.app/)
- [Immich 環境變數](https://immich.app/docs/install/environment-variables)
- [Immich 備份與還原](https://docs.immich.app/administration/backup-and-restore/)

## 其他部署平台

- **K3s / Kubernetes（Helm chart）** → [Woow_k3s_immich](https://github.com/WOOWTECH/Woow_k3s_immich)
- **Home Assistant add-on** → [Woow_ha_immich](https://github.com/WOOWTECH/Woow_ha_immich)
