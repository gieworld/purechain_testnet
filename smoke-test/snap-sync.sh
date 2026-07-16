#!/usr/bin/env bash
# Snap-sync a Cancun Clique chain. Every other sync test in this suite uses FULL
# sync; snap sync is a different code path (snapshot serving + state healing) and
# is the DEFAULT way a new node joins, so it must work on a Cancun PoA chain.
#
# Node A (full, mining) builds a tall Cancun chain. Node B starts fresh with
# --syncmode snap, peers to A, and must catch up. Asserts: snap sync actually
# engaged (state-download markers), B reached A's head, the two agree on a block
# hash at a common height, B's tip is a valid Cancun block, and no panics.
#
# Usage: snap-sync.sh <geth>
set -u

BIN="${1:?usage: snap-sync.sh <geth>}"
BASE=~/clique-snap
KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SIGNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SIGNER_NO0X=f39Fd6e51aad88F6F4ce6aB8827279cffFb92266

PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $1"; [ $# -gt 1 ] && echo "        $2"; FAIL=$((FAIL+1)); }
rpc(){ curl -s "http://127.0.0.1:$1" -X POST -H 'Content-Type: application/json' --data "$2"; }
jget(){ echo "$1" | grep -oE "\"$2\":\"[^\"]*\"" | head -1 | sed -E "s/.*:\"([^\"]*)\"/\1/"; }
headnum(){ echo $(( $(jget "$(rpc "$1" '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}')" result) )); }

rm -rf "$BASE"; mkdir -p "$BASE/na" "$BASE/nb"
echo "password" > "$BASE/pw.txt"; echo "$KEY" > "$BASE/key.hex"
VANITY=$(printf '0%.0s' $(seq 1 64)); SEAL=$(printf '0%.0s' $(seq 1 130))
EXTRA=0x${VANITY}${SIGNER_NO0X}${SEAL}

cat > "$BASE/genesis.json" <<EOF
{
  "config": {
    "chainId": 13374,
    "homesteadBlock": 0, "eip150Block": 0, "eip155Block": 0, "eip158Block": 0,
    "byzantiumBlock": 0, "constantinopleBlock": 0, "petersburgBlock": 0,
    "istanbulBlock": 0, "berlinBlock": 0, "londonBlock": 0,
    "shanghaiTime": 0, "cancunTime": 0, "zeroBaseFee": true,
    "clique": { "period": 1, "epoch": 30000 }
  },
  "difficulty": "1", "gasLimit": "30000000", "extradata": "${EXTRA}",
  "alloc": {
    "${SIGNER_NO0X}": { "balance": "100000000000000000000" },
    "0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02": { "balance": "0", "code": "0x3373fffffffffffffffffffffffffffffffffffffffe14604d57602036146024575f5ffd5b5f35801560495762001fff810690815414603c575f5ffd5b62001fff01545f5260205ff35b5f5ffd5b62001fff42064281555f359062001fff015500" }
  }
}
EOF

echo "===== node A: build a tall Cancun chain (mining) ====="
"$BIN" --datadir "$BASE/na" init "$BASE/genesis.json" >/dev/null 2>&1
"$BIN" --datadir "$BASE/na" account import --password "$BASE/pw.txt" "$BASE/key.hex" >/dev/null 2>&1
"$BIN" --datadir "$BASE/na" --networkid 13374 \
  --unlock "$SIGNER" --password "$BASE/pw.txt" --allow-insecure-unlock \
  --mine --miner.etherbase "$SIGNER" --miner.gasprice 0 --txpool.pricelimit 0 \
  --port 30303 --http --http.addr 127.0.0.1 --http.port 8545 --http.api eth,net,web3,admin \
  --authrpc.port 8551 --nodiscover --verbosity 3 > "$BASE/na/geth.log" 2>&1 &
