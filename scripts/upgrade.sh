#!/usr/bin/env bash
# scripts/upgrade.sh: move the installed Immich stack to the versions pinned in this
# checkout. The repo is the source of truth: an upgrade is `git pull` (a commit that bumps
# Image=), then this script.
#
#   scripts/upgrade.sh [--allow-major] [--yes]
#
# backup -> pull -> restart -> smoke -> automatic rollback:
#  1. gates (before anything stops): immich-server and immich-machine-learning carry the
#     same version; no downgrade; a major bump (v2 -> v3) needs --allow-major; the
#     PostgreSQL major version must not change (that is a dump/restore job, see README)
#  2. pulls every pinned image; a failed pull changes nothing
#  3. scripts/backup.sh --cold into ~/backups/immich/upgrade-<timestamp>/: the dump, the
#     installed units and a byte copy of the database directory, which is what makes the
#     rollback exact (Immich's migrations are forward-only)
#  4. scripts/install.sh installs the new units and restarts what changed; tests/smoke.sh
#     waits up to 900 s because the server migrates the database on the first start
#  5. on failure: stop, put the previous units and database directory back, start, smoke,
#     exit 1
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"

allow_major=0 ASSUME_YES=0
while (($#)); do
  case $1 in
    --allow-major) allow_major=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h | --help) sed -n '2,21p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_preflight "$PODMAN_MIN"
ql_lock "$APP"
app_require_installed
ql_env_load "$ENV_FILE"
app_validate_env
postgres_dir=$(app_dir HOST_POSTGRES_DIR)

# ---- 1. gates -------------------------------------------------------------------------------
[[ $(app_tag "$ML_IMAGE") == "$IMMICH_VERSION" ]] \
  || ql_die "the pins disagree: $SERVER_IMAGE vs $ML_IMAGE (Immich requires matching versions)"
tgt=${IMMICH_VERSION#v}
cur=$(app_api_version)
if [[ -z $cur ]]; then
  cur=$(app_tag "$(sed -n 's/^Image=//p' "$QDIR/immich-server.container" 2>/dev/null)")
  cur=${cur#v}
  ql_warn "the server does not answer; comparing with the installed unit (${cur:-unknown})"
fi
[[ $cur =~ ^[0-9]+(\.[0-9]+)*$ ]] || ql_die "cannot determine the running Immich version ('$cur')"
version_change=0
if [[ $cur != "$tgt" ]]; then
  [[ $(printf '%s\n%s\n' "$cur" "$tgt" | sort -V | head -n1) == "$cur" ]] \
    || ql_die "downgrade $cur -> $tgt is not supported (Immich migrations are forward-only); restore a backup instead"
  if ((10#${tgt%%.*} > 10#${cur%%.*} && !allow_major)); then
    ql_die "major upgrade $cur -> $tgt: read https://github.com/immich-app/immich/releases first, then re-run with --allow-major"
  fi
  version_change=1
fi
if [[ $version_change == 1 ]]; then
  app_confirm "upgrade Immich $cur -> $tgt (a cold backup is taken first; failure rolls back automatically)"
else
  ql_info "Immich is already at $tgt; applying unit changes only"
fi

# ---- 2. pull before anything stops --------------------------------------------------------------
for i in "$SERVER_IMAGE" "$ML_IMAGE" "$REDIS_IMAGE" "$PG_IMAGE"; do
  podman image exists "$i" || { ql_info "pulling $i"; podman pull "$i" >/dev/null; } || ql_die "podman pull $i failed; nothing was changed"
done
pg_cur=$(app_pg_major_running)
pg_tgt=$(app_pg_major_image "$PG_IMAGE")
if [[ -n $pg_cur && -n $pg_tgt && $pg_cur != "$pg_tgt" ]]; then
  ql_die "the database image moves from PostgreSQL $pg_cur to $pg_tgt; that needs a dump and restore (README: PostgreSQL major upgrade)"
fi

# ---- 3. cold backup -------------------------------------------------------------------------------
bk=$("$REPO/scripts/backup.sh" --cold --no-library --dest "$BACKUP_ROOT/upgrade-$(date +%Y%m%d-%H%M%S)" | tail -n1)
[[ -f $bk/immich-db.sql.gz && -f $bk/postgres-dir.tgz && -d $bk/units ]] \
  || ql_die "the pre-upgrade backup is incomplete ($bk); nothing was changed"

# ---- 4. install + restart + smoke ------------------------------------------------------------------
if ! "$REPO/scripts/install.sh" --no-start --no-smoke; then
  ql_warn "install.sh failed before anything restarted; putting the previous units back"
  ql_install_files "$bk/units" "$APP" --prune >/dev/null
  systemctl --user daemon-reload
  ql_die "upgrade aborted; the stack still runs $cur (backup: $bk)"
fi
if "$REPO/scripts/install.sh" --smoke-timeout 900; then
  ql_info "upgrade to $tgt complete (pre-upgrade backup: $bk)"
  exit 0
fi

# ---- 5. automatic rollback ---------------------------------------------------------------------
# rollback_incomplete: say so if this script ends before the rollback below finishes.
# A hook, not `trap ... EXIT`: a bare trap would replace the handler ql_lock armed and
# leave the lock directory behind, so every later run would report a takeover.
# shellcheck disable=SC2317,SC2329 # invoked indirectly, as the ql_cleanup hook registered below
rollback_incomplete() {
  local rc=$?
  ((rc == 0)) || ql_warn "ROLLBACK INCOMPLETE (rc=$rc). Backup: $bk. Restore by hand: scripts/restore.sh $bk"
}
ql_cleanup rollback rollback_incomplete
ql_warn "upgrade to $tgt failed; rolling back to $cur"
ts=$(date +%Y%m%d-%H%M%S)
mapfile -t units < <(app_units)
systemctl --user stop "${units[@]}" || true
ql_install_files "$bk/units" "$APP" --prune >/dev/null
if ((version_change)); then
  ql_info "putting the pre-upgrade database directory back (the new version migrated it)"
  podman unshare mv -- "$postgres_dir" "$postgres_dir.failed-$tgt-$ts" || ql_die "cannot move $postgres_dir aside"
  app_ensure_dir "$postgres_dir"
  podman unshare tar --numeric-owner -xzf "$bk/postgres-dir.tgz" -C "$postgres_dir" --strip-components=1 \
    || ql_die "cannot restore the database directory from $bk/postgres-dir.tgz"
fi
ql_apply_units "$APP" "${units[@]}"
app_env_record
"$REPO/tests/smoke.sh" --timeout 900 || ql_die "the rolled-back stack failed its smoke test"
ql_cleanup_clear rollback
ql_warn "rolled back to $cur; the upgrade to $tgt did not pass (backup: $bk)"
((!version_change)) || ql_warn "the failed attempt's data is kept in $postgres_dir.failed-$tgt-$ts; remove it with: podman unshare rm -rf $postgres_dir.failed-$tgt-$ts"
exit 1
