# shellcheck shell=bash
# shellcheck disable=SC2034 # these settings are read by the scripts that source this file
# scripts/app.sh: Immich settings and helpers shared by scripts/*.sh and tests/smoke.sh.
# Sourced after scripts/lib/quadlet-lib.sh (the vendored lib, never edited here).
# The caller sets REPO to the repository root before sourcing this file.

# ---- names -----------------------------------------------------------------------------
APP=immich
export QL_APP=$APP
ENV_FILE=$HOME/.config/$APP/$APP.env
ENV_EXAMPLE=$REPO/config/$APP.env.example
PODMAN_MIN=4.9.3
TARGET=immich.target
# Hand-written units of the podman-compose era; they must not run next to the Quadlet units.
LEGACY_UNITS=(podman-immich.service)
BACKUP_ROOT=$HOME/backups/$APP
APP_STATE_DIR=${QL_STATE_ROOT:-$HOME/.local/state/woow-quadlet}/$APP
QDIR=${QL_QUADLET_DIR:-$HOME/.config/containers/systemd}
DB_CONTAINER=immich_postgres
DB_USER=postgres
DB_NAME=immich
SERVER_CONTAINER=immich_server
ML_CONTAINER=immich_machine_learning
MODEL_CACHE_VOLUME=immich_model-cache
SECRET_DB=immich-db-password
# Units whose container reads ~/.config/immich/immich.env (restarted when the file changes).
ENV_READERS=(immich-server.service immich-machine-learning.service)

