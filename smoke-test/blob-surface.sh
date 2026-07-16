#!/usr/bin/env bash
# Blob / type-3 transaction surface on a Cancun Clique chain with no blob DA.
#
# Enabling Cancun (removing the "clique does not support cancun" guard) also
# opens the EIP-4844 blob-gas fields and the type-3 (blob) transaction path. This
# is a ROBUSTNESS check for that newly-opened surface — NOT a full blob-validity
# test (a valid type-3 tx needs a KZG trusted setup, out of scope for a shell
# harness). It confirms:
#   - the head exposes zero blob gas (no blob activity) and eth_blobBaseFee
#     returns the 1-wei minimum (not null) on a live Cancun head
#   - a malformed type-3 tx is rejected with a clean JSON-RPC error (no crash)
#   - the node keeps sealing afterwards and never panics
#
# Usage: blob-surface.sh <geth>
set -u

BIN="${1:?usage: blob-surface.sh <geth>}"
BASE=~/clique-blob
KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SIGNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SIGNER_NO0X=f39Fd6e51aad88F6F4ce6aB8827279cffFb92266
PORT=8545; RPC="http://127.0.0.1:$PORT"

PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $1"; [ $# -gt 1 ] && echo "        $2"; FAIL=$((FAIL+1)); }
rpc(){ curl -s "$RPC" -X POST -H 'Content-Type: application/json' --data "$1"; }
jget(){ echo "$1" | grep -oE "\"$2\":\"[^\"]*\"" | head -1 | sed -E "s/.*:\"([^\"]*)\"/\1/"; }
headnum(){ echo $(( $(jget "$(rpc '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}')" result) )); }

rm -rf "$BASE"; mkdir -p "$BASE"
echo "password" > "$BASE/pw.txt"; echo "$KEY" > "$BASE/key.hex"
VANITY=$(printf '0%.0s' $(seq 1 64)); SEAL=$(printf '0%.0s' $(seq 1 130))
EXTRA=0x${VANITY}${SIGNER_NO0X}${SEAL}

cat > "$BASE/genesis.json" <<EOF
{
  "config": {
    "chainId": 13375,
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

echo "===== boot Cancun node ====="
"$BIN" --datadir "$BASE/data" init "$BASE/genesis.json" >/dev/null 2>&1
"$BIN" --datadir "$BASE/data" account import --password "$BASE/pw.txt" "$BASE/key.hex" >/dev/null 2>&1
"$BIN" --datadir "$BASE/data" --networkid 13375 \
  --unlock "$SIGNER" --password "$BASE/pw.txt" --allow-insecure-unlock \
  --mine --miner.etherbase "$SIGNER" --miner.gasprice 0 --txpool.pricelimit 0 \
  --http --http.addr 127.0.0.1 --http.port $PORT --http.api eth,net,web3 \
  --nodiscover --maxpeers 0 --verbosity 3 > "$BASE/geth.log" 2>&1 &
PID=$!
for _ in $(seq 1 40); do rpc '{"jsonrpc":"2.0","method":"net_version","id":1}' | grep -q result && break; sleep 0.5; done
sleep 3

echo "===================== CHECKS ====================="
# 1. head has zero blob gas (no blob activity on a Clique chain)
HEAD=$(rpc '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}')
EBG=$(jget "$HEAD" excessBlobGas); BGU=$(jget "$HEAD" blobGasUsed)
{ [ "$EBG" = "0x0" ] && [ "$BGU" = "0x0" ]; } && ok "head reports zero blob gas (excessBlobGas=$EBG blobGasUsed=$BGU)" || bad "unexpected blob gas on head" "excess=$EBG used=$BGU"

# 2. eth_blobBaseFee returns the 1-wei minimum (not null) on a live Cancun head
BBF=$(jget "$(rpc '{"jsonrpc":"2.0","method":"eth_blobBaseFee","id":1}')" result)
[ "$BBF" = "0x1" ] && ok "eth_blobBaseFee = 0x1 (min blob base fee, backport live)" || bad "eth_blobBaseFee not 0x1" "got: $BBF"

# 3. a malformed type-3 (blob) tx is rejected with a clean error (no crash)
H0=$(headnum)
BEFORE=$FAIL
for payload in "0x03" "0x03c0" "0x03c88080808080808080"; do
  R=$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendRawTransaction\",\"params\":[\"$payload\"],\"id\":1}")
  echo "    type-3 payload $payload -> $(echo "$R" | head -c 140)"
  echo "$R" | grep -q '"error"' || bad "type-3 payload $payload was NOT rejected" "$R"
done
[ "$FAIL" -eq "$BEFORE" ] && ok "malformed type-3 txs rejected with clean JSON-RPC errors"

# 4. node survived: still sealing + no panic
sleep 3
H1=$(headnum)
[ "$H1" -gt "$H0" ] && ok "node still sealing after type-3 submissions (head $H0 -> $H1)" || bad "node stopped sealing" "head $H0 -> $H1"
PANICS=$(grep -c -i 'panic:' "$BASE/geth.log")
[ "$PANICS" -eq 0 ] && ok "zero panics in node log" || bad "$PANICS panic(s) in node log"

kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
echo ""
echo "===== RESULT: $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
