#!/usr/bin/env bash
# scripts/migrate-legacy.sh: move a docker-compose / podman-compose Immich deployment
# (containers immich_server, immich_machine_learning, immich_postgres, immich_redis, the
# volume immich_model-cache and a hand-written podman-immich.service) to the Quadlet units of
# this repo. The library and the database directory are adopted where they are: no data is
# copied, and the legacy containers and unit stay for --rollback.
#
#   scripts/migrate-legacy.sh --legacy-dir DIR [--bind ADDR] [--suffix YYYYMMDD]
#                             [--prepare-only | --dry-run] [--no-auto-rollback] [--yes]
#   scripts/migrate-legacy.sh --rollback [--yes]
#   scripts/migrate-legacy.sh --status
#
#   --legacy-dir DIR    the old compose checkout; its .env holds DB_PASSWORD and IMMICH_VERSION
#   --bind ADDR         HOST_BIND of the new publish (default 127.0.0.1; compose used 0.0.0.0)
#   --suffix S          the legacy containers become <name>-legacy-S (default: today). Only
#                       used on the rename path; see "Rollback shape" below.
#   --prepare-only      steps 1-2 only, no downtime: checks, env file, secret, images, hot backup
#   --dry-run           step 1 and a render of the units; changes nothing
#   --no-auto-rollback  leave a failed cutover in place for inspection
#   --rollback          undo the cutover: remove the Quadlet units, bring the legacy
#                       containers back and re-enable the legacy unit
#
# Rollback shape (STANDARD 7a): the legacy containers are kept for --rollback either by
# renaming them and leaving them stopped, or - where the user unit podman-restart.service is
# enabled and a legacy container's restart policy is exactly `always`, as the compose-era
# Immich containers are, because a renamed copy would revive at the next boot and a second
# PostgreSQL would open the same data directory - by capturing them into the backup directory
# and removing them. ql_rollback_strategy decides from this host's real state, never from its
# name, and --dry-run reports which path a cutover would take. The capture is taken in step 2,
# before any downtime.
#
# Steps:  1 pre-flight checks   2 backup (hot pg_dumpall now, cold tar of PGDATA after the stop)
#         3 disable the legacy unit (kept on disk) and retire the legacy containers
#         4 scripts/install.sh adopts the library, PGDATA and immich_model-cache
#         5 tests/smoke.sh      6 --rollback when needed
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"

LEGACY_REQUIRED=("$SERVER_CONTAINER" "$DB_CONTAINER" immich_redis)
LEGACY_UNIT=${LEGACY_UNITS[0]}
STATE=$APP_STATE_DIR/migration.state

mode=migrate legacy_dir='' bind=127.0.0.1 suffix=$(date +%Y%m%d) auto_rollback=1 ASSUME_YES=0
while (($#)); do
  case $1 in
    --legacy-dir) legacy_dir=${2:?--legacy-dir needs a directory}; shift ;;
    --bind) bind=${2:?--bind needs an address}; shift ;;
    --suffix) suffix=${2:?--suffix needs a value}; shift ;;
    --prepare-only) mode=prepare ;;
    --dry-run) mode=dry-run ;;
    --no-auto-rollback) auto_rollback=0 ;;
    --rollback) mode=rollback ;;
    --status) mode=status ;;
    --yes) ASSUME_YES=1 ;;
    -h | --help) sed -n '2,35p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_assert_match --suffix "$suffix" '[A-Za-z0-9._-]+'

state_get() { if [[ -f $STATE ]]; then sed -n "s/^$1=//p" "$STATE" | tail -n1; fi; }
state_set() {
  mkdir -p "$APP_STATE_DIR"
  local tmp
  tmp=$(mktemp "$APP_STATE_DIR/.migration.XXXXXX")
  { if [[ -f $STATE ]]; then grep -v "^$1=" "$STATE" || true; fi; printf '%s=%s\n' "$1" "$2"; } >"$tmp"
  mv -f "$tmp" "$STATE"
}

