#!/usr/bin/env bash
# scripts/uninstall.sh: remove the Immich Quadlet units. Keeps every piece of data by default.
#
#   scripts/uninstall.sh                   stop and remove the units; keep the library, the
#                                          database directory, the model cache, the secret,
#                                          the network and ~/.config/immich/immich.env
#   scripts/uninstall.sh --purge [--yes]   also delete the model-cache volume, the network and
#                                          the secret (the secret is exported first)
#   scripts/uninstall.sh --dry-run         report what would be removed
#
# --purge is the only way this repo deletes anything, and it NEVER deletes the bind-mounted
# library or database directory: it prints the command for that, so a mistyped path cannot
# destroy a photo library.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"

purge=0 ASSUME_YES=0
while (($#)); do
  case $1 in
    --purge) purge=1 ;;
    --yes) ASSUME_YES=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
ql_lock "$APP"
library_dir='' postgres_dir=''
if [[ -f $ENV_FILE ]]; then
  ql_env_load "$ENV_FILE"
  library_dir=$(app_dir HOST_LIBRARY_DIR)
  postgres_dir=$(app_dir HOST_POSTGRES_DIR)
fi

if ((!purge)); then
  ql_uninstall_units "$APP"
  [[ ${QL_DRY_RUN:-0} == 1 ]] || rm -f -- "$APP_STATE_DIR/env.sha256"
  ql_info "kept: $library_dir, $postgres_dir, the model cache, the secret and $ENV_FILE"
  exit 0
fi

app_confirm "--purge deletes the model-cache volume, the immich network and the database password secret"
if [[ ${QL_DRY_RUN:-0} != 1 ]]; then
  systemctl --user stop "$TARGET" immich-server.service immich-machine-learning.service \
    immich-redis.service immich-postgres.service 2>/dev/null || true
  dest=$(app_new_backup_dir "$BACKUP_ROOT/purge-$(date +%Y%m%d-%H%M%S)")
  if podman secret exists "$SECRET_DB"; then
    mkdir -p "$dest/secrets"
    app_save_secret "$SECRET_DB" "$dest/secrets/$SECRET_DB"
  fi
  [[ ! -f $ENV_FILE ]] || cp -p -- "$ENV_FILE" "$dest/"
  app_write_checksums "$dest"
  ql_info "kept the database password and the env file in $dest"
fi
ql_uninstall_units "$APP" --purge
ql_info "the photo library and the database directory are UNTOUCHED. Delete them yourself if you want to:"
ql_info "  podman unshare rm -rf ${postgres_dir:-<HOST_POSTGRES_DIR>}   # the database (subuid-owned)"
ql_info "  rm -rf ${library_dir:-<HOST_LIBRARY_DIR>}                    # every photo and video"
ql_info "  rm -rf ${ENV_FILE%/*}"
