#!/usr/bin/env bash
# Master smoke-test runner. Runs the full suite against the patched geth, and the
# A/B (stock vs patched) upgrade scenarios against both binaries, then prints a
# single PASS/FAIL summary and exits non-zero if anything failed.
#
# Intended to run inside the Linux test container (see smoke-test/Dockerfile),
# but works anywhere bash + curl (+ node for the ethers test) are available.
#
# An optional third argument, a PREVIOUS build of this fork, additionally runs the
# release-upgrade scenarios (previous fork build -> this build). Those answer a
# different question from the stock->patched ones: not "can a Clique chain adopt
# Cancun" but "can operators move between two releases of this fork without
# losing block continuity". Omit it and those two scenarios are skipped.
#
# Usage: run-all.sh <geth-original> <geth-patched> [geth-previous]
set -u

ORIG="${1:?usage: run-all.sh <geth-original> <geth-patched> [geth-previous]}"
PATCHED="${2:?usage: run-all.sh <geth-original> <geth-patched> [geth-previous]}"
PREV="${3:-}"
DIR="$(cd "$(dirname "$0")" && pwd)"

RESULTS=()

verdict() {  # $1=output  $2=exit-code  -> echoes PASS or FAIL
  local out="$1" rc="$2" failed
  # Authoritative: a "<N> failed" summary line printed by the script (last wins).
  failed=$(printf '%s\n' "$out" | grep -oE '[0-9]+ failed' | tail -1 | grep -oE '^[0-9]+')
  if [ -n "$failed" ]; then
    [ "$failed" -eq 0 ] && echo PASS || echo FAIL
    return
  fi
  # No summary line (e.g. transition.sh): trust the exit code.
  [ "$rc" -ne 0 ] && { echo FAIL; return; }
  # Last resort: a raw crash marker (only reached for scripts with no summary).
  printf '%s\n' "$out" | grep -qiE 'panic:|does not support|divide by zero' && { echo FAIL; return; }
  echo PASS
}

run() {  # $1=name  $2..=command
  local name="$1"; shift
  echo; echo "##################### $name #####################"
  local out rc v
  out="$("$@" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  v="$(verdict "$out" "$rc")"
  echo ">>> [$v] $name (exit $rc)"
  RESULTS+=("$v  $name")
}

echo "geth-original : $ORIG"
echo "geth-patched  : $PATCHED"
"$PATCHED" version 2>/dev/null | grep -iE 'Version|Git' | head -3

# ---- single-binary suite (patched) ----
run "run(patched)"     bash "$DIR/run.sh"            "$PATCHED" patched
run "freegas-rpc"      bash "$DIR/freegas-rpc.sh"    "$PATCHED"
run "metamask-compat"  bash "$DIR/metamask-compat.sh" "$PATCHED"
run "push0"            bash "$DIR/push0.sh"          "$PATCHED"
run "cancun-opcodes"   bash "$DIR/cancun-opcodes.sh" "$PATCHED"
run "blob-surface"     bash "$DIR/blob-surface.sh"   "$PATCHED"
run "fee-toggle"       bash "$DIR/fee-toggle.sh"     "$PATCHED"
run "ethers-compat"    bash "$DIR/ethers-compat.sh"  "$PATCHED"
run "transition"       bash "$DIR/transition.sh"     "$PATCHED"
run "multisig-transition" bash "$DIR/multisig-transition.sh" "$PATCHED"
run "snap-sync"        bash "$DIR/snap-sync.sh"      "$PATCHED"
run "out-of-turn"      bash "$DIR/out-of-turn.sh"    "$PATCHED" 250ms
run "commit-latency"   bash "$DIR/commit-latency.sh" "$PATCHED" 20 2s 500ms 250ms

# ---- A/B upgrade scenarios (stock -> patched) ----
run "transition-prod"  bash "$DIR/transition-prod.sh"  "$ORIG" "$PATCHED"
run "rollback"         bash "$DIR/rollback.sh"         "$ORIG" "$PATCHED"
run "upgrade-rigorous" bash "$DIR/upgrade-rigorous.sh" "$ORIG" "$PATCHED"

# ---- release-upgrade scenarios (previous fork build -> this build) ----
if [ -n "$PREV" ]; then
  run "inplace-upgrade" bash "$DIR/inplace-upgrade.sh" "$PREV" "$PATCHED"
  run "mixed-version"   bash "$DIR/mixed-version.sh"   "$PREV" "$PATCHED"
  run "rolling-upgrade" bash "$DIR/rolling-upgrade.sh" "$PREV" "$PATCHED" 4
else
  echo
  echo "##### skipping inplace-upgrade + mixed-version + rolling-upgrade (no previous build) #####"
  echo "      pass a previous build as \$3 to run them:"
  echo "      run-all.sh <geth-original> <geth-patched> <geth-previous>"
fi

echo; echo "########################## SUMMARY ##########################"
printf '%s\n' "${RESULTS[@]}"
NP=$(printf '%s\n' "${RESULTS[@]}" | grep -c '^PASS')
NF=$(printf '%s\n' "${RESULTS[@]}" | grep -c '^FAIL')
echo "-------------------------------------------------------------"
echo "$NP passed, $NF failed (of ${#RESULTS[@]} suites)"
[ "$NF" -eq 0 ]
