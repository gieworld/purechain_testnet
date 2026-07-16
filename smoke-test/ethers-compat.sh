#!/usr/bin/env bash
# ethers.js v6 compatibility test.
#
# ethers v6 (and libraries built on it — wagmi, viem) assume London-era support
# as a baseline. On an Istanbul node they fail at the provider layer: getFeeData()
# calls eth_feeHistory which doesn't exist, and populateTransaction() throws when
# baseFeePerGas is absent from blocks.
#
# This script boots a zeroBaseFee + Cancun node, installs ethers v6 in a temp
# directory, and runs a Node.js harness that:
#   1. Connects a JsonRpcProvider and reads network + block.
#   2. Calls getFeeData() (triggers eth_feeHistory + eth_maxPriorityFeePerGas).
#   3. Sends a legacy tx with gasPrice=0n and waits for the receipt.
#   4. Sends an EIP-1559 tx with maxFeePerGas=0n and waits for the receipt.
#
# Requires: node >= 18, npm. Skips gracefully if neither is present.
#
# WSL note: if only Windows node.exe is available (no node inside WSL), the script
# uses it via interop. Because Windows processes don't see WSL's localhost, the
# test geth binds 0.0.0.0 on a unique high port (18549) and node.exe connects to
# the WSL IP directly. Pick a port your real network does not use.
set -u

BIN="${1:?Usage: $0 <geth>}"
BASE=~/clique-ethers
# Unique high port: this test may run node.exe on Windows (WSL interop), which
# connects via Windows localhost. A production node on common ports (8545-8548)
# would otherwise shadow our throwaway test geth. 18549 avoids that collision.
PORT=18549
RPC=http://127.0.0.1:${PORT}
KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SIGNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SIGNER_NO0X=f39Fd6e51aad88F6F4ce6aB8827279cffFb92266
DEST=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

# Prefer native node; fall back to Windows node.exe via WSL interop.
NODE=""
NPM=""
if command -v node >/dev/null 2>&1; then
  NODE=node; NPM=npm
elif command -v node.exe >/dev/null 2>&1 && command -v npm.cmd >/dev/null 2>&1; then
  NODE=node.exe; NPM=npm.cmd
else
  echo "SKIP: node / node.exe not found"; exit 0
fi

pkill -f "clique-ethers" 2>/dev/null; sleep 0.5
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
  --http --http.addr 0.0.0.0 --http.port "$PORT" --http.api eth,net,web3 \
  --nodiscover --maxpeers 0 --verbosity 3 \
  > "$BASE/geth.log" 2>&1 &
PID=$!

for i in $(seq 1 30); do
  curl -sf "$RPC" -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"net_version","id":1}' | grep -q result && break
  sleep 0.5
done
sleep 2

# Install ethers v6 into a throw-away local project.
# When node.exe (Windows interop) is used, the project must live on a Windows-
# native path so that node_modules resolution works correctly. Use TEMP which
# is always accessible as both a WSL and Windows path.
if [ "$NODE" = "node.exe" ]; then
  NPMDIR=$(wslpath "$(cmd.exe /C "echo %TEMP%" 2>/dev/null | tr -d '\r')")/ethers-compat
else
  NPMDIR="$BASE/npm"
fi
mkdir -p "$NPMDIR"
cat > "$NPMDIR/package.json" <<'PKGJSON'
{ "name": "ethers-compat-test", "version": "1.0.0", "dependencies": { "ethers": "^6.0.0" } }
PKGJSON
echo "--- installing ethers v6 (one-time, cached by npm)..."
# npm.cmd is a Windows batch file; WSL interop only executes .exe directly, so it
# must be launched via cmd.exe with a Windows-native working directory.
if [ "$NPM" = "npm.cmd" ]; then
  cmd.exe /C "cd /d $(wslpath -w "$NPMDIR") && npm install --silent" >/dev/null 2>&1
else
  (cd "$NPMDIR" && "$NPM" install --silent 2>/dev/null)
fi

# Verify the install actually produced node_modules/ethers before continuing.
if [ ! -d "$NPMDIR/node_modules/ethers" ]; then
  echo "SKIP: ethers install failed (no node_modules/ethers); check network/npm"
  kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
  exit 0
fi

