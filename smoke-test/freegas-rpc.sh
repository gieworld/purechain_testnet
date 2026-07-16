#!/usr/bin/env bash
# Free-gas test via raw JSON-RPC (bypasses the console web3.js client-side guard).
# Proves the NODE accepts and mines zero-fee transactions on a zeroBaseFee chain.
#
# Self-contained: creates its own genesis, datadir, signer key and password — no
# pre-existing state required. Uses a unique high port to avoid colliding with a
# running node / editor on the common 8545-8548 range.
set -u

BIN="${1:?Usage: $0 <geth>}"
BASE=~/clique-freegas
PORT=18545; AP=18546; PP=30445
RPC=http://127.0.0.1:$PORT
KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SIGNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SIGNER_NO0X=f39Fd6e51aad88F6F4ce6aB8827279cffFb92266
DEST=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

pkill -f "clique-freegas" 2>/dev/null; sleep 1
rm -rf "$BASE"; mkdir -p "$BASE"
echo "password" > "$BASE/pw.txt"
echo "$KEY" > "$BASE/key.hex"
VANITY=$(printf '0%.0s' $(seq 1 64)); SEAL=$(printf '0%.0s' $(seq 1 130))
EXTRA=0x${VANITY}${SIGNER_NO0X}${SEAL}

cat > "$BASE/genesis.json" <<EOF
{
  "config": {
    "chainId": 13371,
    "homesteadBlock": 0, "eip150Block": 0, "eip155Block": 0, "eip158Block": 0,
    "byzantiumBlock": 0, "constantinopleBlock": 0, "petersburgBlock": 0,
    "istanbulBlock": 0, "berlinBlock": 0, "londonBlock": 0,
    "shanghaiTime": 0, "cancunTime": 0,
    "zeroBaseFee": true,
    "clique": { "period": 1, "epoch": 30000 }
  },
  "difficulty": "1", "gasLimit": "30000000", "extradata": "${EXTRA}",
  "alloc": { "${SIGNER_NO0X}": { "balance": "100000000000000000000" } }
}
EOF

"$BIN" --datadir "$BASE/data" init "$BASE/genesis.json" >/dev/null 2>&1
"$BIN" --datadir "$BASE/data" account import --password "$BASE/pw.txt" "$BASE/key.hex" >/dev/null 2>&1
"$BIN" --datadir "$BASE/data" --networkid 13371 \
  --unlock "$SIGNER" --password "$BASE/pw.txt" --allow-insecure-unlock \
  --mine --miner.etherbase "$SIGNER" --miner.gasprice 0 --txpool.pricelimit 0 \
  --http --http.addr 127.0.0.1 --http.port $PORT --http.api eth,net,web3 \
  --authrpc.port $AP --port $PP --nodiscover --maxpeers 0 --verbosity 3 \
  > "$BASE/geth.log" 2>&1 &
PID=$!
for i in $(seq 1 30); do
  curl -s "$RPC" -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"net_version","id":1}' | grep -q result && break
  sleep 0.5
done
sleep 2

rpc() { curl -s "$RPC" -X POST -H 'Content-Type: application/json' --data "$1"; }
PASS=0; FAIL=0
check(){ if echo "$2" | grep -Fq "$3"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; echo "        got: $(echo "$2" | head -c 200)"; FAIL=$((FAIL+1)); fi; }

echo ""
echo "===== free-gas zero-fee transactions via JSON-RPC ====="

echo "--- (1) legacy tx, gasPrice 0x0:"
R1=$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"$SIGNER\",\"to\":\"$DEST\",\"value\":\"0x1\",\"gasPrice\":\"0x0\"}],\"id\":1}")
TX1=$(echo "$R1" | grep -oE '0x[0-9a-fA-F]{64}' | head -1)
check "legacy zero-fee tx accepted" "$R1" '"result":"0x'

echo "--- (2) EIP-1559 tx, maxFeePerGas 0x0 / maxPriorityFeePerGas 0x0:"
R2=$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"$SIGNER\",\"to\":\"$DEST\",\"value\":\"0x2\",\"maxFeePerGas\":\"0x0\",\"maxPriorityFeePerGas\":\"0x0\"}],\"id\":1}")
TX2=$(echo "$R2" | grep -oE '0x[0-9a-fA-F]{64}' | head -1)
check "EIP-1559 zero-fee tx accepted" "$R2" '"result":"0x'

sleep 4
LATEST=$(rpc '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}')
check "latest block baseFeePerGas is 0x0" "$LATEST" '"baseFeePerGas":"0x0"'

RC1=$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$TX1\"],\"id\":1}")
check "legacy tx mined (status 0x1)" "$RC1" '"status":"0x1"'
check "legacy tx effectiveGasPrice 0x0" "$RC1" '"effectiveGasPrice":"0x0"'

RC2=$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$TX2\"],\"id\":1}")
check "EIP-1559 tx mined (status 0x1)" "$RC2" '"status":"0x1"'
check "EIP-1559 tx effectiveGasPrice 0x0" "$RC2" '"effectiveGasPrice":"0x0"'

BAL=$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$DEST\",\"latest\"],\"id\":1}")
check "dest balance is 0x3 (both txs delivered 1+2 wei)" "$BAL" '"result":"0x3"'

kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
PANICS=$(grep -c -i panic "$BASE/geth.log")
[ "$PANICS" -eq 0 ] && { echo "  PASS  zero panics in node log"; PASS=$((PASS+1)); } || { echo "  FAIL  $PANICS panics in node log"; FAIL=$((FAIL+1)); }

echo ""
echo "===== RESULT: $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
