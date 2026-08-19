#!/usr/bin/env bash
# PHANTOM STANDBY: what happens when PoA² promotes an address with no node
# behind it?
#
# Why it matters: a signer that never seals still counts toward len(signers),
# which raises Clique's recent-signer bar (limit = len/2 + 1). Enough phantoms
# and the controller meant to heal the chain halts it instead — and it would do
# so automatically, at 3am, from a stale address list.
#
# The fix under test (poa2.js v4): a promoted standby must PROVE it seals
# within VERIFY_BLOCKS. If it does not, it is rolled back, remembered, and the
# next candidate is tried — and the failed validator is never removed until a
# working replacement is in place.
#
# Method: inject a phantom address at the FRONT of the pool so it is picked
# first, kill a validator, and watch. The pool edit is reverted at exit.
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

PHANTOM=0x00000000000000000000000000000000deadbe01
VICTIM=1
VADDR=f39fd6e51aad88f6f4ce6ab8827279cfffb92266
POOLFILE=scripts/poa2.js

ipc(){ timeout 25 docker exec "rehearsal-node$1" geth attach --exec "$2" /data/geth.ipc 2>/dev/null | tr -d '\r'; }
head_of(){ ipc "${1:-2}" 'eth.blockNumber' | grep -oE '^[0-9]+$' | head -1; }
signers(){ ipc "${1:-2}" 'JSON.stringify(clique.getSigners())'; }
count(){ ipc "${1:-2}" 'clique.getSigners().length' | grep -oE '^[0-9]+$' | head -1; }
ctl(){ local s="$1" pat="$2" n=0 v; for v in 1 2 3 4 5 6; do
    docker ps --format '{{.Names}}' | grep -q "rehearsal-poa2-node$v" || continue
    n=$(( n + $(docker logs --since "$s" "rehearsal-poa2-node$v" 2>&1 | grep -c "$pat" || true) )); done; echo "$n"; }

cleanup(){
  echo "  [cleanup] restoring pool and victim"
  cp "$POOLFILE.bak" "$POOLFILE" 2>/dev/null && rm -f "$POOLFILE.bak"
  docker start "rehearsal-node$VICTIM" "rehearsal-automine-node$VICTIM" >/dev/null 2>&1
  [ -n "${LOAD:-}" ] && docker rm -f "$LOAD" >/dev/null 2>&1
  # controllers must go back to the clean pool
  for v in 1 2 3 4 5 6; do docker restart "rehearsal-poa2-node$v" >/dev/null 2>&1; done
}
trap cleanup EXIT

echo "=== inject phantom at the front of the standby pool ==="
cp "$POOLFILE" "$POOLFILE.bak"
python - "$POOLFILE" "$PHANTOM" <<'PY'
import io,sys
p,ph = sys.argv[1], sys.argv[2]
s = io.open(p, encoding='utf-8').read()
anchor = 'var POOL = [\n'
assert anchor in s, "pool anchor not found"
s = s.replace(anchor, anchor + '        "%s",   // TEST-ONLY phantom: no node behind it\n' % ph.lower(), 1)
io.open(p,'w',encoding='utf-8',newline='\n').write(s)
print("  phantom injected")
PY
for v in 1 2 3 4 5 6; do docker restart "rehearsal-poa2-node$v" >/dev/null 2>&1; done
sleep 12

echo "=== preconditions ==="
docker ps --format '{{.Names}}' | grep -q 'rehearsal-loadgen' || {
  LOAD=$(docker compose run -d --rm loadgen steady http://node5:8545 8 1200 phantom 0); sleep 20; }
S0=$(signers); echo "  signers: $S0"
printf '%s' "$S0" | grep -qi "$VADDR" || { echo "ABORT: node$VICTIM is not a signer"; exit 1; }
H0=$(head_of); sleep 8; H1=$(head_of)
[ -n "$H1" ] && [ "$H1" -gt "${H0:-0}" ] || { echo "ABORT: chain not sealing ($H0 -> $H1)"; exit 1; }
echo "  chain sealing ($H0 -> $H1)"

echo
echo "=== fault: stop validator node$VICTIM; PoA² will pick the phantom first ==="
T=$(date -u +%FT%TZ); sleep 1
docker stop "rehearsal-node$VICTIM" "rehearsal-automine-node$VICTIM" >/dev/null 2>&1
T0=$(date +%s)

PH_IN=0; PH_OUT=0; REAL_IN=0; MAXSET=0
for i in $(seq 1 130); do
  S=$(signers); C=$(count); [ -n "$C" ] && [ "$C" -gt "$MAXSET" ] && MAXSET=$C
  if [ "$PH_IN" -eq 0 ] && printf '%s' "$S" | grep -qi 'deadbe01'; then
    PH_IN=1; echo "  [$(( $(date +%s) - T0 ))s] phantom ADDED to the signer set (size $C)"
  fi
  if [ "$PH_IN" -eq 1 ] && [ "$PH_OUT" -eq 0 ] && ! printf '%s' "$S" | grep -qi 'deadbe01'; then
    PH_OUT=1; echo "  [$(( $(date +%s) - T0 ))s] phantom ROLLED BACK (size $C)"
  fi
  # a real standby taking over = recovery complete
  if [ "$REAL_IN" -eq 0 ] && [ "${C:-0}" -eq 4 ] && ! printf '%s' "$S" | grep -qi "$VADDR" && ! printf '%s' "$S" | grep -qi 'deadbe01'; then
    REAL_IN=1; echo "  [$(( $(date +%s) - T0 ))s] real standby took over; set healthy at 4"
    break
  fi
  sleep 4
done

DET=$(ctl "$T" 'PHANTOM STANDBY')
echo
echo "===== RESULT ====="
echo "  phantom promoted            : $([ $PH_IN  -eq 1 ] && echo YES || echo no)"
echo "  phantom detected+rolled back: $([ $PH_OUT -eq 1 ] && echo YES || echo NO)   (controllers logging it: $DET)"
echo "  real standby took over      : $([ $REAL_IN -eq 1 ] && echo YES || echo NO)"
echo "  largest signer-set size seen: $MAXSET"
echo "  final signers ($(count)): $(signers)"
echo "  head: $(head_of) — advancing means the phantom never halted the chain"
RC=1
if [ "$PH_IN" -eq 1 ] && [ "$PH_OUT" -eq 1 ] && [ "$REAL_IN" -eq 1 ]; then
  echo "  VERDICT: PASS — phantom was promoted, caught, rolled back, and a working"
  echo "           standby took over. The halt hazard is self-correcting."
  RC=0
elif [ "$PH_IN" -eq 1 ] && [ "$PH_OUT" -eq 0 ]; then
  echo "  VERDICT: FAIL — the phantom REMAINED in the signer set. It raises the"
  echo "           recent-signer bar and erodes liveness margin permanently."
else
  echo "  VERDICT: INCONCLUSIVE — the phantom was never promoted, so the guard"
  echo "           was not exercised (pool ordering or timing)."
fi
exit $RC
