#!/usr/bin/env bash
# scripts/restore.sh: put a scripts/backup.sh backup back into the installed Immich stack.
#
#   scripts/restore.sh <backup-dir> [--with-library] [--yes]
#
# 1. verifies SHA256SUMS
# 2. stops immich.target
# 3. restores the podman secret from the backup: pg_dumpall carries the role's password hash,
#    so the secret and the dump have to travel together
# 4. moves the PostgreSQL directory aside (kept as <dir>.pre-restore-<timestamp>) and lets
#    immich-postgres initialise a fresh cluster, which is Immich's documented restore path
# 5. loads immich-db.sql.gz into it
# 6. --with-library also replaces the library from library.tgz (the library is normally
#    intact and huge, so it is not touched by default)
# 7. starts the stack and runs tests/smoke.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"

src='' with_library=0 ASSUME_YES=0
while (($#)); do
  case $1 in
    --with-library) with_library=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h | --help) sed -n '2,17p' "$0"; exit 0 ;;
    -*) ql_die "unknown option $1 (see --help)" ;;
    *) [[ -z $src ]] || ql_die "one backup directory only"; src=$1 ;;
  esac
  shift
done
[[ -n $src ]] || ql_die "usage: scripts/restore.sh <backup-dir> [--with-library] [--yes]"
src=$(cd -- "$src" && pwd -P) || ql_die "no such directory: $src"
ql_require_rootless
ql_lock "$APP"
app_require_installed
ql_env_load "$ENV_FILE"
postgres_dir=$(app_dir HOST_POSTGRES_DIR)
library_dir=$(app_dir HOST_LIBRARY_DIR)

[[ -f $src/SHA256SUMS ]] || ql_die "$src/SHA256SUMS is missing: not a scripts/backup.sh backup"
(cd -- "$src" && sha256sum -c --quiet SHA256SUMS) || ql_die "checksum mismatch in $src"
dump=$src/immich-db.sql.gz
[[ -f $dump ]] || ql_die "$dump is missing"
((!with_library)) || [[ -f $src/library.tgz ]] || ql_die "--with-library: $src/library.tgz is missing"
app_confirm "restore replaces the Immich database${with_library:+ and the library} with $src"

ts=$(date +%Y%m%d-%H%M%S)
mapfile -t units < <(app_units)
ql_info "stopping $TARGET"
systemctl --user stop "${units[@]}"

for f in "$src"/secrets/*; do
  [[ -f $f ]] || continue
  ql_secret_ensure "${f##*/}" "file:$f" --update
done

ql_info "moving $postgres_dir aside (kept as $postgres_dir.pre-restore-$ts)"
podman unshare mv -- "$postgres_dir" "$postgres_dir.pre-restore-$ts" || ql_die "cannot move $postgres_dir"
app_ensure_dir "$postgres_dir"

ql_info "starting $DB_CONTAINER on an empty data directory"
systemctl --user start immich-postgres.service
QL_HEALTH_ACTIVE=1 ql_wait_container_healthy "$DB_CONTAINER" 300 || ql_die "$DB_CONTAINER did not become healthy"
app_restore_db "$dump"

if ((with_library)); then
  ql_info "replacing $library_dir from library.tgz (kept as $library_dir.pre-restore-$ts)"
  podman unshare mv -- "$library_dir" "$library_dir.pre-restore-$ts" || ql_die "cannot move $library_dir"
  app_ensure_dir "$library_dir"
  # --strip-components=1: the archive's top-level directory is the library directory as it
  # was named on the source host, which need not be its name here.
  podman unshare tar --numeric-owner -xzf "$src/library.tgz" -C "$library_dir" --strip-components=1 \
    || ql_die "cannot extract library.tgz"
fi

systemctl --user start "${units[@]}"
"$REPO/tests/smoke.sh" --timeout 900 || ql_die "restored, but the smoke test failed; see: journalctl --user -u immich-server.service -n 100"
ql_info "restore of $src complete"
ql_info "the previous data is still on disk; remove it when you are satisfied:"
ql_info "  podman unshare rm -rf $postgres_dir.pre-restore-$ts"
((!with_library)) || ql_info "  rm -rf $library_dir.pre-restore-$ts"
