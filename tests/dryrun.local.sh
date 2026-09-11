# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # REPO, base, optional and failures belong to tests/dryrun.sh
# tests/dryrun.local.sh: Immich-specific checks, sourced at the end of tests/dryrun.sh.
#   1. immich-server and immich-machine-learning carry the same version: Immich only
#      supports matching versions, and upgrade.sh bumps them together.
#   2. The toypark1234 fixture also renders with the optional machine-learning units,
#      which is what that host installs.

v_srv=$(sed -n 's#^Image=ghcr.io/immich-app/immich-server:##p' "$REPO/quadlet/immich-server.container")
v_ml=$(sed -n 's#^Image=ghcr.io/immich-app/immich-machine-learning:##p' "$REPO/quadlet/optional/immich-machine-learning.container")
if [[ -n $v_srv && $v_srv == "$v_ml" ]]; then
  echo "ok   version lockstep: immich-server $v_srv = immich-machine-learning $v_ml"
else
  echo "FAIL version lockstep: immich-server ($v_srv) != immich-machine-learning ($v_ml)"
  failures=$((failures + 1))
fi

run_variant fixture-toypark1234+optional "$REPO/tests/fixtures/toypark1234.env" "${base[@]}" "${optional[@]}"
