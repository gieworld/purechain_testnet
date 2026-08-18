#!/usr/bin/env bash
# IN-PLACE BINARY UPGRADE test: stop the previous build, start the new build on
# the SAME datadir, and prove the chain carries on without losing or rewriting
# history. Then downgrade back to prove the datadir is still readable.
#
#   PHASE 1  prev build mines a Cancun chain, record head + block hashes
#   PHASE 2  swap binary in place -> new build must continue from the same head,
#            with every pre-upgrade block hash unchanged (no reorg, no rewind)
#   PHASE 3  swap back to prev build -> must still start and keep mining
#
# Usage: inplace-upgrade.sh <geth-prev> <geth-new>
set -u

PREV="${1:?usage: $0 <geth-prev> <geth-new>}"
NEW="${2:?usage: $0 <geth-prev> <geth-new>}"

BASE=~/clique-inplace
P=18651; AP=18661; PP=30551
KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SIGNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SIGNER_NO0X=f39Fd6e51aad88F6F4ce6aB8827279cffFb92266

PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

rpc(){ curl -s -X POST -H 'Content-Type: application/json' --data "$1" "http://127.0.0.1:$P"; }
head_num(){ printf "%d" "$(rpc '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | sed -E 's/.*"result":"([^"]*)".*/\1/')" 2>/dev/null || echo 0; }
# grep -o so a null/error response yields EMPTY instead of sed passing the
# whole error JSON through — two identical error responses must never count as
# "hashes identical".
blk_hash(){ rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$1\",false],\"id\":1}" | grep -o '"hash":"0x[0-9a-f]*"' | head -1 | sed -E 's/.*:"([^"]*)"/\1/'; }
blk_field(){ rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$1\",false],\"id\":1}" | grep -o "\"$2\":\"[^\"]*\"" | head -1; }
wait_rpc(){ for _ in $(seq 1 80); do rpc '{"jsonrpc":"2.0","method":"net_version","id":1}' | grep -q result && return 0; sleep 0.5; done; return 1; }
stopnode(){ kill "$1" 2>/dev/null; for _ in $(seq 1 30); do kill -0 "$1" 2>/dev/null || break; sleep 0.5; done; kill -9 "$1" 2>/dev/null; wait "$1" 2>/dev/null || true; sleep 1; }

start(){ # $1=bin $2=log
  "$1" --datadir "$BASE/data" --networkid 13411 \
    --unlock "$SIGNER" --password "$BASE/pw.txt" --allow-insecure-unlock \
    --mine --miner.etherbase "$SIGNER" --miner.gasprice 0 --txpool.pricelimit 0 \
    --http --http.addr 127.0.0.1 --http.port $P --http.api eth,net,web3,admin \
    --authrpc.port $AP --port $PP --nodiscover --maxpeers 5 --verbosity 3 > "$2" 2>&1 &
  echo $!
}

pkill -f "clique-inplace" 2>/dev/null; sleep 1
rm -rf "$BASE"; mkdir -p "$BASE/data"
echo "password" > "$BASE/pw.txt"; echo "$KEY" > "$BASE/key.hex"
VANITY=$(printf '0%.0s' $(seq 1 64)); SEAL=$(printf '0%.0s' $(seq 1 130))

cat > "$BASE/genesis.json" <<EOF
{
  "config": {
    "chainId": 13411,
    "homesteadBlock":0,"eip150Block":0,"eip155Block":0,"eip158Block":0,
    "byzantiumBlock":0,"constantinopleBlock":0,"petersburgBlock":0,"istanbulBlock":0,
    "berlinBlock":0,"londonBlock":0,
    "shanghaiTime":0,"cancunTime":0,
    "zeroBaseFee": true,
    "clique": { "period": 1, "epoch": 30000 }
  },
  "difficulty":"1","gasLimit":"0x1c9c380",
  "extradata":"0x${VANITY}${SIGNER_NO0X}${SEAL}",
  "alloc": { "${SIGNER}": { "balance": "0x56bc75e2d63100000" } }
}
EOF

"$PREV" --datadir "$BASE/data" init "$BASE/genesis.json" > /dev/null 2>&1
"$PREV" --datadir "$BASE/data" account import --password "$BASE/pw.txt" "$BASE/key.hex" > /dev/null 2>&1

echo "############################################################"
echo "# PHASE 1 - previous build builds a Cancun chain"
echo "############################################################"
PID=$(start "$PREV" "$BASE/1-prev.log")
wait_rpc || { no "prev build never came up"; tail -20 "$BASE/1-prev.log"; exit 1; }
for _ in $(seq 1 40); do [ "$(head_num)" -ge 8 ] && break; sleep 1; done
H1=$(head_num)
[ "$H1" -ge 6 ] && ok "prev build mined to head=$H1" || no "prev build stalled at head=$H1"

# snapshot the hashes of every block we will later re-check. Every snapshot
# must be non-empty NOW: an empty baseline would make the later equality checks
# vacuous (empty = empty), so a failed snapshot is a hard FAIL up front.
declare -A PRE
SNAP_OK=1
for n in 1 2 3 4 5; do
  PRE[$n]=$(blk_hash "0x$(printf %x $n)")
  [ -n "${PRE[$n]}" ] || SNAP_OK=0
done
GEN=$(blk_hash "0x0")
[ -n "$GEN" ] || SNAP_OK=0
[ "$SNAP_OK" -eq 1 ] || no "could not snapshot pre-upgrade hashes — later identity checks would be vacuous"
CANCUN_PRE=$(blk_field "latest" "excessBlobGas")
echo "        genesis=$(echo "$GEN" | head -c 18)...  head=$H1  $CANCUN_PRE"
stopnode "$PID"
echo "        (prev build stopped cleanly)"

echo
echo "############################################################"
echo "# PHASE 2 - IN-PLACE SWAP to the new build, same datadir"
echo "############################################################"
PID=$(start "$NEW" "$BASE/2-new.log")
if ! wait_rpc; then
  no "new build FAILED to start on the previous build's datadir"
  tail -25 "$BASE/2-new.log"; exit 1
fi
ok "new build started on the previous build's datadir"

H2=$(head_num)
[ "$H2" -ge "$H1" ] && ok "no rewind on upgrade (head $H1 -> $H2)" \
                    || no "chain REWOUND on upgrade ($H1 -> $H2)"

# genesis + every recorded pre-upgrade block must be byte-identical
[ "$(blk_hash "0x0")" = "$GEN" ] && ok "genesis hash unchanged after upgrade" \
                                 || no "genesis hash CHANGED after upgrade"
SAME=1
for n in 1 2 3 4 5; do
  [ "$(blk_hash "0x$(printf %x $n)")" = "${PRE[$n]}" ] || { SAME=0; echo "        block #$n differs"; }
done
[ "$SAME" -eq 1 ] && ok "all pre-upgrade block hashes identical (history preserved)" \
                  || no "pre-upgrade block hashes CHANGED (history rewritten)"

# chain must keep advancing under the new binary
for _ in $(seq 1 30); do [ "$(head_num)" -gt "$((H2+3))" ] && break; sleep 1; done
H3=$(head_num)
[ "$H3" -gt "$H2" ] && ok "chain CONTINUES mining under new build ($H2 -> $H3)" \
                    || no "chain stopped advancing under new build (stuck at $H2)"

# Cancun fields still present on new blocks
CANCUN_POST=$(blk_field "latest" "excessBlobGas")
[ -n "$CANCUN_POST" ] && ok "Cancun header fields still emitted ($CANCUN_POST)" \
                      || no "Cancun header fields MISSING after upgrade"
WR=$(blk_field "latest" "withdrawalsRoot")
[ -n "$WR" ] && ok "Shanghai withdrawalsRoot still present" || no "withdrawalsRoot missing"

# a zero-fee tx must still mine (free-gas intact across the upgrade)
TXH=$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"$SIGNER\",\"to\":\"$SIGNER\",\"value\":\"0x1\",\"gas\":\"0x5208\",\"gasPrice\":\"0x0\"}],\"id\":1}" | sed -E 's/.*"result":"([^"]*)".*/\1/')
if [ -n "$TXH" ] && [ "${TXH:0:2}" = "0x" ]; then
  MINED=0
  for _ in $(seq 1 25); do
    rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$TXH\"],\"id\":1}" | grep -q '"blockNumber"' && { MINED=1; break; }
    sleep 1
  done
  [ "$MINED" -eq 1 ] && ok "zero-fee tx still mines after upgrade" || no "zero-fee tx not mined after upgrade"
else
  no "could not submit zero-fee tx after upgrade"
fi

P2=$(grep -ci panic "$BASE/2-new.log" || true)
[ "$P2" -eq 0 ] && ok "new build: zero panics" || no "new build: $P2 panic lines"
H_AFTER=$(head_num); HASH_AFTER=$(blk_hash "0x$(printf %x $H1)")
stopnode "$PID"

echo
echo "############################################################"
echo "# PHASE 3 - DOWNGRADE back to the previous build"
echo "############################################################"
PID=$(start "$PREV" "$BASE/3-back.log")
if wait_rpc; then
  ok "previous build re-starts on the upgraded datadir (downgrade works)"
  [ "$(blk_hash "0x$(printf %x $H1)")" = "$HASH_AFTER" ] \
    && ok "block #$H1 hash still identical after downgrade" \
    || no "block #$H1 hash changed after downgrade"
  HD=$(head_num)
  for _ in $(seq 1 25); do [ "$(head_num)" -gt "$((HD+2))" ] && break; sleep 1; done
  [ "$(head_num)" -gt "$HD" ] && ok "chain keeps mining after downgrade" || no "chain stalled after downgrade"
  P3=$(grep -ci panic "$BASE/3-back.log" || true)
  [ "$P3" -eq 0 ] && ok "downgraded build: zero panics" || no "downgraded build: $P3 panic lines"
else
  no "previous build FAILED to start on the upgraded datadir (downgrade broken)"
  tail -20 "$BASE/3-back.log"
fi
stopnode "$PID"

echo
echo "================== RESULT: $PASS passed, $FAIL failed =================="
[ "$FAIL" -eq 0 ]