# Resolve the RPC host the JS will use. Windows node.exe cannot rely on WSL2
# localhost forwarding, so it connects to the WSL IP directly (geth binds 0.0.0.0).
# Native (in-WSL) node uses 127.0.0.1.
if [ "$NODE" = "node.exe" ]; then
  WSLIP=$(hostname -I | awk '{print $1}')
  JS_RPC="http://${WSLIP}:${PORT}"
  echo "--- node.exe will connect to WSL IP: $JS_RPC"
else
  JS_RPC="$RPC"
fi

# Write the Node.js test harness.
# Variable substitution: JS_RPC, KEY, DEST are expanded by bash (no $ in JS code itself).
cat > "$NPMDIR/test.js" <<JSEOF
'use strict';
const { ethers } = require('ethers');

const RPC  = '${JS_RPC}';
const PRIV = '0x${KEY}';
const DEST = '${DEST}';

let pass = 0, fail = 0;

function check(label, actual, expected) {
  let ok;
  if (typeof expected === 'bigint') {
    ok = (actual !== null && actual !== undefined && BigInt(actual) === expected);
  } else {
    ok = (actual === expected);
  }
  if (ok) {
    console.log('  PASS ', label);
    pass++;
  } else {
    console.log('  FAIL ', label);
    console.log('        got:', String(actual), '  expected:', String(expected));
    fail++;
  }
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const wallet   = new ethers.Wallet(PRIV, provider);

  // 1. Network detection — provider must connect and identify the chain
  const network = await provider.getNetwork();
  check('chainId = 13371', Number(network.chainId), 13371);

  // 2. Block — baseFeePerGas must exist (proves London) and be 0 (free gas)
  const block = await provider.getBlock('latest');
  check('block.baseFeePerGas exists', block.baseFeePerGas !== null && block.baseFeePerGas !== undefined, true);
  check('block.baseFeePerGas = 0n (free gas)', block.baseFeePerGas, 0n);

  // 3. getFeeData — internally calls eth_feeHistory + eth_maxPriorityFeePerGas.
  //    On an Istanbul node this throws because eth_feeHistory does not exist;
  //    the fact that it returns at all is the core compatibility win.
  const fee = await provider.getFeeData();
  check('getFeeData() succeeds (eth_feeHistory available)', fee !== null, true);
  check('feeData.gasPrice = 0n', fee.gasPrice, 0n);
  // Known ethers v6 quirk: getFeeData() gates EIP-1559 fees behind a truthiness
  // check on baseFeePerGas (it tests "if (block.baseFeePerGas)"), and 0n is falsy.
  // So on a zero-basefee chain ethers leaves maxFeePerGas/maxPriorityFeePerGas null
  // and dapps fall back to the legacy gasPrice (0n) path — which works. We assert
  // the null here so the behavior is pinned and documented rather than surprising.
  check('feeData.maxFeePerGas null on zero-basefee (ethers treats 0 as non-1559)', fee.maxFeePerGas, null);
  check('feeData.maxPriorityFeePerGas null on zero-basefee (same reason)', fee.maxPriorityFeePerGas, null);

  // 4. Legacy tx (type 0) with gasPrice=0n
  //    On Istanbul, this step would fail because the node expects gasPrice >= 1.
  const tx1 = await wallet.sendTransaction({
    to: DEST, value: 1n, gasPrice: 0n, type: 0
  });
  const r1 = await tx1.wait(1);
  check('legacy tx mined (status=1)', r1.status, 1);
  check('legacy tx effectiveGasPrice = 0n', r1.gasPrice, 0n);

  // 5. EIP-1559 tx (type 2) with maxFeePerGas=0n
  //    On Istanbul, type-2 txs don't exist at all.
  const tx2 = await wallet.sendTransaction({
    to: DEST, value: 1n, maxFeePerGas: 0n, maxPriorityFeePerGas: 0n
  });
  const r2 = await tx2.wait(1);
  check('EIP-1559 tx mined (status=1)', r2.status, 1);
  check('EIP-1559 tx effectiveGasPrice = 0n', r2.gasPrice, 0n);

  console.log('');
  console.log('===== RESULT:', pass, 'passed,', fail, 'failed =====');
  process.exit(fail > 0 ? 1 : 0);
}

main().catch(e => {
  console.error('FATAL:', e.message);
  process.exit(1);
});
JSEOF

echo ""
echo "===== ethers.js v6 compatibility ====="
if [ "$NODE" = "node.exe" ]; then
  "$NODE" "$(wslpath -w "$NPMDIR/test.js")"
else
  "$NODE" "$NPMDIR/test.js"
fi
EXIT=$?

kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
exit $EXIT
