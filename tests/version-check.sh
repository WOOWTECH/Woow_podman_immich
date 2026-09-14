#!/usr/bin/env bash
# tests/version-check.sh: pins app_legacy_version_check (scripts/app.sh), the pre-flight
# check scripts/migrate-legacy.sh runs before a cutover. It exists because a literal string
# compare of the legacy .env's IMMICH_VERSION against this checkout's pinned tag false-fails
# on a floating legacy tag (docker-compose's IMMICH_VERSION=v2): "2" != "2.7.5" even when the
# image v2 currently resolves to IS 2.7.5. Confirmed live on woowtechopenclaw: the legacy
# .env said v2, the running container's own /api/server/version answered
# {"major":2,"minor":7,"patch":5}, and the checkout pins v2.7.5 - a real match the old check
# rejected. The fix asks the legacy server's own API what it is actually running, and falls
# back to the .env string only when that API cannot be reached.
#
# curl is the double in tests/shims (see tests/shims/curl for its protocol); podman and
# systemctl are shimmed too because scripts/app.sh sources scripts/lib/quadlet-lib.sh, but
# this file's tests never touch containers or units.
#
#   tests/version-check.sh [name-filter]
# shellcheck disable=SC2030,SC2031
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
SHIMS=$HERE/shims
FILTER=${1:-}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/immich-version-check-tests.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
npass=0 nfail=0
FAILED=()

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
eq() { [[ $1 == "$2" ]] || die_t "${3:-value}: expected [$2] got [$1]"; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in:"$'\n'"$1"; }
OUT=''
expect_ok() { OUT=$( ("$@") 2>&1) || die_t "expected success of: $*"$'\n'"$OUT"; }
expect_fail() { if OUT=$( ("$@") 2>&1); then die_t "expected failure of: $*"$'\n'"$OUT"; fi; }

BASE=http://127.0.0.1:2283
key() { local u=$1; printf '%s' "${u//[\/:]/_}"; }

# api_answers <major> <minor> <patch>: the legacy server's own /api/server/version reports this
api_answers() {
  mkdir -p "$SHIM_STATE/curl_body"
  printf '{"major":%s,"minor":%s,"patch":%s}' "$1" "$2" "$3" >"$SHIM_STATE/curl_body/$(key "$BASE/api/server/version")"
}
# api_down: the legacy server's version endpoint does not answer (down, unreachable, timeout)
api_down() {
  mkdir -p "$SHIM_STATE/curl_fail"
  : >"$SHIM_STATE/curl_fail/$(key "$BASE/api/server/version")"
}

# ---- floating legacy tag, resolves to the SAME version as the pin: must proceed -----------
# This is the exact openclaw shape: .env says v2, the API reports 2.7.5, the checkout pins
# v2.7.5. The pre-fix literal compare ("2" != "2.7.5") rejects this; the fix must not.
t_floating_tag_matching_the_target_proceeds() {
  api_answers 2 7 5
  expect_ok app_legacy_version_check v2 "$BASE"
  has "$OUT" '"patch":5' "the raw API JSON is returned for the caller to log"
}

# ---- floating legacy tag, resolves to a DIFFERENT version than the pin: must still refuse --
# The invariant this check protects is "migrate at the same version, then upgrade" (see the
# script's own header comment) - not merely "no major jump". A floating tag that happens to
# have moved past (or short of) the pinned patch/minor is still a real version mismatch, so
# this must refuse exactly as it would for a pinned tag that disagreed.
t_floating_tag_on_a_different_resolved_version_still_refuses() {
  api_answers 2 8 0
  expect_fail app_legacy_version_check v2 "$BASE"
  has "$OUT" "running legacy Immich is 2.8.0"
  has "$OUT" "checkout pins v2.7.5"
}

# ---- pinned legacy tag, exact match: must proceed (unchanged behaviour) -------------------
t_pinned_tag_exact_match_proceeds() {
  api_answers 2 7 5
  expect_ok app_legacy_version_check v2.7.5 "$BASE"
}

# ---- pinned legacy tag that disagrees with the pin: must refuse (unchanged behaviour) ------
t_pinned_tag_mismatch_refuses() {
  api_answers 2 6 0
  expect_fail app_legacy_version_check v2.6.0 "$BASE"
  has "$OUT" "running legacy Immich is 2.6.0"
}

# ---- the API cannot be reached: falls back to the .env string, floating tag matching -------
t_api_unreachable_falls_back_to_matching_env_string() {
  api_down
  expect_ok app_legacy_version_check v2.7.5 "$BASE"
  has "$OUT" "falling back to the .env"
}

# ---- the API cannot be reached: falls back to the .env string, and still refuses a real
#      mismatch (the fallback is weaker, not absent) ----------------------------------------
t_api_unreachable_falls_back_and_still_refuses_a_mismatch() {
  api_down
  expect_fail app_legacy_version_check v2.6.0 "$BASE"
  has "$OUT" "legacy .env pins IMMICH_VERSION=v2.6.0"
}

run() {
  local t=$1 log rc
  [[ -z $FILTER || $t == *"$FILTER"* ]] || return 0
  log=$ROOT/$t.log
  (
    set -euo pipefail
    T=$ROOT/$t
    mkdir -p "$T/home" "$T/state" "$T/run"
    export HOME=$T/home SHIM_STATE=$T/state XDG_RUNTIME_DIR=$T/run USER=tester TMPDIR=$T
    export PATH="$SHIMS:$PATH" QL_LOG_PREFIX=version-check
    unset QL_DRY_RUN QL_STATE_ROOT QL_QUADLET_DIR QL_CONFIG_ROOT
    : >"$SHIM_STATE/calls"
    [[ $(command -v curl) == "$SHIMS/curl" ]] || die_t "the curl shim is not first on PATH; refusing to run"
    # shellcheck source=../scripts/lib/quadlet-lib.sh
    . "$REPO/scripts/lib/quadlet-lib.sh"
    # shellcheck source=../scripts/app.sh
    . "$REPO/scripts/app.sh"
    "$t"
  ) >"$log" 2>&1
  rc=$?
  if ((rc == 0)); then
    npass=$((npass + 1))
    printf 'ok    %s\n' "$t"
  else
    nfail=$((nfail + 1))
    FAILED+=("$t")
    printf 'FAIL  %s\n' "$t"
    tail -n 25 "$log" | sed 's/^/      | /'
  fi
}

for t in $(declare -F | sed -n 's/^declare -f \(t_.*\)$/\1/p'); do run "$t"; done
printf '\n%d passed, %d failed\n' "$npass" "$nfail"
((nfail == 0)) || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
