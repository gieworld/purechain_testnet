#!/usr/bin/env bash
# STANDBY POOL EXHAUSTION: a validator dies and there is nothing to promote.
#
# The naive response is to log and do nothing, leaving the dead signer in the
# set. That is the WORSE state: Clique needs floor(n/2)+1 signers to seal, so
# 4 signers with one dead needs 3 of the 3 survivors — zero margin, and the
# next failure halts the chain. Removing the dead signer drops the requirement
# to 2 of 3, restoring a spare.
#
# So on exhaustion PoA² should SHRINK the set rather than stall — but never
# below MIN_SIZE, where shrinking would reverse the benefit.
#
# Method: temporarily reduce the pool to exactly the current signers (no
# standbys), kill one validator, and watch. Pool is restored at exit.
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

POOLFILE=scripts/poa2.js
ipc(){ timeout 25 docker exec "rehearsal-node$1" geth attach --exec "$2" /data/geth.ipc 2>/dev/null | tr -d '\r'; }
head_of(){ ipc "${1:-2}" 'eth.blockNumber' | grep -oE '^[0-9]+$' | head -1; }
signers(){ ipc "${1:-2}" 'JSON.stringify(clique.getSigners())'; }
count(){ ipc "${1:-2}" 'clique.getSigners().length' | grep -oE '^[0-9]+$' | head -1; }
ctl(){ local s="$1" pat="$2" n=0 v; for v in 1 2 3 4 5 6; do
    docker ps --format '{{.Names}}' | grep -q "rehearsal-poa2-node$v" || continue
    n=$(( n + $(docker logs --since "$s" "rehearsal-poa2-node$v" 2>&1 | grep -c "$pat" || true) )); done; echo "$n"; }

PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

cleanup(){
  echo "  [cleanup] restoring pool, victim and controllers"
  [ -f "$POOLFILE.bak" ] && cp "$POOLFILE.bak" "$POOLFILE" && rm -f "$POOLFILE.bak"
  docker start rehearsal-node3 rehearsal-automine-node3 rehearsal-node4 rehearsal-automine-node4 >/dev/null 2>&1
  [ -n "${LOAD:-}" ] && docker rm -f "$LOAD" >/dev/null 2>&1
  for v in 1 2 3 4 5 6; do docker restart "rehearsal-poa2-node$v" >/dev/null 2>&1; done
}
trap cleanup EXIT

echo "=== setup ==="
docker ps --format '{{.Names}}' | grep -E 'poa2|loadgen' | xargs -r docker rm -f >/dev/null 2>&1
LOAD=$(docker compose run -d --rm loadgen steady http://node5:8545 8 1500 exhaust 0)
sleep 18
SIG0=$(signers); N0=$(count)
echo "  signers ($N0): $SIG0"
[ "${N0:-0}" -eq 4 ] || { echo "ABORT: expected 4 signers, got ${N0:-?}"; exit 1; }

# Reduce the pool to exactly the current signers -> no standby can be picked.
echo "=== shrinking the pool to the current signers (no standbys available) ==="
cp "$POOLFILE" "$POOLFILE.bak"
python - "$POOLFILE" "$SIG0" <<'PY'
import io,sys,re,json
p, sig = sys.argv[1], sys.argv[2]
addrs = re.findall(r'0x[0-9a-fA-F]{40}', sig)
assert len(addrs) == 4, addrs
s = io.open(p, encoding='utf-8').read()
new = "var POOL = [\n" + "".join('        "%s",\n' % a.lower() for a in addrs).rstrip(",\n") + "\n];"
s = re.sub(r'var POOL = \[.*?\];', new, s, count=1, flags=re.S)
io.open(p,'w',encoding='utf-8',newline='\n').write(s)
print("  pool now: %s" % ", ".join(a[:10] for a in addrs))
PY
for v in 1 2 3 4 5 6; do docker compose up -d --no-deps "poa2-node$v" >/dev/null 2>&1; done
sleep 20
H0=$(head_of); sleep 8; H1=$(head_of)
[ -n "$H1" ] && [ "$H1" -gt "${H0:-0}" ] || { echo "ABORT: chain not sealing"; exit 1; }
echo "  chain sealing ($H0 -> $H1)"

# pick a victim that is currently a signer
if printf '%s' "$SIG0" | grep -qi '3c44cddd'; then VIC=3; VADDR=3c44cdddb6a900fa2b585dd299e03d12fa4293bc
elif printf '%s' "$SIG0" | grep -qi '90f79bf6'; then VIC=4; VADDR=90f79bf6eb2c4f870365e785982e1f101e93b906
else echo "ABORT: no usable victim"; exit 1; fi

echo
echo "=== killing validator node$VIC with an empty standby pool ==="
T=$(date -u +%FT%TZ); sleep 1
docker stop "rehearsal-node$VIC" "rehearsal-automine-node$VIC" >/dev/null 2>&1
T0=$(date +%s); SHRUNK=0
for i in $(seq 1 90); do
  S=$(signers); C=$(count)
  if [ -n "$S" ] && ! printf '%s' "$S" | grep -qi "$VADDR"; then
    SHRUNK=1; echo "  [$(( $(date +%s) - T0 ))s] dead signer REMOVED without replacement; set now $C"; break
  fi
  sleep 4
done
EXH=$(ctl "$T" 'EXHAUSTED')
NOW=$(count)

echo
echo "===== RESULT ====="
echo "  'pool EXHAUSTED' logged by : $EXH controller(s)"
echo "  dead signer removed        : $([ $SHRUNK -eq 1 ] && echo YES || echo NO)"
echo "  signer set size            : $N0 -> ${NOW:-?}"
echo "  signers: $(signers)"
echo "  head: $(head_of) (advancing = chain healthy on the smaller set)"
[ "${EXH:-0}" -gt 0 ] && ok "exhaustion was detected and reported" || no "exhaustion never reported"
if [ "$SHRUNK" -eq 1 ] && [ "${NOW:-0}" -eq 3 ]; then
  ok "set shrank 4 -> 3: sealer requirement drops 3-of-3 to 2-of-3, restoring margin"
else
  no "dead signer was left in the set (still ${NOW:-?}) — zero liveness margin"
fi
# the chain must still be alive on 3 signers
HA=$(head_of); sleep 12; HB=$(head_of)
[ -n "$HB" ] && [ "$HB" -gt "${HA:-0}" ] && ok "chain still sealing on the reduced set ($HA -> $HB)" \
                                          || no "chain stalled after the shrink ($HA -> $HB)"

echo
echo "############ RESULT: $PASS passed, $FAIL failed ############"
[ "$FAIL" -eq 0 ]