if [[ $mode == status ]]; then
  if [[ -f $STATE ]]; then cat "$STATE"; else echo "no migration recorded in $STATE"; fi
  exit 0
fi

ql_preflight "$PODMAN_MIN"
ql_lock "$APP"
export WOOW_QL_LOCK_HELD=$APP
unit_exists() { [[ -n $(systemctl --user show -p FragmentPath --value "$1" 2>/dev/null) ]]; }

# =============================================================================================
# 6. rollback
# =============================================================================================
rollback() {
  local status sfx c unit_state bk
  local -a renamed=()
  status=$(state_get STATUS) sfx=$(state_get SUFFIX) bk=$(state_get BACKUP)
  read -ra renamed <<<"$(state_get RENAMED)"
  [[ $status == cutover || $status == "done" ]] || ql_die "nothing to roll back (migration status: ${status:-none})"
  app_confirm "--rollback removes the Immich Quadlet units and brings the legacy containers back"
  ql_info "stopping and removing the Quadlet units (the library, the database and the model cache are kept)"
  ql_uninstall_units "$APP"
  rm -f -- "$APP_STATE_DIR/env.sha256"
  for c in "${renamed[@]}"; do
    if podman container exists "$c"; then
      [[ $(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$c") == immich-*.service ]] \
        || ql_die "container $c exists and is not a Quadlet leftover; resolve it by hand"
      podman rm -f "$c" >/dev/null
    fi
  done
  # renamed back, or recreated from the capture the cutover took - whichever the host needed
  app_legacy_restore "$sfx" "$bk" "${renamed[@]}"
  unit_state=$(state_get LEGACY_UNIT_STATE)
  if unit_exists "$LEGACY_UNIT"; then
    if [[ $unit_state == enabled ]]; then systemctl --user enable "$LEGACY_UNIT" >/dev/null 2>&1; fi
    systemctl --user start "$LEGACY_UNIT"
  else
    podman start "${renamed[@]}" >/dev/null
  fi
  ql_wait_http "http://127.0.0.1:$(state_get LEGACY_PORT)/api/server/ping" 200 180 \
    || ql_die "the legacy Immich did not answer after the rollback"
  state_set STATUS rolled-back
  ql_info "rolled back: the legacy stack runs again. Backup of the attempt: $(state_get BACKUP)"
  ql_info "the new 'immich' network and the podman secret are harmless leftovers; podman network rm immich removes the network"
}

if [[ $mode == rollback ]]; then
  rollback
  exit 0
fi

# =============================================================================================
# 1. pre-flight checks (read-only)
# =============================================================================================
[[ -n $legacy_dir ]] || ql_die "--legacy-dir is required (the old compose checkout with its .env)"
legacy_dir=$(cd -- "$legacy_dir" && pwd -P) || ql_die "no such directory: $legacy_dir"
LEGACY_ENV=$legacy_dir/.env
[[ -r $LEGACY_ENV ]] || ql_die "$LEGACY_ENV not found"
legacy_get() {
  local v
  v=$(sed -n "s/^$1=//p" "$LEGACY_ENV" | tail -n1 | tr -d '\r')
  v=${v#\"} v=${v%\"}
  printf '%s' "$v"
}
# mount_source <container> <destination>: the host path a container bind-mounts there
mount_source() {
  podman inspect --format '{{range .Mounts}}{{.Destination}}|{{.Source}}{{println}}{{end}}' "$1" 2>/dev/null \
    | sed -n "s#^$2|##p" | tail -n1
}

ql_info "step 1/5: pre-flight checks"
case $(state_get STATUS) in
  cutover | "done") ql_die "a cutover is already recorded in $STATE (use --status, or --rollback)" ;;
esac
if [[ $mode == dry-run ]]; then QL_DRY_RUN=1 ql_enable_linger; else ql_enable_linger; fi
legacy_containers=()
for c in "${LEGACY_REQUIRED[@]}"; do
  podman container exists "$c" || ql_die "legacy container $c not found"
  legacy_containers+=("$c")
done
if podman container exists "$ML_CONTAINER"; then legacy_containers+=("$ML_CONTAINER"); fi
for c in "${legacy_containers[@]}"; do
  label=$(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$c")
  [[ $label != immich-*.service ]] || ql_die "$c is already managed by Quadlet ($label)"
  app_running "$c" || ql_die "legacy container $c is not running; start the legacy stack for the hot backup"
done
# How the legacy containers are kept for --rollback: renamed and left stopped, or captured
# and removed. Asked of this host, never of its name (STANDARD 7a, quadlet-lib >= 1.4.0).
# The compose-era Immich containers carry restart=always, so on a host whose
# podman-restart.service is enabled a renamed copy would revive at boot and a second
# PostgreSQL would open the same data directory. That is what the capture path prevents.
STRATEGY=$(ql_rollback_strategy "${legacy_containers[@]}")
if [[ $STRATEGY == rename ]]; then
  for c in "${legacy_containers[@]}"; do
    if podman container exists "$c-legacy-$suffix"; then ql_die "$c-legacy-$suffix already exists; pick another --suffix"; fi
  done
fi
legacy_library=$(mount_source "$SERVER_CONTAINER" /data)
legacy_pgdata=$(mount_source "$DB_CONTAINER" /var/lib/postgresql/data)
[[ -d $legacy_library ]] || ql_die "cannot find the library bind mount of $SERVER_CONTAINER (/data)"
[[ -d $legacy_pgdata ]] || ql_die "cannot find the PGDATA bind mount of $DB_CONTAINER"
[[ $(legacy_get DB_USERNAME) == "$DB_USER" && $(legacy_get DB_DATABASE_NAME) == "$DB_NAME" ]] \
  || ql_die "the legacy .env must use DB_USERNAME=$DB_USER and DB_DATABASE_NAME=$DB_NAME (the units fix them)"
[[ -n $(legacy_get DB_PASSWORD) ]] || ql_die "DB_PASSWORD is empty in $LEGACY_ENV"
legacy_version=$(legacy_get IMMICH_VERSION)
[[ ${legacy_version#v} == "${IMMICH_VERSION#v}" ]] \
  || ql_die "the legacy .env pins IMMICH_VERSION=$legacy_version but this checkout pins $IMMICH_VERSION; migrate at the same version, then upgrade"
legacy_port=$(legacy_get IMMICH_PORT)
legacy_port=${legacy_port:-2283}
ql_assert_match "IMMICH_PORT in the legacy .env" "$legacy_port" '[0-9]{1,5}'
running_version=$(curl -fsS -m 10 "http://127.0.0.1:$legacy_port/api/server/version" 2>/dev/null || true)
if app_is_installed && [[ $(state_get STATUS) != prepared ]]; then
  ql_die "the Immich Quadlet units are already installed; this host needs no migration"
fi
if unit_exists "$LEGACY_UNIT"; then
  ql_info "legacy unit $LEGACY_UNIT: $(systemctl --user is-enabled "$LEGACY_UNIT" 2>/dev/null || true)"
else
  ql_warn "no $LEGACY_UNIT on this host; the legacy containers will be stopped with podman stop"
fi
ql_info "legacy Immich $legacy_version on port $legacy_port, version endpoint: ${running_version:-no answer}"
ql_info "library:  $legacy_library"
ql_info "database: $legacy_pgdata"
if curl -fsS -m 10 "http://127.0.0.1:$legacy_port/api/server/config" 2>/dev/null | grep -q '"isInitialized":false'; then
  ql_warn "this Immich has no admin account yet: whoever opens it first becomes the admin. Create it now"
fi

derive_env() {
  local f=$1 tz
  ql_env_set "$f" HOST_BIND "$bind"
  ql_env_set "$f" HOST_PORT "$legacy_port"
  ql_env_set "$f" HOST_LIBRARY_DIR "$(app_spec_path "$legacy_library")"
  ql_env_set "$f" HOST_POSTGRES_DIR "$(app_spec_path "$legacy_pgdata")"
  tz=$(legacy_get TZ)
  [[ -z $tz ]] || ql_env_set "$f" TZ "$tz"
  if podman container exists "$ML_CONTAINER"; then
    ql_env_set "$f" IMMICH_MACHINE_LEARNING_ENABLED true
  else
    ql_env_set "$f" IMMICH_MACHINE_LEARNING_ENABLED false
  fi
}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-migrate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
if [[ $mode == dry-run ]]; then
  if [[ -f $ENV_FILE ]]; then cp -p -- "$ENV_FILE" "$WORK/immich.env"; else install -m 600 -- "$ENV_EXAMPLE" "$WORK/immich.env"; fi
  derive_env "$WORK/immich.env"
  ql_env_load "$WORK/immich.env"
  app_validate_env
  app_render "$WORK/render" "$WORK/immich.env"
  if [[ $STRATEGY == capture ]]; then
    ql_info "dry-run: checks passed and the units render. The cutover would stop $LEGACY_UNIT, capture ${legacy_containers[*]} into the backup directory and remove them (podman-restart.service would revive a renamed copy here), and install:"
  else
    ql_info "dry-run: checks passed and the units render. The cutover would stop $LEGACY_UNIT, rename ${legacy_containers[*]} to *-legacy-$suffix and install:"
  fi
  sed 's/^/    /' < <(grep -vE '^[[:space:]]*(#|$)' "$WORK/immich.env") >&2
  exit 0
fi

# =============================================================================================
# 2. prepare (no downtime): env file, secret, images, hot backup
# =============================================================================================
ql_info "step 2/5: env file, secret, images and a hot backup (no downtime)"
ql_env_ensure "$ENV_EXAMPLE" "$ENV_FILE"
[[ $QL_ENV_CREATED != 1 ]] || ql_info "filling $ENV_FILE in from $LEGACY_ENV (review it after the cutover)"
derive_env "$ENV_FILE"
ql_env_load "$ENV_FILE"
app_validate_env
# shellcheck disable=SC2034 # read by ql_secret_ensure through env:LEGACY_DB_PASSWORD
LEGACY_DB_PASSWORD=$(legacy_get DB_PASSWORD)
ql_secret_ensure "$SECRET_DB" env:LEGACY_DB_PASSWORD --update
unset LEGACY_DB_PASSWORD
app_render "$WORK/render" "$ENV_FILE"
ql_pull_images "$WORK/render/out"

bk=$(state_get BACKUP)
if [[ $(state_get STATUS) != prepared || ! -d $bk ]]; then
  bk=$(app_new_backup_dir "$BACKUP_ROOT/migrate-$(date +%Y%m%d-%H%M%S)")
fi
(umask 077 && cp -p -- "$LEGACY_ENV" "$bk/legacy.env")
if unit_exists "$LEGACY_UNIT"; then systemctl --user cat "$LEGACY_UNIT" >"$bk/$LEGACY_UNIT" 2>/dev/null || true; fi
podman inspect "${legacy_containers[@]}" >"$bk/inspect.json"
app_dump_db "$bk/immich-db.sql.gz"
mkdir -p "$bk/secrets"
app_save_secret "$SECRET_DB" "$bk/secrets/$SECRET_DB"
{
  printf 'legacy version: %s\nversion endpoint: %s\n' "$legacy_version" "${running_version:-?}"
  printf 'library: %s\npgdata: %s\n' "$legacy_library" "$legacy_pgdata"
  podman exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "select extname || ' ' || extversion from pg_extension order by 1" 2>/dev/null || true
  podman exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "select 'tables=' || count(*) from pg_stat_user_tables" 2>/dev/null || true
} >"$bk/precheck.txt"
# On the capture path the rollback copy is written now, while the legacy stack still runs:
# a container whose create command cannot be replayed is then refused before any downtime.
if [[ $STRATEGY == capture ]]; then app_legacy_capture "$bk" "${legacy_containers[@]}"; fi
app_write_checksums "$bk"
state_set STRATEGY "$STRATEGY"
state_set STATUS prepared
state_set BACKUP "$bk"
state_set SUFFIX "$suffix"
state_set LEGACY_PORT "$legacy_port"
state_set RENAMED "${legacy_containers[*]}"
ql_info "hot backup: $bk"
ql_info "note: the photo library is adopted where it is and never rewritten, so it is not copied here"
if [[ $mode == prepare ]]; then
  ql_info "prepared. Run the cutover (downtime 3-5 min) with the same options minus --prepare-only"
  exit 0
fi

# =============================================================================================
# 3. stop + cold backup + rename (downtime starts)
# =============================================================================================
app_confirm "the cutover stops Immich (about 3-5 minutes of downtime)"
ql_info "step 3/5: stopping the legacy stack, cold copy of the database directory, retiring the legacy containers ($STRATEGY)"
unit_state=$(systemctl --user is-enabled "$LEGACY_UNIT" 2>/dev/null || true)
state_set LEGACY_UNIT_STATE "${unit_state:-absent}"
state_set STATUS cutover
if unit_exists "$LEGACY_UNIT"; then
  systemctl --user disable "$LEGACY_UNIT" >/dev/null 2>&1 || true
  systemctl --user stop "$LEGACY_UNIT" || true
  ! systemctl --user is-active --quiet "$LEGACY_UNIT" || ql_die "$LEGACY_UNIT is still active"
  ql_info "disabled and stopped $LEGACY_UNIT (the unit file stays for --rollback)"
fi
for c in "${legacy_containers[@]}"; do
  if app_running "$c"; then podman stop -t 60 "$c" >/dev/null; fi
  ! app_running "$c" || ql_die "$c is still running"
done
ql_backup_dir "$legacy_pgdata" "$bk/postgres-dir.tgz" >/dev/null
app_legacy_retire "$STRATEGY" "$suffix" "$bk" "${legacy_containers[@]}"
app_write_checksums "$bk"

# =============================================================================================
# 4. install (adopts the library, PGDATA and the model cache)   5. smoke
# =============================================================================================
ql_info "step 4/5: scripts/install.sh"
failed=0
"$REPO/scripts/install.sh" --no-smoke || failed=1
if ((!failed)); then
  ql_info "step 5/5: tests/smoke.sh"
  "$REPO/tests/smoke.sh" --timeout 900 || failed=1
fi
if ((failed)); then
  if ((auto_rollback)); then
    ql_warn "the cutover failed; rolling back automatically (--no-auto-rollback keeps it for inspection)"
    ASSUME_YES=1 rollback
    ql_die "migration failed and was rolled back; the legacy stack runs again. Logs: journalctl --user -u immich-server.service"
  fi
  ql_die "the cutover failed; the new units are left in place. Inspect, then run: $0 --rollback"
fi
state_set STATUS "done"
ql_info "migration complete. Compare with $bk/precheck.txt (extensions, table count)."
if [[ $STRATEGY == capture ]]; then
  ql_info "the legacy containers were captured into $bk/legacy-container and removed (podman-restart.service is enabled here, so a renamed copy would have revived at boot); $LEGACY_UNIT is disabled. Roll back with:"
else
  ql_info "legacy containers *-legacy-$suffix and $LEGACY_UNIT (disabled) are kept for rollback:"
fi
ql_info "  $0 --rollback"
ql_info "after the soak period, clean up as described in README ('After the soak')"
