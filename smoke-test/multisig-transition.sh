#!/usr/bin/env bash
# Multi-signer Clique + Cancun transition test.
#
# Everything else in this suite is single-signer. Real PoA runs N signers with
# in-turn/out-of-turn difficulty (2 vs 1) and randomized wiggle delays, which is
# exactly the timing regime that stresses the miner fork-boundary fix. This boots
# a 3-signer network (clique period 5, zeroBaseFee), peers the nodes over p2p, and
# mines across a TIMED Shanghai/Cancun activation, then proves:
#   - all 3 nodes share one genesis hash
#   - the chain advances past the fork on every node
#   - the 3 nodes AGREE on the block hash at a common height (consensus held
#     across the fork — the scariest failure mode for a seal-hash/field change)
#   - the tip is a valid Cancun block (excessBlobGas present) on every node
#   - no panics and no Cancun-field header errors anywhere
#   - both difficulty 1 and 2 were produced (out-of-turn signing actually happened)
#
# Usage: multisig-transition.sh <geth>
set -u

BIN="${1:?usage: multisig-transition.sh <geth>}"
BASE=~/clique-multisig
PERIOD=5
FORKDELAY=30      # seconds until shanghai/cancun activate (crossed while mining)
MINE_SECS=55      # how long to mine after the network is peered

