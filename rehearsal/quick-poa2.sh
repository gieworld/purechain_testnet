#!/usr/bin/env bash
# QUICK PoA² smoke test — the one question that matters, in a few minutes:
# does the controller detect a dead validator and heal the signer set?
#
# Shortcuts taken deliberately (the full p9 campaign covers what these skip):
#   * Validators are force-mined instead of driven by transaction load, so
#     blocks flow immediately and no tx-relay arming is needed.
#   * Only the genuine-fault path is exercised. False positives, repeat faults,
#     the dead-sidecar case and the phantom-standby hazard stay in p9.
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

ipc(){ timeout 25 docker exec "rehearsal-node$1" geth attach --exec "$2" /data/geth.ipc 2>/dev/null | tr -d '\r'; }
head_of(){ ipc "$1" 'eth.blockNumber' | grep -oE '^[0-9]+$' | head -1; }
signers(){ ipc 1 'JSON.stringify(clique.getSigners())'; }
count(){ ipc 1 'clique.getSigners().length' | grep -oE '^[0-9]+$' | head -1; }
V3=3c44cdddb6a900fa2b585dd299e03d12fa4293bc          # node3, the victim
S5=9965507d1a55bcc2695c58ba16fb37d819b0a4dc          # standby on node5
S6=976ea74026e726554db657fa54763abd0c3a0aa9          # standby on node6

echo "=== 0. force-mine all validators so blocks flow without tx load ==="
for v in 1 2 3 4; do
  ipc "$v" 'try{miner.setEtherbase(eth.accounts[0])}catch(e){}; if(!eth.mining)miner.start()' >/dev/null
done
sleep 5
H0=$(head_of 1); echo "  head=$H0  signers=$(count)"
[ -z "$H0" ] && { echo "FAIL: node1 unreachable"; exit 1; }

echo "=== 1. warm the 64-block activity window (all four must appear) ==="
for i in $(seq 1 40); do
  H=$(head_of 1)
  [ -n "$H" ] && [ $((H - H0)) -ge 70 ] && break
  sleep 3
done
ACT=$(ipc 1 'JSON.stringify(clique.status().sealerActivity)')
echo "  activity: $ACT"
echo "$ACT" | grep -qE ':0[,}]' && echo "  WARN: a validator still reads 0 — window not fully warm"

echo "=== 2. start PoA² on every validator ==="
for v in 1 2 3 4; do docker compose up -d --no-deps "poa2-node$v" >/dev/null 2>&1; done
sleep 12
HB=$(docker logs rehearsal-poa2-node1 2>&1 | grep -c '^\.\.\.' || true)
echo "  controller heartbeats on node1: $HB"
[ "${HB:-0}" -eq 0 ] && { echo "FAIL: controller is not executing (setInterval regression?)"; exit 1; }
echo "  signers before fault: $(signers)"

echo "=== 3. kill validator node3 ==="
docker stop rehearsal-automine-node3 rehearsal-node3 >/dev/null 2>&1
T0=$(date +%s)

echo "=== 4. watch for detect -> promote -> remove (max 5 min) ==="
DETECTED=0; PROMOTED=0; REMOVED=0
for i in $(seq 1 100); do
  if [ "$DETECTED" -eq 0 ] && docker logs --since 10m rehearsal-poa2-node1 2>&1 | grep -q 'is not mining'; then
    DETECTED=1; echo "  [$(( $(date +%s) - T0 ))s] DETECTED: $(docker logs --since 10m rehearsal-poa2-node1 2>&1 | grep 'is not mining' | tail -1)"
  fi
  SIG=$(signers)
  if [ "$PROMOTED" -eq 0 ] && printf '%s' "$SIG" | grep -qiE "$S5|$S6"; then
    PROMOTED=1; echo "  [$(( $(date +%s) - T0 ))s] PROMOTED a standby -> set size $(count)"
  fi
  if [ "$REMOVED" -eq 0 ] && [ -n "$SIG" ] && ! printf '%s' "$SIG" | grep -qi "$V3"; then
    REMOVED=1; echo "  [$(( $(date +%s) - T0 ))s] REMOVED the failed validator -> set size $(count)"
  fi
  [ "$PROMOTED" -eq 1 ] && [ "$REMOVED" -eq 1 ] && break
  sleep 3
done

echo
echo "===== RESULT ====="
echo "  detected failed validator : $([ $DETECTED -eq 1 ] && echo YES || echo NO)"
echo "  promoted a standby        : $([ $PROMOTED -eq 1 ] && echo YES || echo NO)"
echo "  removed the failed signer : $([ $REMOVED  -eq 1 ] && echo YES || echo NO)"
echo "  final signer set ($(count)): $(signers)"
echo "  chain head: $(head_of 1) (started $H0) — still advancing means no stall"
[ $DETECTED -eq 1 ] && [ $PROMOTED -eq 1 ] && [ $REMOVED -eq 1 ]
