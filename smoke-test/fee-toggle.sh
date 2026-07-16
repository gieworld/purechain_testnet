#!/usr/bin/env bash
# Fee-toggle reference: a free-gas (zeroBaseFee) network can charge gas fees at
# any time WITHOUT a consensus change, fork, or genesis edit — purely via a
# minimum priority tip enforced by node policy. This is the documented escape
# hatch for the "free gas" product: the option is preserved at zero cost.
#
# Proves, on a live zeroBaseFee Cancun chain:
#   1. With a 1 gwei minimum tip enforced (--miner.gasprice / --txpool.pricelimit
#      / --txpool.nolocals), a zero-fee tx is REJECTED ("transaction underpriced").
#   2. A tx paying the tip is mined; effectiveGasPrice == tip (baseFee stays 0,
#      so the whole fee is the tip and goes to the signer).
#   3. The base fee in headers is still 0x0 — zeroBaseFee is untouched.
#
# To go back to free gas: drop these flags (pricelimit 0, gasprice 0, no nolocals)
# and restart. Reversible, per-node, instant.
#
# NOTE: --txpool.nolocals is required so the limit also applies to txs submitted
# through this node's own RPC; without it, locally-submitted txs bypass the floor.
#
# Usage: fee-toggle.sh <geth-patched>
set -u

BIN="${1:?Usage: $0 <geth-patched>}"
BASE=~/clique-fee-toggle
PORT=18595; AP=18596; PP=30495
KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SIGNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SIGNER_NO0X=f39Fd6e51aad88F6F4ce6aB8827279cffFb92266
DEST=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
MINTIP=0x3b9aca00   # 1 gwei

pkill -f "clique-fee-toggle" 2>/dev/null; sleep 1
rm -rf "$BASE"; mkdir -p "$BASE"
echo password > "$BASE/pw.txt"; echo "$KEY" > "$BASE/key.hex"
V=$(printf '0%.0s' $(seq 1 64)); S=$(printf '0%.0s' $(seq 1 130)); EXTRA=0x${V}${SIGNER_NO0X}${S}

cat > "$BASE/g.json" <<EOF
{ "config": { "chainId": 13371, "homesteadBlock":0,"eip150Block":0,"eip155Block":0,"eip158Block":0,
  "byzantiumBlock":0,"constantinopleBlock":0,"petersburgBlock":0,"istanbulBlock":0,"berlinBlock":0,"londonBlock":0,
  "shanghaiTime":0,"cancunTime":0,"zeroBaseFee":true,"clique":{"period":1,"epoch":30000} },
  "difficulty":"1","gasLimit":"30000000","extradata":"${EXTRA}",
  "alloc": { "${SIGNER_NO0X}": { "balance":"100000000000000000000" } } }
EOF

"$BIN" --datadir "$BASE/data" init "$BASE/g.json" >/dev/null 2>&1
"$BIN" --datadir "$BASE/data" account import --password "$BASE/pw.txt" "$BASE/key.hex" >/dev/null 2>&1
# Enforce a 1 gwei minimum tip — this is the single "turn on fees" knob.
"$BIN" --datadir "$BASE/data" --networkid 13371 \
  --unlock "$SIGNER" --password "$BASE/pw.txt" --allow-insecure-unlock \
  --mine --miner.etherbase "$SIGNER" \
  --miner.gasprice $MINTIP --txpool.pricelimit 1000000000 --txpool.nolocals \
  --http --http.addr 127.0.0.1 --http.port $PORT --http.api eth,net,web3 \
  --authrpc.port $AP --port $PP --nodiscover --maxpeers 0 --verbosity 2 \
  > "$BASE/geth.log" 2>&1 &
PID=$!
for i in $(seq 1 40); do
  curl -s "http://127.0.0.1:$PORT" -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"net_version","id":1}' | grep -q result && break
  sleep 0.5
done
sleep 2

rpc(){ curl -s "http://127.0.0.1:$PORT" -X POST -H 'Content-Type: application/json' --data "$1"; }
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL  $1"; [ $# -gt 1 ] && echo "        $2"; FAIL=$((FAIL+1)); }
check(){ if echo "$2" | grep -Fq "$3"; then ok "$1"; else bad "$1" "got: $(echo "$2" | head -c 200)"; fi; }

echo ""
echo "===== fee toggle on a zeroBaseFee chain (1 gwei min tip) ====="

# 1. zero-fee tx must be rejected
A=$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"$SIGNER\",\"to\":\"$DEST\",\"value\":\"0x1\",\"gasPrice\":\"0x0\"}],\"id\":1}")
check "zero-fee tx is REJECTED (underpriced)" "$A" "underpriced"

# 2. tx paying the tip is accepted + mined with effectiveGasPrice == tip
B=$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"$SIGNER\",\"to\":\"$DEST\",\"value\":\"0x1\",\"gasPrice\":\"$MINTIP\"}],\"id\":1}")
TXB=$(echo "$B" | grep -oE '0x[0-9a-fA-F]{64}' | head -1)
check "tip-paying tx accepted" "$B" '"result":"0x'
sleep 3
R=$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$TXB\"],\"id\":1}")
check "tip-paying tx mined (status 0x1)" "$R" '"status":"0x1"'
check "effectiveGasPrice == 1 gwei tip" "$R" '"effectiveGasPrice":"0x3b9aca00"'

# 3. base fee in the header is still zero
L=$(rpc '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}')
check "header baseFeePerGas still 0x0 (zeroBaseFee untouched)" "$L" '"baseFeePerGas":"0x0"'

kill $PID 2>/dev/null; wait $PID 2>/dev/null
echo ""
echo "===== RESULT: $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
