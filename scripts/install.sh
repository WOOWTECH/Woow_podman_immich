#!/usr/bin/env bash
# scripts/install.sh: install or update Immich as rootless Quadlet units (podman 4.9.3,
# systemd --user, linger). Idempotent: a re-run with nothing changed restarts nothing.
#
#   scripts/install.sh [--no-ml] [--db-password-file F] [--no-start] [--no-smoke]
#                      [--smoke-timeout S] [--dry-run]
#
#   --no-ml                write IMMICH_MACHINE_LEARNING_ENABLED=false and skip (or remove)
#                          the machine-learning container. Set it back to true to add it again.
#   --db-password-file F   first install only: take the database password from F instead of
#                          generating one (an existing secret is never replaced)
#   --no-start             install the files and daemon-reload only
#   --no-smoke             skip tests/smoke.sh at the end
#   --smoke-timeout S      seconds tests/smoke.sh waits for health (default 300)
#   --dry-run              render and validate, report what would change; change nothing
#
# The first run creates ~/.config/immich/immich.env from config/immich.env.example and stops
# so you can review it. A host that runs the old compose stack uses migrate-legacy.sh.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"

no_ml=0 db_pw_file='' no_start=0 no_smoke=0 smoke_timeout=300
while (($#)); do
  case $1 in
    --no-ml) no_ml=1 ;;
    --db-password-file) db_pw_file=${2:?--db-password-file needs a file}; shift ;;
    --no-start) no_start=1 ;;
    --no-smoke) no_smoke=1 ;;
    --smoke-timeout) smoke_timeout=${2:?--smoke-timeout needs seconds}; shift ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,21p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
dry=${QL_DRY_RUN:-0}

# ---- 1. host preflight ----------------------------------------------------------------------
ql_preflight "$PODMAN_MIN"
ql_enable_linger
# upgrade.sh and migrate-legacy.sh hold the lock already and call this script.
[[ ${WOOW_QL_LOCK_HELD:-} == "$APP" ]] || ql_lock "$APP"

# ---- 2. per-host settings (D2: values come from the env file, never from the repo) ---------
ql_env_ensure "$ENV_EXAMPLE" "$ENV_FILE"
render_env=$ENV_FILE
if [[ ! -f $ENV_FILE ]]; then
  render_env=$ENV_EXAMPLE # --dry-run on a fresh host: render the defaults
else
  ((!no_ml)) || ql_env_set "$ENV_FILE" IMMICH_MACHINE_LEARNING_ENABLED false
  if [[ $QL_ENV_CREATED == 1 ]]; then
    ql_info "review $ENV_FILE (HOST_LIBRARY_DIR and HOST_POSTGRES_DIR above all), then run $0 again"
    exit 0
  fi
fi
ql_env_load "$render_env"
app_validate_env
library_dir=$(app_dir HOST_LIBRARY_DIR)
postgres_dir=$(app_dir HOST_POSTGRES_DIR)

# ---- 3. legacy guards (Quadlet's `podman run --replace` would delete a same-named container)
for u in "${LEGACY_UNITS[@]}"; do
  if systemctl --user is-active --quiet "$u" 2>/dev/null; then
    ql_die "legacy unit $u is running; migrate this host with scripts/migrate-legacy.sh"
  fi
done
mapfile -t containers < <(app_containers)
for c in "${containers[@]}"; do ql_check_container_collision "${c%%:*}" "${c#*:}"; done
ql_check_path_mounted "$library_dir" "${containers[@]%%:*}"
ql_check_path_mounted "$postgres_dir" "${containers[@]%%:*}"

# ---- 4. stage, render, validate -----------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
app_render "$WORK" "$render_env"
for f in "$WORK/out"/*; do
  u=$(ql_unit_for "$f")
  [[ -z $u ]] || ql_check_unit_shadow "$u" "$APP"
done

# ---- 5. data directories, images and secrets before any unit changes -----------------------
if [[ $dry != 1 ]]; then
  app_ensure_dir "$library_dir"
  app_ensure_dir "$postgres_dir"
fi
ql_pull_images "$WORK/out"
if [[ -n $db_pw_file ]]; then
  [[ -r $db_pw_file ]] || ql_die "cannot read $db_pw_file"
  # shellcheck disable=SC2034 # read by ql_secret_ensure through env:DB_PASSWORD_FROM_FILE
  DB_PASSWORD_FROM_FILE=$(<"$db_pw_file")
  ql_secret_ensure "$SECRET_DB" env:DB_PASSWORD_FROM_FILE
  unset DB_PASSWORD_FROM_FILE
else
  # Immich documents [A-Za-z0-9] for the database password.
  ql_secret_ensure "$SECRET_DB" random:32
fi

# ---- 6. install changed files, then start / restart only what changed ---------------------
if ! app_ml_enabled && app_installed_file immich-machine-learning.container; then
  ql_info "IMMICH_MACHINE_LEARNING_ENABLED=false: removing the machine-learning container"
  ql_remove_files "$APP" immich-machine-learning.container immich-model-cache.volume
fi
changed=$(ql_install_files "$WORK/out" "$APP")
[[ -z $changed ]] || ql_info "changed: $(tr '\n' ' ' <<<"$changed")"
[[ $render_env != "$ENV_FILE" ]] || app_env_mark_if_changed
if [[ $dry == 1 ]]; then
  ql_info "dry-run complete; nothing was changed"
  exit 0
fi
mapfile -t units < <(app_units)
if ((no_start)); then
  systemctl --user daemon-reload
  ql_info "installed; not started (--no-start). Start with: systemctl --user start $TARGET"
  exit 0
fi
ql_apply_units "$APP" "${units[@]}"
app_env_record

# ---- 7. smoke ------------------------------------------------------------------------------
if ((no_smoke)); then
  ql_info "$APP is installed and started (smoke test skipped)"
  exit 0
fi
"$REPO/tests/smoke.sh" --timeout "$smoke_timeout" || ql_die "smoke test failed; see: journalctl --user -u immich-server.service -n 100"
ql_info "$APP is installed and healthy at $(app_base_url)/"
