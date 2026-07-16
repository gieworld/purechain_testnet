#!/usr/bin/env bash
# PUSH0 opcode (EIP-3855 / Shanghai) smoke test.
#
# Solidity 0.8.20+ compiles with --evm-version shanghai by default and emits
# PUSH0 (opcode 0x5f) wherever it previously used PUSH1 0x00. On a pre-Shanghai
# node PUSH0 is an invalid opcode and the contract reverts on every call.
#
# This script deploys hand-crafted bytecode that uses PUSH0 for all zero pushes,
# calls it, and asserts the return value is 42. Proves PUSH0 executes correctly
# on the patched Cancun chain.
#
# Bytecode breakdown:
#   Deploy (10 bytes): 6008 600a 5f39 6008 5ff3
#     PUSH1 8       -- runtime code length
#     PUSH1 0x0a    -- offset of runtime code in this bytecode (byte 10)
#     PUSH0         -- memory destination = 0       ← PUSH0
#     CODECOPY      -- mem[0..7] = bytecode[10..17]
#     PUSH1 8       -- return length
#     PUSH0         -- return offset = 0             ← PUSH0
#     RETURN
#
#   Runtime (8 bytes): 602a 5f52 6020 5ff3
#     PUSH1 42      -- value
#     PUSH0         -- MSTORE offset = 0             ← PUSH0
#     MSTORE        -- mem[0..31] = 42
#     PUSH1 32      -- return length
#     PUSH0         -- return offset = 0             ← PUSH0
#     RETURN        -- returns 0x000...2a
set -u

BIN="${1:?Usage: $0 <geth>}"
BASE=~/clique-push0
RPC=http://127.0.0.1:8547
KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SIGNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SIGNER_NO0X=f39Fd6e51aad88F6F4ce6aB8827279cffFb92266

# Deploy bytecode (10 bytes deploy + 8 bytes runtime, four PUSH0 opcodes total)
BYTECODE=0x6008600a5f3960085ff3602a5f5260205ff3

pkill -f "clique-push0" 2>/dev/null; sleep 0.5
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
  --http --http.addr 127.0.0.1 --http.port 8547 --http.api eth,net,web3 \
  --nodiscover --maxpeers 0 --verbosity 3 \
  > "$BASE/geth.log" 2>&1 &
PID=$!

for i in $(seq 1 30); do
  curl -sf "$RPC" -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"net_version","id":1}' | grep -q result && break
  sleep 0.5
done
sleep 1

rpc() { curl -s "$RPC" -X POST -H 'Content-Type: application/json' --data "$1"; echo; }

PASS=0; FAIL=0
check() {
  local label="$1" result="$2" expect="$3"
  if echo "$result" | grep -Fq "$expect"; then
    echo "  PASS  $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label"
    echo "        got: $(echo "$result" | head -c 300)"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "===== PUSH0 (EIP-3855 / Shanghai) ====="

# --- Deploy -------------------------------------------------------------------
echo "--- deploying PUSH0 contract..."
DEPLOY=$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"$SIGNER\",\"gas\":\"0x30000\",\"gasPrice\":\"0x0\",\"data\":\"$BYTECODE\"}],\"id\":1}")
TXHASH=$(echo "$DEPLOY" | grep -oE '0x[0-9a-fA-F]{64}' | head -1)
echo "    deploy tx: ${TXHASH:-(none — check for error below)}"
check "deploy tx accepted" "$DEPLOY" '"result":"0x'

sleep 3

RECEIPT=$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$TXHASH\"],\"id\":1}")
CONTRACT=$(echo "$RECEIPT" | grep -oE '"contractAddress":"0x[0-9a-fA-F]{40}"' | grep -oE '0x[0-9a-fA-F]{40}')
echo "    contract:  ${CONTRACT:-(not found)}"

check "deploy tx mined (status 0x1)" "$RECEIPT" '"status":"0x1"'
check "contractAddress present in receipt" "$RECEIPT" '"contractAddress":"0x'

# --- Call ---------------------------------------------------------------------
# The runtime code ignores calldata and always returns 42 (0x2a) as uint256.
if [ -n "${CONTRACT:-}" ]; then
  CALL=$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$CONTRACT\",\"gasPrice\":\"0x0\"},\"latest\"],\"id\":1}")
  check "eth_call returns 42 (PUSH0 executed correctly)" "$CALL" \
    '"result":"0x000000000000000000000000000000000000000000000000000000000000002a"'

  # --- Verify PUSH0 is in the stored bytecode ---------------------------------
  CODE=$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getCode\",\"params\":[\"$CONTRACT\",\"latest\"],\"id\":1}")
  check "deployed bytecode contains PUSH0 opcode (0x5f)" "$CODE" '5f'
  echo "    stored code: $(echo "$CODE" | grep -oE '"result":"[^"]*"')"
fi

# --- Regression: same call on a pre-Shanghai chain would revert ---------------
# We can't easily spin up a second chain here, so we note the baseline result.
# If eth_call returns "0x" or has an error, PUSH0 was treated as INVALID.
echo ""
echo "    (on a pre-Shanghai Istanbul node this call would return 0x / INVALID opcode)"

kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null

echo ""
echo "===== RESULT: $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
