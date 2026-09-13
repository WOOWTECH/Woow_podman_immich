#!/usr/bin/env bash
# tests/smoke.sh: post-install health checks for the Immich stack. Read-only; exit 0 = healthy.
#
#   tests/smoke.sh [--timeout S] [--public-url URL]
#
#   --timeout S       seconds to wait for the healthchecks and HTTP (default 300; upgrades
#                     run DB migrations on the first start, so upgrade.sh passes 900)
#   --public-url URL  also GET <URL>/api/server/ping through the tunnel / proxy
#
# Checks: the units are active, every container is healthy, /api/server/ping answers, the
# reported version equals the installed unit, the vector extensions are present, the port
# listens only on HOST_BIND, and the containers belong to the Quadlet units.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/app.sh
. "$REPO/scripts/app.sh"
export QL_LOG_PREFIX=smoke QL_HEALTH_ACTIVE=1

timeout=300 public_url=''
while (($#)); do
  case $1 in
    --timeout) timeout=${2:?--timeout needs seconds}; shift ;;
    --public-url) public_url=${2:?--public-url needs a URL}; shift ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_env_load "$ENV_FILE"

fails=0
ok() { ql_info "ok   $*"; }
bad() { ql_warn "FAIL $*"; fails=$((fails + 1)); }
check() {
  local desc=$1
  shift
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}

# 1. units
mapfile -t units < <(app_units)
for u in "${units[@]}"; do check "$u is active" systemctl --user is-active --quiet "$u"; done

# 2. podman healthchecks
mapfile -t containers < <(app_containers)
for c in "${containers[@]}"; do check "${c%%:*} is healthy" ql_wait_container_healthy "${c%%:*}" "$timeout"; done

# 3. the API answers on the published port
base=$(app_base_url)
check "GET $base/api/server/ping" ql_wait_http "$base/api/server/ping" 200 "$timeout"
pong=$(curl -fsS -m 10 "$base/api/server/ping" 2>/dev/null || true)
if [[ $pong == *'"res":"pong"'* ]]; then ok "server answers pong"; else bad "unexpected /api/server/ping body: ${pong:-<empty>}"; fi

# 4. the reported version equals the installed unit
want=$(app_tag "$(app_installed_image immich-server.container)")
have=$(app_api_version)
if [[ v$have == "$want" || $have == "$want" ]]; then ok "server version $have = installed unit $want"; else bad "server version '${have:-?}' != installed unit $want"; fi
if app_ml_enabled; then
  img=$(podman inspect --format '{{.ImageName}}' "$ML_CONTAINER" 2>/dev/null || true)
  want=$(app_installed_image immich-machine-learning.container)
  if [[ $img == "$want" ]]; then ok "machine learning image $img = installed unit"; else bad "machine learning image '${img:-?}' != installed unit $want"; fi
fi

# 5. the database has the vector extensions Immich needs
exts=$(podman exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
  "select extname || ' ' || extversion from pg_extension order by 1" 2>/dev/null || true)
for e in vchord vector; do
  if grep -q "^$e " <<<"$exts"; then ok "extension $e: $(grep "^$e " <<<"$exts")"; else bad "extension $e is missing from the immich database"; fi
done

# 6. the containers are the ones these units created
for c in "${containers[@]}"; do
  label=$(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "${c%%:*}" 2>/dev/null || true)
  if [[ $label == "${c#*:}" ]]; then ok "${c%%:*} belongs to ${c#*:}"; else bad "${c%%:*} has PODMAN_SYSTEMD_UNIT='${label:-none}', expected ${c#*:}"; fi
done

# 7. the published port listens only where HOST_BIND says
port=$(ql_env_get HOST_PORT) bind=$(ql_env_get HOST_BIND)
expected_listener() {
  case $1 in
    "$bind:$port") return 0 ;;
    "0.0.0.0:$port" | "*:$port") [[ $bind == 0.0.0.0 ]] ;;
    *) return 1 ;;
  esac
}
if command -v ss >/dev/null 2>&1; then
  mapfile -t listeners < <(ss -ltnH "sport = :$port" | awk '{print $4}' | sort -u)
  unexpected=0
  for l in "${listeners[@]}"; do expected_listener "$l" || unexpected=1; done
  if ((${#listeners[@]} && !unexpected)); then
    ok "port $port listens on ${listeners[*]}"
  else
    bad "port $port listeners '${listeners[*]}' do not match HOST_BIND=$bind"
  fi
else
  ql_info "note: ss not found; listener check skipped"
fi

# 8. through the tunnel / proxy
if [[ -n $public_url ]]; then
  check "GET ${public_url%/}/api/server/ping" ql_wait_http "${public_url%/}/api/server/ping" 200 120
fi

if ((fails)); then
  ql_warn "$fails check(s) failed"
  exit 1
fi
ql_info "all checks passed"