# ---- pins (the repo is the source of truth for every version) ---------------------------
app_pin() { sed -n 's/^Image=//p' "$REPO/quadlet/$1" | tail -n1; }
# app_tag <image>: its tag, digest stripped
app_tag() {
  local last=${1##*/}
  last=${last%%@*}
  [[ $last == *:* ]] && printf '%s' "${last##*:}"
  return 0
}
# app_installed_image <unit file>: the Image= systemd runs (falls back to the repo pin when
# the unit is not installed). Smoke tests compare against this, so a rolled-back stack passes.
app_installed_image() {
  local f=$QDIR/${1##*/} i=''
  [[ -f $f ]] && i=$(sed -n 's/^Image=//p' "$f" | tail -n1)
  if [[ -n $i ]]; then printf '%s' "$i"; else app_pin "$1"; fi
}
SERVER_IMAGE=$(app_pin immich-server.container)
ML_IMAGE=$(app_pin optional/immich-machine-learning.container)
REDIS_IMAGE=$(app_pin immich-redis.container)
PG_IMAGE=$(app_pin immich-postgres.container)
IMMICH_VERSION=$(app_tag "$SERVER_IMAGE")

# ---- per-host settings --------------------------------------------------------------------
app_ml_enabled() { [[ $(ql_env_get IMMICH_MACHINE_LEARNING_ENABLED true) != false ]]; }

# app_units: every unit this host runs, the target first
app_units() {
  printf '%s\n' "$TARGET" immich-postgres.service immich-redis.service
  if app_ml_enabled; then printf '%s\n' immich-machine-learning.service; fi
  printf '%s\n' immich-server.service
}

# app_containers: name:unit of every container this host runs
app_containers() {
  printf '%s\n' "$DB_CONTAINER:immich-postgres.service" immich_redis:immich-redis.service
  if app_ml_enabled; then printf '%s\n' "$ML_CONTAINER:immich-machine-learning.service"; fi
  printf '%s\n' "$SERVER_CONTAINER:immich-server.service"
}

# app_spec_path <abs path>: rewrite $HOME/... as %h/... so a rendered unit carries no
# literal home path (systemd expands %h when it starts the unit)
app_spec_path() {
  local p=$1
  [[ $p == "$HOME"/* ]] && p="%h/${p#"$HOME"/}"
  printf '%s' "$p"
}

# app_dir <KEY>: the value of a HOST_*_DIR key with %h expanded
app_dir() { ql_expand_home "$(ql_env_get "$1")"; }

# app_ensure_dir <path>: create it 0700 when missing. Never chmod an existing directory:
# after the first start PGDATA belongs to a container subuid, which we cannot chmod.
app_ensure_dir() {
  [[ -d $1 ]] && return 0
  (umask 077 && mkdir -p -- "$1") || ql_die "cannot create $1"
  ql_info "created $1"
}

# app_validate_env: dies on a value the units or Immich cannot work with (QL_ENV is loaded)
app_validate_env() {
  local port k d fs
  ql_assert_match HOST_BIND "$(ql_env_get HOST_BIND)" '[0-9]{1,3}(\.[0-9]{1,3}){3}|\[[0-9A-Fa-f:.]+\]'
  port=$(ql_env_get HOST_PORT)
  ql_assert_match HOST_PORT "$port" '[0-9]{1,5}'
  ((10#$port >= 1 && 10#$port <= 65535)) || ql_die "HOST_PORT=$port is not a TCP port"
  ql_assert_match IMMICH_MACHINE_LEARNING_ENABLED "$(ql_env_get IMMICH_MACHINE_LEARNING_ENABLED true)" 'true|false'
  for k in HOST_LIBRARY_DIR HOST_POSTGRES_DIR; do
    d=$(ql_env_get "$k")
    [[ $d == /* || $d == '%h/'* ]] || ql_die "$k=$d must be an absolute path or start with %h/ (your home directory)"
    [[ $d != *:* ]] || ql_die "$k=$d must not contain ':'"
  done
  d=$(app_dir HOST_POSTGRES_DIR)
  if [[ -d $d ]]; then
    fs=$(stat -f -c %T -- "$d" 2>/dev/null || echo unknown)
    case $fs in
      nfs* | smb* | cifs | fuseblk | 9p | tmpfs)
        ql_die "HOST_POSTGRES_DIR is on a $fs filesystem; a PostgreSQL cluster must live on local disk" ;;
    esac
  fi
  [[ -z ${QL_ENV[IMMICH_PORT]+x} ]] || ql_die "IMMICH_PORT in $ENV_FILE is Immich's port INSIDE the container; the host port is HOST_PORT"
  for k in DB_USERNAME DB_DATABASE_NAME DB_PASSWORD DB_HOSTNAME REDIS_HOSTNAME; do
    [[ -z ${QL_ENV[$k]+x} ]] || ql_warn "$k in $ENV_FILE is ignored: the units set it (the password is a podman secret)"
  done
  return 0
}

# app_base_url: where this host reaches the published port
app_base_url() {
  local b
  b=$(ql_env_get HOST_BIND)
  case $b in 0.0.0.0) b=127.0.0.1 ;; '[::]') b='[::1]' ;; esac
  printf 'http://%s:%s' "$b" "$(ql_env_get HOST_PORT)"
}

# ---- render ---------------------------------------------------------------------------------
# app_render <workdir> <envfile>: stage the units this host installs, render them into
# <workdir>/out and run the generator dry-run. Dies on any problem; nothing is installed.
app_render() {
  local w=$1 env=$2
  mkdir -p "$w/src" "$w/out"
  cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.network "$REPO"/systemd/* "$w/src/"
  if app_ml_enabled; then cp -p "$REPO"/quadlet/optional/* "$w/src/"; fi
  ql_render "$w/src" "$env" "$REPO/quadlet/render-vars" "$w/out"
  ql_dryrun "$w/out" --verify --ref-dir "$QDIR" || ql_die "the rendered units failed the dry-run; nothing was installed"
}

# ---- install state (quadlet-lib keeps a sha256sum-format manifest per app) -----------------
app_manifest() { printf '%s/manifest' "$APP_STATE_DIR"; }
app_is_installed() { [[ -s $(app_manifest) ]]; }
app_require_installed() { app_is_installed || ql_die "$APP is not installed on this host (run scripts/install.sh first)"; }
app_installed_file() { app_is_installed && awk -v b="$1" '{ n = split($2, p, "/"); if (p[n] == b) f = 1 } END { exit !f }' "$(app_manifest)"; }

# app_snapshot_units <dir>: copy every installed unit file into <dir> (flat), so a later
# `ql_install_files <dir> $APP --prune` puts exactly this set back (upgrade rollback).
app_snapshot_units() {
  local dest=$1 sha path
  mkdir -p "$dest"
  while read -r sha path; do
    [[ -n $sha && -f $path ]] || continue
    cp -p -- "$path" "$dest/"
  done <"$(app_manifest)"
}

# The containers read the env file at start, so a changed file must restart them.
app_env_hash() { sha256sum <"$ENV_FILE" | cut -d' ' -f1; }
app_env_mark_if_changed() {
  local f=$APP_STATE_DIR/env.sha256
  if [[ ! -f $f || $(<"$f") != "$(app_env_hash)" ]]; then ql_mark_changed "$APP" "${ENV_READERS[@]}"; fi
}
app_env_record() {
  [[ ${QL_DRY_RUN:-0} == 1 ]] && return 0
  mkdir -p "$APP_STATE_DIR" && app_env_hash >"$APP_STATE_DIR/env.sha256"
}

# ---- secrets, database ----------------------------------------------------------------------
# app_save_secret <name> <file>: the secret value into a 0600 file, without a trailing newline
app_save_secret() {
  local v
  v=$(podman secret inspect --showsecret --format '{{.SecretData}}' "$1") || ql_die "cannot read secret $1"
  (umask 077 && printf '%s' "$v" >"$2") || ql_die "cannot write $2"
}

# app_dump_db <file.sql.gz>: Immich's documented backup command (pg_dumpall, roles included)
app_dump_db() {
  (umask 077 && podman exec "$DB_CONTAINER" pg_dumpall --clean --if-exists -U "$DB_USER" | gzip >"$1.partial") \
    || { rm -f -- "$1.partial"; ql_die "pg_dumpall failed"; }
  [[ -s $1.partial ]] || { rm -f -- "$1.partial"; ql_die "the database dump is empty"; }
  mv -f -- "$1.partial" "$1"
  ql_info "dumped the database -> $1 ($(du -h -- "$1" | cut -f1))"
}

# app_restore_db <file.sql.gz>: Immich's documented restore command. It expects a cluster
# that immich-postgres has just initialised (restore.sh moves the old data directory aside).
app_restore_db() {
  gunzip -c -- "$1" \
    | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
    | podman exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d postgres >/dev/null \
    || ql_die "restoring $1 failed"
  ql_info "restored the database from $1"
}

# app_pg_major_running / app_pg_major_image <image>: the PostgreSQL major version
app_pg_major_running() { podman exec "$DB_CONTAINER" sh -c 'echo "$PG_MAJOR"' 2>/dev/null || true; }
app_pg_major_image() {
  podman image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null | sed -n 's/^PG_MAJOR=//p' | tail -n1
}

# app_write_checksums <dir>: SHA256SUMS over every file below <dir> (restore.sh verifies it)
app_write_checksums() {
  local list
  list=$(cd -- "$1" && find . -type f ! -name 'SHA256SUMS*' ! -name '*.sha256' -printf '%P\n' | LC_ALL=C sort) \
    || ql_die "cannot list $1"
  (cd -- "$1" && umask 077 && while IFS= read -r f; do if [[ -n $f ]]; then sha256sum -- "$f"; fi; done <<<"$list" >SHA256SUMS.tmp \
    && mv -f SHA256SUMS.tmp SHA256SUMS) || ql_die "cannot write $1/SHA256SUMS"
}

# app_new_backup_dir [dir]: a fresh private directory. Without an argument it is
# ~/backups/immich/<timestamp>, with -2, -3, ... when several backups land in the same second.
app_new_backup_dir() {
  local d=${1:-} base i=2
  if [[ -z $d ]]; then
    base=$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)
    d=$base
    while [[ -e $d ]]; do d=$base-$i; i=$((i + 1)); done
  fi
  [[ ! -e $d ]] || ql_die "$d already exists"
  (umask 077 && mkdir -p -- "$d") || ql_die "cannot create $d"
  printf '%s' "$d"
}

# app_running <container>
app_running() { [[ $(podman inspect --format '{{.State.Running}}' "$1" 2>/dev/null) == true ]]; }

# app_api_version: the version the running server reports, as x.y.z ("" when it is down)
app_api_version() {
  local j
  j=$(curl -fsS -m 10 "$(app_base_url)/api/server/version" 2>/dev/null) || return 0
  printf '%s.%s.%s' "$(sed -n 's/.*"major":\([0-9]*\).*/\1/p' <<<"$j")" \
    "$(sed -n 's/.*"minor":\([0-9]*\).*/\1/p' <<<"$j")" "$(sed -n 's/.*"patch":\([0-9]*\).*/\1/p' <<<"$j")"
}

# app_confirm <what>: interactive "type the app name" confirmation unless --yes was given
app_confirm() {
  [[ ${ASSUME_YES:-0} == 1 || ${QL_DRY_RUN:-0} == 1 ]] && return 0
  [[ -t 0 ]] || ql_die "$1; add --yes to confirm non-interactively"
  local answer
  read -r -p "$1. Type '$APP' to continue: " answer
  [[ $answer == "$APP" ]] || ql_die "aborted; nothing was changed"
}

# ---- the legacy rollback model (STANDARD 7a; quadlet-lib >= 1.4.0) -----------------------
# Keeping the legacy containers renamed and stopped is a rollback path only while nothing
# starts them again. The user unit podman-restart.service runs
# `podman start --all --filter restart-policy=always` at boot, so where it is enabled a
# renamed, stopped container whose policy is exactly `always` revives and fights the new
# Quadlet container for its name, ports and volumes. podman 4.9.3 cannot defuse that in
# place - `podman update` is cgroup-only, a restart policy is fixed at create time - so the
# answer there is to capture the container and remove it. ql_rollback_strategy asks this
# host (is that unit enabled, what is each container's policy) and answers `rename` or
# `capture`; it never looks at a host name.

# app_legacy_capture <backup dir> <container>...: write the rollback copy of each container.
# Read-only towards the containers, so it belongs in the prepare phase, before any downtime:
# a container the library cannot replay (an empty CreateCommand - created through the podman
# API rather than the CLI) is refused here, while the legacy stack is still running.
app_legacy_capture() {
  local bk=${1:?usage: app_legacy_capture <backup dir> <container>...} c meta
  shift
  for c in "$@"; do
    meta=$bk/legacy-container/$c/meta
    if [[ -f $meta ]]; then
      ql_info "the rollback copy of $c is already in $bk/legacy-container/$c"
    else
      ql_capture_container "$c" "$bk" >/dev/null
    fi
    [[ $(sed -n 's/^RECREATABLE=//p' "$meta" | tail -n1) == 1 ]] || ql_die \
      "$c was created through the podman API, not the CLI, so its create command cannot be replayed and a capture-based rollback is impossible. Either disable podman-restart.service (then the legacy containers can simply be renamed) or plan to rebuild $c by hand from $bk/legacy-container/$c/inspect.json"
  done
}

# app_legacy_retire <strategy> <suffix> <backup dir> <container>...: take the legacy
# containers out of the new stack's way, in the shape the strategy asked for.
app_legacy_retire() {
  # The suffix is empty on the capture path: nothing is renamed there, so there is no
  # <name>-legacy-<suffix> to name. ${2-} rather than ${2:?}, which would abort the script.
  local strategy=${1:?} sfx=${2-} bk=${3:?} c
  shift 3
  for c in "$@"; do
    case $strategy in
      rename)
        [[ -n $sfx ]] || ql_die "the rename path needs a suffix for $c-legacy-<suffix>"
        podman rename "$c" "$c-legacy-$sfx" || ql_die "podman rename $c failed"
        ql_info "renamed $c -> $c-legacy-$sfx (stopped, kept for --rollback)" ;;
      capture)
        [[ -f $bk/legacy-container/$c/meta ]] || ql_die "no rollback copy of $c in $bk; nothing was removed"
        # A plain rm on purpose: `podman rm -v` would delete the anonymous volumes that the
        # capture records and expects to find again.
        podman rm "$c" >/dev/null || ql_die "podman rm $c failed"
        ql_info "removed $c; --rollback recreates it from $bk/legacy-container/$c" ;;
      *) ql_die "unknown rollback strategy '$strategy'" ;;
    esac
  done
}

# app_legacy_restore <suffix> <backup dir> <container>...: bring the legacy containers back,
# whichever shape the cutover used. A recreated container comes back stopped and with its
# original restart policy; the caller starts it, exactly as it starts a renamed one.
app_legacy_restore() {
  # An empty suffix means the cutover captured rather than renamed: there is no
  # <name>-legacy-<suffix> to look for, only the rollback copy.
  local sfx=${1-} bk=${2:?} c
  shift 2
  for c in "$@"; do
    if [[ -n $sfx ]] && podman container exists "$c-legacy-$sfx"; then
      podman rename "$c-legacy-$sfx" "$c" || ql_die "podman rename $c-legacy-$sfx failed"
      ql_info "renamed $c-legacy-$sfx -> $c"
    elif [[ -f $bk/legacy-container/$c/meta ]]; then
      ql_recreate_container "$bk" "$c" >/dev/null || ql_die "could not recreate $c from $bk"
      ql_info "recreated $c from $bk/legacy-container/$c (stopped, with its original restart policy)"
    else
      ql_die "neither the renamed container ${sfx:+$c-legacy-$sfx }nor a rollback copy in $bk exists; restore $c by hand"
    fi
  done
}
