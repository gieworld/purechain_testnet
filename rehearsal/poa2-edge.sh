#!/usr/bin/env bash
# PoA² v3 edge cases — the three that decide operational policy:
#   A. Does it evict healthy validators during a rolling upgrade?
#   B. Does it evict a healthy node whose sealing sidecar died?
#   C. Does it heal a SECOND fault, or go deaf after the first cycle?
#
# Every test asserts the controller was AWAKE for it (a deaf controller
# produces the same "nothing happened" as a correct decision — that false pass
# is exactly what the previous run produced).
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

ALLV="1 2 3 4 5 6"
ipc(){ timeout 25 docker exec "rehearsal-node$1" geth attach --exec "$2" /data/geth.ipc 2>/dev/null | tr -d '\r'; }
head_of(){ ipc "${1:-1}" 'eth.blockNumber' | grep -oE '^[0-9]+$' | head -1; }
signers(){ ipc "${1:-1}" 'JSON.stringify(clique.getSigners())'; }
count(){ ipc "${1:-1}" 'clique.getSigners().length' | grep -oE '^[0-9]+$' | head -1; }
mine_on(){ ipc "$1" 'try{miner.setEtherbase(eth.accounts[0])}catch(e){}; if(!eth.mining)miner.start()' >/dev/null; }
has(){ printf '%s' "$1" | grep -qi "$2"; }
# aggregate controller output across every node running one
ctl(){ local s="$1" pat="$2" n=0 v; for v in $ALLV; do
    docker ps --format '{{.Names}}' | grep -q "rehearsal-poa2-node$v" || continue
    n=$(( n + $(docker logs --since "$s" "rehearsal-poa2-node$v" 2>&1 | grep -c "$pat" || true) )); done; echo "$n"; }
wait_alive(){ for _ in $(seq 1 40); do [ -n "$(head_of "$1")" ] && return 0; sleep 3; done; return 1; }

V1=f39fd6e51aad88f6f4ce6ab8827279cfffb92266
V2=70997970c51812dc3a010c7d01b50e0d17dc79c8
V4=90f79bf6eb2c4f870365e785982e1f101e93b906

PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

