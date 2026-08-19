#!/usr/bin/env bash
# Does PoA² v5 tell "node is DOWN" apart from "node is UP but not sealing"?
#
# Both read as zero sealer activity. v4 replaced either one after ~193s, which
# spends a standby on a problem a sidecar restart would fix. v5 looks the
# suspect up in admin.peers: gone from the network -> replace promptly; still
# connected -> warn loudly and wait far longer.
#
# Two cases, same fault symptom, opposite correct responses:
#   1. sidecar dead, node healthy and peered  -> WARN, do not replace (yet)
#   2. node fully stopped, off the network    -> replace promptly
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

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

cleanup(){ docker start rehearsal-automine-node4 rehearsal-node4 rehearsal-node3 rehearsal-automine-node3 >/dev/null 2>&1
           [ -n "${LOAD:-}" ] && docker rm -f "$LOAD" >/dev/null 2>&1; }
trap cleanup EXIT

echo "=== setup: fresh controllers (v5) + load ==="
docker ps --format '{{.Names}}' | grep -E 'poa2|loadgen' | xargs -r docker rm -f >/dev/null 2>&1
LOAD=$(docker compose run -d --rm loadgen steady http://node5:8545 8 1500 reach 0)
for v in 1 2 3 4 5 6; do docker compose up -d --no-deps "poa2-node$v" >/dev/null 2>&1; done
sleep 25
H0=$(head_of); sleep 8; H1=$(head_of)
[ -n "$H1" ] && [ "$H1" -gt "${H0:-0}" ] || { echo "ABORT: chain not sealing ($H0 -> $H1)"; exit 1; }
echo "  chain sealing ($H0 -> $H1); signers: $(signers)"

# --------------------------------------------------------- CASE 1: peered ---
# node4 must be a signer for this case; if it isn't, use whichever is.
S=$(signers)
if printf '%s' "$S" | grep -qi '90f79bf6'; then VIC=4; VADDR=90f79bf6eb2c4f870365e785982e1f101e93b906
elif printf '%s' "$S" | grep -qi '3c44cddd'; then VIC=3; VADDR=3c44cdddb6a900fa2b585dd299e03d12fa4293bc
else echo "ABORT: neither node3 nor node4 is a signer"; exit 1; fi

echo
echo "=== CASE 1: node$VIC stays UP and peered, only its miner stops ==="
T=$(date -u +%FT%TZ); sleep 1
docker stop "rehearsal-automine-node$VIC" >/dev/null 2>&1
ipc $VIC 'miner.stop()' >/dev/null 2>&1
sleep 3
echo "  node$VIC mining=$(ipc $VIC 'eth.mining')  head=$(head_of $VIC) (alive)"
echo "  watching 5 min — v4 replaced this at ~193s"
EVICT1=0
for i in $(seq 1 75); do
  printf '%s' "$(signers)" | grep -qi "$VADDR" || { EVICT1=1; echo "  [$((i*4))s] EVICTED"; break; }
  sleep 4
done
WARN=$(ctl "$T" 'REACHABLE but not sealing')
echo "  warnings raised: $WARN   signers: $(count)"
[ "${WARN:-0}" -gt 0 ] && ok "case1: controller identified it as REACHABLE-but-not-sealing and warned" \
                       || no "case1: no warning raised — reachability check did not fire"
[ "$EVICT1" -eq 0 ] && ok "case1: healthy peered node was NOT replaced (standby preserved)" \
                    || no "case1: healthy peered node was replaced anyway"
docker start "rehearsal-automine-node$VIC" >/dev/null 2>&1
sleep 25

# ----------------------------------------------------------- CASE 2: down ---
echo
echo "=== CASE 2: node$VIC fully stopped (off the network) ==="
T2=$(date -u +%FT%TZ); sleep 1
docker stop "rehearsal-automine-node$VIC" "rehearsal-node$VIC" >/dev/null 2>&1
T0=$(date +%s); EVICT2=0
for i in $(seq 1 90); do
  printf '%s' "$(signers)" | grep -qi "$VADDR" || { EVICT2=1; echo "  [$(( $(date +%s) - T0 ))s] replaced"; break; }
  sleep 4
done
DEADLOG=$(ctl "$T2" 'dead (off the network)')
echo "  'off the network' classifications: $DEADLOG   signers: $(count)"
[ "$EVICT2" -eq 1 ] && ok "case2: genuinely-down validator WAS replaced" \
                    || no "case2: down validator not replaced within ~6 min"
[ "${DEADLOG:-0}" -gt 0 ] && ok "case2: classified correctly as off-the-network" \
                          || no "case2: not classified as off-the-network"

echo
echo "############ RESULT: $PASS passed, $FAIL failed ############"
echo "  final signers ($(count)): $(signers)"
echo "  head: $(head_of)"
[ "$FAIL" -eq 0 ]