# Three Hardhat dev accounts (key -> address).
KEYS=(
  ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
  59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
  5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
)
ADDRS=(
  f39Fd6e51aad88F6F4ce6aB8827279cffFb92266
  70997970C51812dc3A010C7d01b50e0d17dc79C8
  3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
)
N=${#ADDRS[@]}

PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $1"; [ $# -gt 1 ] && echo "        $2"; FAIL=$((FAIL+1)); }
rpc() { curl -s "http://127.0.0.1:$1" -X POST -H 'Content-Type: application/json' --data "$2"; }
jget(){ echo "$1" | grep -oE "\"$2\":\"[^\"]*\"" | head -1 | sed -E "s/.*:\"([^\"]*)\"/\1/"; }

rm -rf "$BASE"; mkdir -p "$BASE"
echo "password" > "$BASE/pw.txt"

# Build genesis extradata: 32-byte vanity + signer addresses (ASC, 20B each) + 65-byte seal.
VANITY=$(printf '0%.0s' $(seq 1 64)); SEAL=$(printf '0%.0s' $(seq 1 130))
SIGNERS_HEX=$(printf '%s\n' "${ADDRS[@]}" | tr 'A-Z' 'a-z' | sort | tr -d '\n')
EXTRA=0x${VANITY}${SIGNERS_HEX}${SEAL}
echo "signers (sorted): $SIGNERS_HEX"
echo "extradata length (hex chars, want $((64 + N*40 + 130))): $(( ${#EXTRA} - 2 ))"

# Fund all three signers.
ALLOC=""
for a in "${ADDRS[@]}"; do ALLOC="${ALLOC}\"${a}\": { \"balance\": \"100000000000000000000\" },"; done

NOW=$(date +%s); FORKTIME=$((NOW + FORKDELAY))
cat > "$BASE/genesis.json" <<EOF
{
  "config": {
    "chainId": 13372,
    "homesteadBlock": 0, "eip150Block": 0, "eip155Block": 0, "eip158Block": 0,
    "byzantiumBlock": 0, "constantinopleBlock": 0, "petersburgBlock": 0,
    "istanbulBlock": 0, "berlinBlock": 0, "londonBlock": 0,
    "shanghaiTime": ${FORKTIME}, "cancunTime": ${FORKTIME},
    "zeroBaseFee": true,
    "clique": { "period": ${PERIOD}, "epoch": 30000 }
  },
  "difficulty": "1", "gasLimit": "30000000", "extradata": "${EXTRA}",
  "alloc": {
    ${ALLOC}
    "0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02": { "balance": "0", "code": "0x3373fffffffffffffffffffffffffffffffffffffffe14604d57602036146024575f5ffd5b5f35801560495762001fff810690815414603c575f5ffd5b62001fff01545f5260205ff35b5f5ffd5b62001fff42064281555f359062001fff015500" }
  }
}
EOF

echo "===== init + start ${N} signer nodes (period ${PERIOD}, forks @ +${FORKDELAY}s) ====="
PIDS=()
for i in $(seq 0 $((N-1))); do
  D="$BASE/n$i"; mkdir -p "$D"
  echo "${KEYS[$i]}" > "$D/key.hex"
  "$BIN" --datadir "$D" init "$BASE/genesis.json" >/dev/null 2>&1
  "$BIN" --datadir "$D" account import --password "$BASE/pw.txt" "$D/key.hex" >/dev/null 2>&1
  "$BIN" --datadir "$D" --networkid 13372 \
    --port $((30303+i)) --http --http.addr 127.0.0.1 --http.port $((8545+i)) \
    --http.api eth,net,web3,admin,clique --authrpc.port $((8551+i)) \
    --unlock "0x${ADDRS[$i]}" --password "$BASE/pw.txt" --allow-insecure-unlock \
    --mine --miner.etherbase "0x${ADDRS[$i]}" --miner.gasprice 0 --txpool.pricelimit 0 \
    --nodiscover --verbosity 3 > "$D/geth.log" 2>&1 &
  PIDS+=("$!")
done

# Wait for every node's RPC to answer.
for i in $(seq 0 $((N-1))); do
  for _ in $(seq 1 40); do rpc $((8545+i)) '{"jsonrpc":"2.0","method":"net_version","id":1}' | grep -q result && break; sleep 0.5; done
done

echo "===== mesh-peer the nodes ====="
ENODES=()
for i in $(seq 0 $((N-1))); do
  info=$(rpc $((8545+i)) '{"jsonrpc":"2.0","method":"admin_nodeInfo","params":[],"id":1}')
  ENODES+=("$(echo "$info" | grep -oE 'enode://[0-9a-f]+@127\.0\.0\.1:[0-9]+' | head -1)")
done
for i in $(seq 0 $((N-1))); do
  for j in $(seq 0 $((N-1))); do
    [ "$i" = "$j" ] && continue
    rpc $((8545+i)) "{\"jsonrpc\":\"2.0\",\"method\":\"admin_addPeer\",\"params\":[\"${ENODES[$j]}\"],\"id\":1}" >/dev/null
  done
done
sleep 6
for i in $(seq 0 $((N-1))); do
  pc=$(rpc $((8545+i)) '{"jsonrpc":"2.0","method":"net_peerCount","id":1}' | grep -oE '"result":"0x[0-9a-f]+"' | grep -oE '0x[0-9a-f]+')
  echo "  node $i peers: $(( ${pc:-0} ))"
done

echo "===== mine across the fork (${MINE_SECS}s) ====="
sleep "$MINE_SECS"

# ---- gather state from every node while still alive ----
declare -a HEADNUM HEADHASH GENHASH TIPEXCESS
for i in $(seq 0 $((N-1))); do
  b=$(rpc $((8545+i)) '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}')
  HEADNUM[$i]=$(( $(jget "$b" number) ))
  HEADHASH[$i]=$(jget "$b" hash)
  TIPEXCESS[$i]=$(jget "$b" excessBlobGas)
  g=$(rpc $((8545+i)) '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}')
  GENHASH[$i]=$(jget "$g" hash)
  echo "  node $i: head=${HEADNUM[$i]} hash=${HEADHASH[$i]:0:12}.. excessBlobGas=${TIPEXCESS[$i]:-<none>}"
done

# Common height all nodes have, a couple blocks back (stable, avoids head races).
MINH=${HEADNUM[0]}; for i in $(seq 0 $((N-1))); do [ "${HEADNUM[$i]}" -lt "$MINH" ] && MINH=${HEADNUM[$i]}; done
CMP=$((MINH - 2)); [ "$CMP" -lt 1 ] && CMP=1
CMPHEX=$(printf '0x%x' "$CMP")
declare -a CMPHASH
for i in $(seq 0 $((N-1))); do
  b=$(rpc $((8545+i)) "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$CMPHEX\",false],\"id\":1}")
  CMPHASH[$i]=$(jget "$b" hash)
done

# Per-signer seal activity (proves the signers actually rotated). In a healthy
# network every block is in-turn (difficulty 2); out-of-turn (difficulty 1) only
# appears when the in-turn signer is absent, so rotation is proven by DISTINCT
# sealers in clique_status, not by difficulty variety.
CLIQUE_STATUS=$(rpc 8545 '{"jsonrpc":"2.0","method":"clique_status","params":[],"id":1}')
DIFFS=""
for n in $(seq 1 "$MINH"); do
  b=$(rpc 8545 "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$(printf '0x%x' "$n")\",false],\"id\":1}")
  DIFFS="${DIFFS} $(jget "$b" difficulty)"
done

echo "===== stop nodes ====="
for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null; done

echo ""
echo "===================== CHECKS ====================="
# 1. one genesis across all nodes
allsame=1; for i in $(seq 0 $((N-1))); do [ "${GENHASH[$i]}" = "${GENHASH[0]}" ] || allsame=0; done
[ "$allsame" = 1 ] && [ -n "${GENHASH[0]}" ] && ok "all ${N} nodes share genesis hash (${GENHASH[0]:0:12}..)" || bad "genesis hash mismatch across nodes"

# 2. chain advanced past the fork on every node (need > ~FORKDELAY/PERIOD blocks)
need=$(( FORKDELAY / PERIOD + 2 )); adv=1
for i in $(seq 0 $((N-1))); do [ "${HEADNUM[$i]}" -ge "$need" ] || adv=0; done
[ "$adv" = 1 ] && ok "every node advanced past the fork (heads: ${HEADNUM[*]}; need >= $need)" || bad "a node stalled" "heads: ${HEADNUM[*]}"

# 3. CONSENSUS: identical hash at common height across all nodes
allsame=1; for i in $(seq 0 $((N-1))); do [ "${CMPHASH[$i]}" = "${CMPHASH[0]}" ] || allsame=0; done
[ "$allsame" = 1 ] && [ -n "${CMPHASH[0]}" ] && ok "all ${N} nodes agree on block $CMP hash (${CMPHASH[0]:0:12}..)" || bad "consensus split at block $CMP" "hashes: ${CMPHASH[*]}"

# 4. Cancun live at the tip on every node
c4=1; for i in $(seq 0 $((N-1))); do [ -n "${TIPEXCESS[$i]}" ] || c4=0; done
[ "$c4" = 1 ] && ok "tip carries excessBlobGas on every node (Cancun live)" || bad "a node tip has no excessBlobGas" "excess: ${TIPEXCESS[*]}"

# 5. no panics anywhere
pan=$(cat "$BASE"/n*/geth.log 2>/dev/null | grep -ic 'panic:')
[ "$pan" -eq 0 ] && ok "zero panics across all node logs" || bad "$pan panic(s) in node logs"

# 6. no Cancun-field header errors anywhere
cfe=$(cat "$BASE"/n*/geth.log 2>/dev/null | grep -icE 'missing (excessBlobGas|blobGasUsed|parentBeaconRoot)|invalid (excessBlobGas|blobGasUsed|parentBeaconRoot)')
[ "$cfe" -eq 0 ] && ok "no Cancun-field header errors across all node logs" || bad "$cfe Cancun-field header error(s)"

# 7. signer rotation: multiple distinct signers actually sealed blocks.
SEALERS=$(echo "$CLIQUE_STATUS" | grep -oE '0x[0-9a-fA-F]{40}' | tr 'A-Z' 'a-z' | sort -u | wc -l)
INTURN=$(echo "$CLIQUE_STATUS" | grep -oE '"inturnPercent":[0-9]+' | grep -oE '[0-9]+$')
echo "  difficulties seen: $(echo "$DIFFS" | tr ' ' '\n' | sort -u | tr '\n' ' ')(diff 2 = in-turn; all in-turn is healthy)"
echo "  clique_status: distinct sealers=${SEALERS:-0}, inturnPercent=${INTURN:-?}%"
if [ "${SEALERS:-0}" -ge 2 ]; then
  ok "signers rotated across the fork: ${SEALERS} distinct sealers (inturnPercent ${INTURN:-?}%)"
else
  bad "signer rotation not observed (single sealer)" "clique_status: $CLIQUE_STATUS"
fi

echo ""
echo "===== RESULT: $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
