#!/usr/bin/env bash
# MetaMask fee-estimation compatibility test.
#
# MetaMask (and most modern wallets) switched to the London fee model: they call
# eth_feeHistory + eth_maxPriorityFeePerGas to build fee suggestions, and require
# baseFeePerGas to be present in block headers. On a pre-London Istanbul node these
# calls either error or return no data, breaking fee display and tx submission.
#
# This script boots a zeroBaseFee + Cancun chain and checks every RPC endpoint
# the wallet uses during its fee-estimation flow.
set -u

BIN="${1:?Usage: $0 <geth>}"
BASE=~/clique-metamask
RPC=http://127.0.0.1:8546
KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SIGNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SIGNER_NO0X=f39Fd6e51aad88F6F4ce6aB8827279cffFb92266
DEST=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

pkill -f "clique-metamask" 2>/dev/null; sleep 0.5
rm -rf "$BASE"; mkdir -p "$BASE"
echo "password" > "$BASE/pw.txt"
echo "$KEY" > "$BASE/key.hex"
VANITY=$(printf '0%.0s' $(seq 1 64))
SEAL=$(printf '0%.0s' $(seq 1 130))
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
  "difficulty": "1", "gasLimit": "30000000",
  "extradata": "${EXTRA}",
  "alloc": { "${SIGNER_NO0X}": { "balance": "100000000000000000000" } }
}
EOF

"$BIN" --datadir "$BASE/data" init "$BASE/genesis.json" 2>&1 | tail -1
"$BIN" --datadir "$BASE/data" account import --password "$BASE/pw.txt" "$BASE/key.hex" >/dev/null 2>&1
"$BIN" --datadir "$BASE/data" --networkid 13371 \
  --unlock "$SIGNER" --password "$BASE/pw.txt" --allow-insecure-unlock \
  --mine --miner.etherbase "$SIGNER" --miner.gasprice 0 --txpool.pricelimit 0 \
  --http --http.addr 127.0.0.1 --http.port 8546 --http.api eth,net,web3 \
  --nodiscover --maxpeers 0 --verbosity 3 \
  > "$BASE/geth.log" 2>&1 &
PID=$!

# Wait for RPC
for i in $(seq 1 30); do
  curl -sf "$RPC" -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"net_version","id":1}' | grep -q result && break
  sleep 0.5
done
sleep 2  # let a few blocks seal

rpc() { curl -s "$RPC" -X POST -H 'Content-Type: application/json' --data "$1"; echo; }

PASS=0; FAIL=0
check() {
  local label="$1" result="$2" expect="$3"
  if echo "$result" | grep -Fq "$expect"; then
    echo "  PASS  $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label"
    echo "        got: $(echo "$result" | head -c 200)"
    FAIL=$((FAIL + 1))
  fi
}
check_absent() {
  local label="$1" result="$2" bad="$3"
  if echo "$result" | grep -Fq "$bad"; then
    echo "  FAIL  $label  (found: $bad)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $label"
    PASS=$((PASS + 1))
  fi
}

echo ""
echo "===== MetaMask / wallet RPC compatibility ====="

# --- 1. eth_chainId -----------------------------------------------------------
# MetaMask reads this on connect to identify the network.
R=$(rpc '{"jsonrpc":"2.0","method":"eth_chainId","id":1}')
check "eth_chainId returns 0x343b (13371)" "$R" '"result":"0x343b"'

# --- 2. eth_gasPrice ----------------------------------------------------------
# MetaMask fallback for legacy tx fee display.
R=$(rpc '{"jsonrpc":"2.0","method":"eth_gasPrice","id":1}')
check "eth_gasPrice returns 0x0 (free gas)" "$R" '"result":"0x0"'
check_absent "eth_gasPrice no error" "$R" '"error"'

# --- 3. eth_maxPriorityFeePerGas ----------------------------------------------
# MetaMask EIP-1559 tip estimation. Must exist post-London.
R=$(rpc '{"jsonrpc":"2.0","method":"eth_maxPriorityFeePerGas","id":1}')
check "eth_maxPriorityFeePerGas responds" "$R" '"result"'
check_absent "eth_maxPriorityFeePerGas no error" "$R" '"error"'

# --- 4. eth_feeHistory --------------------------------------------------------
# MetaMask's primary fee model (5 blocks, 25/50/75th reward percentiles).
# Must return baseFeePerGas array of 0x0 on a free-gas chain.
R=$(rpc '{"jsonrpc":"2.0","method":"eth_feeHistory","params":["0x5","latest",[25,50,75]],"id":1}')
check "eth_feeHistory responds" "$R" '"result"'
check_absent "eth_feeHistory no error" "$R" '"error"'
check "eth_feeHistory has baseFeePerGas" "$R" '"baseFeePerGas"'
check "eth_feeHistory baseFeePerGas is zero" "$R" '"0x0"'
check "eth_feeHistory has oldestBlock" "$R" '"oldestBlock"'
check "eth_feeHistory has gasUsedRatio" "$R" '"gasUsedRatio"'

# --- 5. eth_getBlockByNumber --------------------------------------------------
# MetaMask reads the latest block to get baseFeePerGas for fee calculation.
# Pre-London blocks don't have this field, causing MetaMask to display errors.
R=$(rpc '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}')
check "block has baseFeePerGas (London field)" "$R" '"baseFeePerGas":"0x0"'
check "block has withdrawalsRoot (Shanghai field)" "$R" '"withdrawalsRoot"'
check "block has excessBlobGas (Cancun field)" "$R" '"excessBlobGas"'
check_absent "block no error" "$R" '"error"'

# --- 6. eth_blobBaseFee -------------------------------------------------------
# Called unconditionally by newer MetaMask forks and OP Stack tooling.
R=$(rpc '{"jsonrpc":"2.0","method":"eth_blobBaseFee","id":1}')
check "eth_blobBaseFee responds" "$R" '"result"'
check_absent "eth_blobBaseFee no error" "$R" '"error"'

# --- 7. Zero-fee tx via MetaMask-style params (EIP-1559, explicit zero fees) --
# MetaMask builds EIP-1559 txs. On a free-gas chain it must be able to submit
# with maxFeePerGas=0 and maxPriorityFeePerGas=0.
R=$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"$SIGNER\",\"to\":\"$DEST\",\"value\":\"0x1\",\"maxFeePerGas\":\"0x0\",\"maxPriorityFeePerGas\":\"0x0\"}],\"id\":1}")
TXHASH=$(echo "$R" | grep -oE '0x[0-9a-fA-F]{64}' | head -1)
check "zero-fee EIP-1559 tx accepted (has txhash)" "$R" '"result":"0x'
sleep 3
RECEIPT=$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$TXHASH\"],\"id\":1}")
check "zero-fee tx mined (status 0x1)" "$RECEIPT" '"status":"0x1"'
check "effectiveGasPrice is 0x0" "$RECEIPT" '"effectiveGasPrice":"0x0"'

kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null

echo ""
echo "===== RESULT: $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