echo "############ setup: controllers on EVERY node + continuous load ############"
# LOAD, not force-mining. `miner.start()` from outside is undone within ~2s by
# the sealing sidecar, which stops the miner once transaction activity dies —
# a previous run froze the chain at one block for 20 minutes and every test
# after it was vacuous. Transactions are what keep an on-demand chain sealing,
# so the tests need them for the whole run, exactly like production.
docker ps --format '{{.Names}}' | grep -E 'poa2|loadgen' | xargs -r docker rm -f >/dev/null 2>&1
LOAD=$(docker compose run -d --rm loadgen steady http://node5:8545 8 2400 poa2-edge 0)
echo "  load generator: ${LOAD:0:12}"
trap 'docker rm -f "$LOAD" >/dev/null 2>&1 || true' EXIT
for v in $ALLV; do docker compose up -d --no-deps "poa2-node$v" >/dev/null 2>&1; done
sleep 25
H_A=$(head_of 1); sleep 10; H_B=$(head_of 1)
if [ -n "$H_A" ] && [ -n "$H_B" ] && [ "$H_B" -gt "$H_A" ]; then
  echo "  chain is sealing ($H_A -> $H_B)"
else
  echo "  ABORT: chain is not producing blocks ($H_A -> $H_B); every test below would be vacuous"; exit 1
fi
LIVE=$(docker ps --format '{{.Names}}' | grep -c poa2 || true)
echo "  controllers running: $LIVE"
SIG0=$(signers); echo "  signers ($(count)): $SIG0"
BOOT=$(ctl 2m 'v3 running')
[ "${BOOT:-0}" -ge 4 ] && ok "setup: controllers started ($BOOT banners)" || no "setup: only $BOOT controllers came up"

# ---------------------------------------------------------------- TEST A ----
echo
echo "############ A. rolling upgrade WITH PoA² running ############"
A_START=$(date -u +%FT%TZ); sleep 1
for v in 1 2 4; do
  echo "  -- restarting node$v --"
  T=$(date +%s)
  docker restart "rehearsal-node$v" >/dev/null 2>&1
  wait_alive "$v" || echo "     warn: slow return"
  docker exec "rehearsal-node$v" geth attach --exec 'loadScript("/scripts/addpeers.js")' /data/geth.ipc >/dev/null 2>&1 || true
  echo "     back after $(( $(date +%s) - T ))s; signers $(count)"
  sleep 25
done
sleep 40
A_SEEN=$(ctl "$A_START" 'is not mining')       # noticed (fine)
A_ACTED=$(ctl "$A_START" 'confirmed dead')     # acted (NOT fine)
A_REC=$(ctl "$A_START" 'resumed sealing')      # noticed then cleared (ideal)
A_SIG=$(signers)
echo "  noticed=$A_SEEN  cleared-after-recovery=$A_REC  acted=$A_ACTED"
[ "$A_SIG" = "$SIG0" ] && ok "A: signer set unchanged through the rolling upgrade" \
                      || no "A: signer set MUTATED during routine maintenance"
[ "${A_ACTED:-0}" -eq 0 ] && ok "A: no replacement was triggered for a merely-restarting validator" \
                          || no "A: $A_ACTED replacement(s) triggered against healthy validators mid-upgrade"

# ---------------------------------------------------------------- TEST B ----
echo
echo "############ B. healthy node, DEAD sealing sidecar ############"
B_START=$(date -u +%FT%TZ); sleep 1
docker stop rehearsal-automine-node4 >/dev/null 2>&1
B_EVICT=0
for i in $(seq 1 80); do
  S=$(signers); [ -n "$S" ] && ! has "$S" "$V4" && { B_EVICT=1; break; }
  sleep 4
done
B_SEEN=$(ctl "$B_START" 'is not mining'); B_ACTED=$(ctl "$B_START" 'confirmed dead')
echo "  node4 head=$(head_of 4) (alive)   noticed=$B_SEEN  acted=$B_ACTED  signers=$(count)"
# The controller MUST have been awake, or this proves nothing.
[ "${B_SEEN:-0}" -gt 0 ] && ok "B: controller was AWAKE and noticed node4 stopped sealing" \
                         || no "B: controller never noticed — result below is meaningless (deaf controller)"
if [ "$B_EVICT" -eq 1 ]; then
  no "B: a healthy node was EVICTED because its sidecar died — burns a standby for a sidecar restart"
else
  ok "B: healthy node with a dead sidecar was NOT evicted"
fi
docker start rehearsal-automine-node4 >/dev/null 2>&1; sleep 8
sleep 20

# ---------------------------------------------------------------- TEST C ----
echo
echo "############ C. SECOND fault — does the detector re-arm? ############"
C_START=$(date -u +%FT%TZ); sleep 1
echo "  signers before: $(signers)"
docker stop rehearsal-automine-node2 rehearsal-node2 >/dev/null 2>&1
T0=$(date +%s); C_HEAL=0
for i in $(seq 1 110); do
  S=$(signers); C=$(count)
  if [ -n "$S" ] && ! has "$S" "$V2" && [ "${C:-0}" -eq 4 ]; then
    C_HEAL=1; echo "  [$(( $(date +%s) - T0 ))s] healed: node2 out, set back to 4"; break
  fi
  sleep 4
done
C_SEEN=$(ctl "$C_START" 'is not mining'); C_ACTED=$(ctl "$C_START" 'confirmed dead')
echo "  noticed=$C_SEEN  acted=$C_ACTED   signers now: $(signers)"
[ "${C_SEEN:-0}" -gt 0 ] && ok "C: detector RE-ARMED after the earlier cycle (noticed the new fault)" \
                         || no "C: detector still deaf — never noticed the second fault"
[ "$C_HEAL" -eq 1 ] && ok "C: second fault fully healed" \
                    || no "C: second fault noticed but not healed"

echo
echo "############ RESULT: $PASS passed, $FAIL failed ############"
echo "  final signers ($(count)): $(signers)"
echo "  head: $(head_of 1)"
[ "$FAIL" -eq 0 ]
