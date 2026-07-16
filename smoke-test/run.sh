#!/usr/bin/env bash
# Clique + Cancun smoke test: prove the patched geth mines Cancun blocks
# and the original (baseline) geth cannot.
set -u

BIN="$1"          # path to geth binary to test
LABEL="$2"        # label for output
BASE=~/clique-smoke-$LABEL
KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # Hardhat acct #0
SIGNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SIGNER_NO0X=f39Fd6e51aad88F6F4ce6aB8827279cffFb92266

rm -rf "$BASE"
mkdir -p "$BASE"
echo "password" > "$BASE/pw.txt"
echo "$KEY" > "$BASE/key.hex"

# Build extradata with exact byte counts: 32-byte vanity + 20-byte signer + 65-byte seal.
VANITY=$(printf '0%.0s' $(seq 1 64))
SEAL=$(printf '0%.0s' $(seq 1 130))
EXTRA=0x${VANITY}${SIGNER_NO0X}${SEAL}
echo "extradata length (hex chars, want 234): $(( ${#EXTRA} - 2 ))"

cat > "$BASE/genesis.json" <<EOF
{
  "config": {
    "chainId": 13371,
    "homesteadBlock": 0, "eip150Block": 0, "eip155Block": 0, "eip158Block": 0,
    "byzantiumBlock": 0, "constantinopleBlock": 0, "petersburgBlock": 0,
    "istanbulBlock": 0, "berlinBlock": 0, "londonBlock": 0,
    "shanghaiTime": 0, "cancunTime": 0,
    "clique": { "period": 1, "epoch": 30000 }
  },
  "difficulty": "1",
  "gasLimit": "30000000",
  "extradata": "${EXTRA}",
  "alloc": {
    "${SIGNER_NO0X}": { "balance": "100000000000000000000" },
    "0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02": {
      "balance": "0",
      "code": "0x3373fffffffffffffffffffffffffffffffffffffffe14604d57602036146024575f5ffd5b5f35801560495762001fff810690815414603c575f5ffd5b62001fff01545f5260205ff35b5f5ffd5b62001fff42064281555f359062001fff015500"
    }
  }
}
EOF

echo "===== [$LABEL] geth init ====="
"$BIN" --datadir "$BASE/data" init "$BASE/genesis.json" 2>&1 | tail -2

echo "===== [$LABEL] import signer key ====="
"$BIN" --datadir "$BASE/data" account import --password "$BASE/pw.txt" "$BASE/key.hex" 2>&1 | tail -1

echo "===== [$LABEL] start mining (12s) ====="
"$BIN" --datadir "$BASE/data" \
  --networkid 13371 \
  --unlock "$SIGNER" --password "$BASE/pw.txt" --allow-insecure-unlock \
  --mine --miner.etherbase "$SIGNER" \
  --nodiscover --maxpeers 0 \
  --verbosity 3 \
  > "$BASE/geth.log" 2>&1 &
PID=$!
sleep 12
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

echo "===== [$LABEL] result ====="
echo "--- block-progress / panic / clique-error markers:"
grep -iE "Commit new sealing|mined potential block|Successfully sealed|Imported new|panic|does not support|divide by zero" "$BASE/geth.log" | tail -10
echo "--- last 5 log lines:"
tail -5 "$BASE/geth.log"