PA=$!
for _ in $(seq 1 40); do rpc 8545 '{"jsonrpc":"2.0","method":"net_version","id":1}' | grep -q result && break; sleep 0.5; done
# Mine until the chain is tall enough for a real snap pivot (pivot = head-64).
sleep 90
HA=$(headnum 8545); echo "  node A head after mining: $HA"
ENODE_A=$(rpc 8545 '{"jsonrpc":"2.0","method":"admin_nodeInfo","params":[],"id":1}' | grep -oE 'enode://[0-9a-f]+@127\.0\.0\.1:30303')
echo "  enode A: ${ENODE_A:0:40}..."

echo "===== node B: fresh, --syncmode snap, peer to A ====="
"$BIN" --datadir "$BASE/nb" init "$BASE/genesis.json" >/dev/null 2>&1
"$BIN" --datadir "$BASE/nb" --networkid 13374 --syncmode snap \
  --port 30304 --http --http.addr 127.0.0.1 --http.port 8546 --http.api eth,net,web3,admin \
  --authrpc.port 8552 --nodiscover --verbosity 3 > "$BASE/nb/geth.log" 2>&1 &
PB=$!
for _ in $(seq 1 40); do rpc 8546 '{"jsonrpc":"2.0","method":"net_version","id":1}' | grep -q result && break; sleep 0.5; done
rpc 8546 "{\"jsonrpc\":\"2.0\",\"method\":\"admin_addPeer\",\"params\":[\"$ENODE_A\"],\"id\":1}" >/dev/null

echo "===== wait for B to snap-sync and catch up ====="
CAUGHT=0
for t in $(seq 1 60); do
  sleep 2
  HB=$(headnum 8546); HA=$(headnum 8545)
  [ $((t % 5)) -eq 0 ] && echo "  t=$((t*2))s  A=$HA  B=$HB"
  if [ "$HB" -gt 0 ] && [ "$HB" -ge $((HA - 3)) ]; then CAUGHT=1; break; fi
done

# Snapshot both heads while alive, then stop.
HA=$(headnum 8545); HB=$(headnum 8546)
TIPB=$(rpc 8546 '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}')
EXCESSB=$(jget "$TIPB" excessBlobGas)
MINH=$HA; [ "$HB" -lt "$MINH" ] && MINH=$HB; CMP=$((MINH-2)); [ "$CMP" -lt 1 ] && CMP=1
CMPHEX=$(printf '0x%x' "$CMP")
HASH_A=$(jget "$(rpc 8545 "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$CMPHEX\",false],\"id\":1}")" hash)
HASH_B=$(jget "$(rpc 8546 "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$CMPHEX\",false],\"id\":1}")" hash)

kill "$PA" "$PB" 2>/dev/null; wait "$PA" 2>/dev/null; wait "$PB" 2>/dev/null

SNAP=$(grep -icE 'state sync|state download|state heal|Imported new state|Snap sync|state entries' "$BASE/nb/geth.log")
PANICS=$(cat "$BASE"/n*/geth.log 2>/dev/null | grep -ic 'panic:')

echo ""
echo "===================== CHECKS ====================="
echo "  final: A=$HA  B=$HB  compareBlock=$CMP"
[ "$CAUGHT" = 1 ] && ok "node B caught up to node A's head via sync (A=$HA, B=$HB)" || bad "node B did not catch up" "A=$HA B=$HB"
[ "$SNAP" -gt 0 ] && ok "snap sync engaged on node B ($SNAP state-sync log markers)" || bad "no snap-sync markers in B log (may have full-synced)"
[ -n "$HASH_A" ] && [ "$HASH_A" = "$HASH_B" ] && ok "A and B agree on block $CMP hash (${HASH_A:0:12}..)" || bad "head hash mismatch at block $CMP" "A=$HASH_A B=$HASH_B"
[ -n "$EXCESSB" ] && ok "synced tip on B is a valid Cancun block (excessBlobGas=$EXCESSB)" || bad "B tip missing excessBlobGas" "tip: $(echo "$TIPB" | head -c 160)"
[ "$PANICS" -eq 0 ] && ok "zero panics across both node logs" || bad "$PANICS panic(s) in node logs"

echo ""
echo "===== RESULT: $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
