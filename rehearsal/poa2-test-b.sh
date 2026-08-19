#!/usr/bin/env bash
# TEST B, done properly: a HEALTHY validator that has stopped sealing.
#
# Two earlier attempts were vacuous. The second failed because killing the
# sealing sidecar does NOT stop the miner — geth keeps sealing with whatever
# state it was left in, so the validator never looked idle. The dangerous
# real-world case is narrower: the sidecar dies while the miner is STOPPED
# (during an idle period), so when load returns that node never resumes
# sealing. It is healthy, synced, serving RPC — and invisible as a sealer.
#
# This reproduces exactly that: stop the sidecar AND stop the miner, leave the
# node up, and see what PoA² decides.
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

ipc(){ timeout 25 docker exec "rehearsal-node$1" geth attach --exec "$2" /data/geth.ipc 2>/dev/null | tr -d '\r'; }
head_of(){ ipc "${1:-1}" 'eth.blockNumber' | grep -oE '^[0-9]+$' | head -1; }
signers(){ ipc "${1:-1}" 'JSON.stringify(clique.getSigners())'; }
count(){ ipc "${1:-1}" 'clique.getSigners().length' | grep -oE '^[0-9]+$' | head -1; }
ctl(){ local s="$1" pat="$2" n=0 v; for v in 1 2 3 4 5 6; do
    docker ps --format '{{.Names}}' | grep -q "rehearsal-poa2-node$v" || continue
    n=$(( n + $(docker logs --since "$s" "rehearsal-poa2-node$v" 2>&1 | grep -c "$pat" || true) )); done; echo "$n"; }

VICTIM=4                                              # node4, currently a signer
VADDR=90f79bf6eb2c4f870365e785982e1f101e93b906

echo "=== preconditions ==="
docker ps --format '{{.Names}}' | grep -q 'rehearsal-loadgen' || {
  LOAD=$(docker compose run -d --rm loadgen steady http://node5:8545 8 900 test-b 0)
  echo "  started load ${LOAD:0:12}"; trap 'docker rm -f "$LOAD" >/dev/null 2>&1 || true' EXIT; sleep 20; }
S0=$(signers); echo "  signers: $S0"
printf '%s' "$S0" | grep -qi "$VADDR" || { echo "ABORT: node$VICTIM is not currently a signer"; exit 1; }
H0=$(head_of 1); sleep 8; H1=$(head_of 1)
[ -n "$H1" ] && [ "$H1" -gt "${H0:-0}" ] || { echo "ABORT: chain not sealing ($H0 -> $H1)"; exit 1; }
echo "  chain sealing ($H0 -> $H1)"
echo -n "  node$VICTIM mining before: "; ipc $VICTIM 'eth.mining'

echo
echo "=== fault: sidecar dies AND miner is left stopped (node stays healthy) ==="
T=$(date -u +%FT%TZ); sleep 1
docker stop "rehearsal-automine-node$VICTIM" >/dev/null 2>&1
ipc $VICTIM 'miner.stop()' >/dev/null 2>&1
sleep 3
echo -n "  node$VICTIM mining now: "; ipc $VICTIM 'eth.mining'
echo -n "  node$VICTIM head (proves it is alive and syncing): "; head_of $VICTIM

echo
echo "=== watching PoA² for up to 6 min ==="
T0=$(date +%s); EVICTED=0
for i in $(seq 1 90); do
  S=$(signers)
  if [ -n "$S" ] && ! printf '%s' "$S" | grep -qi "$VADDR"; then
    EVICTED=1; echo "  [$(( $(date +%s) - T0 ))s] node$VICTIM EVICTED from the signer set"; break
  fi
  sleep 4
done
SEEN=$(ctl "$T" 'is not mining'); ACTED=$(ctl "$T" 'confirmed dead')

echo
echo "===== RESULT ====="
echo "  controller noticed it stopped sealing : $SEEN"
echo "  controller acted (confirmed dead)     : $ACTED"
echo "  node still alive?  head=$(head_of $VICTIM)   mining=$(ipc $VICTIM 'eth.mining')"
echo "  signers ($(count)): $(signers)"
if [ "${SEEN:-0}" -eq 0 ]; then
  echo "  VERDICT: INCONCLUSIVE — controller never noticed; test did not create the condition"
  RC=1
elif [ "$EVICTED" -eq 1 ]; then
  echo "  VERDICT: PoA² REPLACES a healthy-but-not-sealing validator."
  echo "           Liveness is preserved, but a standby is consumed for a fault"
  echo "           that a sidecar restart would have fixed. Operators must watch"
  echo "           for sidecar death directly, not rely on PoA² to be gentle."
  RC=0
else
  echo "  VERDICT: PoA² noticed but did NOT replace it within the window."
  RC=0
fi
echo "  restoring node$VICTIM"
docker start "rehearsal-automine-node$VICTIM" >/dev/null 2>&1
exit $RC
