#!/usr/bin/env bash
# Transition test: an EXISTING Istanbul-only Clique chain is upgraded in place
# to Berlin+London+Shanghai+Cancun and must cross the fork without:
#   - changing the genesis hash (same chain, no re-genesis)
#   - reorging/invalidating pre-fork blocks
#   - panicking or producing a block that fails its own Cancun verification
#
# IMPORTANT: this test uses clique period 5 (matching network/genesis.json) and
# a *timestamp-based* cancunTime that is crossed WHILE MINING. That combination
# is what exercises the fork-boundary timing bug: the miner must decide whether
# to add the Cancun header fields (excessBlobGas/blobGasUsed/parentBeaconRoot)
# using the SAME timestamp Clique.Prepare ends up writing (parent.Time+Period),
# not the pre-Prepare wall-clock. A period-1 chain hides the bug because there
# the two timestamps are algebraically identical; period>=2 does not.
set -u

BIN="$1"
BASE=~/clique-transition
KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SIGNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SIGNER_NO0X=f39Fd6e51aad88F6F4ce6aB8827279cffFb92266
PERIOD=5

rm -rf "$BASE"; mkdir -p "$BASE"
echo "password" > "$BASE/pw.txt"
echo "$KEY" > "$BASE/key.hex"
VANITY=$(printf '0%.0s' $(seq 1 64)); SEAL=$(printf '0%.0s' $(seq 1 130))
EXTRA=0x${VANITY}${SIGNER_NO0X}${SEAL}

# ---- PHASE 1: Istanbul-only genesis (like the current network) ----
cat > "$BASE/genesis-istanbul.json" <<EOF
{
  "config": {
    "chainId": 13371,
    "homesteadBlock": 0, "eip150Block": 0, "eip155Block": 0, "eip158Block": 0,
    "byzantiumBlock": 0, "constantinopleBlock": 0, "petersburgBlock": 0,
    "istanbulBlock": 0,
    "clique": { "period": ${PERIOD}, "epoch": 30000 }
  },
  "difficulty": "1", "gasLimit": "30000000", "extradata": "${EXTRA}",
  "alloc": { "${SIGNER_NO0X}": { "balance": "100000000000000000000" } }
}
EOF

echo "===== PHASE 1: init Istanbul-only & mine (period ${PERIOD}) ====="
"$BIN" --datadir "$BASE/data" init "$BASE/genesis-istanbul.json" 2>&1 | grep -i "genesis state" | tee "$BASE/h1.txt"
"$BIN" --datadir "$BASE/data" account import --password "$BASE/pw.txt" "$BASE/key.hex" >/dev/null 2>&1
"$BIN" --datadir "$BASE/data" --networkid 13371 --unlock "$SIGNER" --password "$BASE/pw.txt" \
  --allow-insecure-unlock --mine --miner.etherbase "$SIGNER" --nodiscover --maxpeers 0 \
  --verbosity 3 > "$BASE/p1.log" 2>&1 &
P=$!; sleep 14; kill "$P" 2>/dev/null; wait "$P" 2>/dev/null; sleep 2  # release datadir lock
P1HEAD=$(grep -oE "Successfully sealed new block +number=[0-9]+" "$BASE/p1.log" | grep -oE "[0-9]+$" | tail -1)
echo "phase-1 head block: ${P1HEAD:-0}"

# ---- PHASE 2: same genesis params + FUTURE forks, re-init in place ----
# London activates a couple of blocks ahead (block-based); Shanghai+Cancun
# activate on a wall-clock timestamp that is crossed DURING phase-2 mining.
LONDON=$(( ${P1HEAD:-0} + 2 ))
NOW=$(date +%s); FORKTIME=$((NOW + 20))
cat > "$BASE/genesis-cancun.json" <<EOF
{
  "config": {
    "chainId": 13371,
    "homesteadBlock": 0, "eip150Block": 0, "eip155Block": 0, "eip158Block": 0,
    "byzantiumBlock": 0, "constantinopleBlock": 0, "petersburgBlock": 0,
    "istanbulBlock": 0,
    "berlinBlock": ${LONDON}, "londonBlock": ${LONDON},
    "shanghaiTime": ${FORKTIME}, "cancunTime": ${FORKTIME},
    "clique": { "period": ${PERIOD}, "epoch": 30000 }
  },
  "difficulty": "1", "gasLimit": "30000000", "extradata": "${EXTRA}",
  "alloc": { "${SIGNER_NO0X}": { "balance": "100000000000000000000" } }
}
EOF

echo "===== PHASE 2: re-init in place (london@${LONDON}, shanghai/cancun@+20s), mine across the fork ====="
"$BIN" --datadir "$BASE/data" init "$BASE/genesis-cancun.json" 2>&1 | grep -iE "genesis state|config" | tee "$BASE/h2.txt"

PORT=18547; AP=18548
"$BIN" --datadir "$BASE/data" --networkid 13371 --unlock "$SIGNER" --password "$BASE/pw.txt" \
  --allow-insecure-unlock --mine --miner.etherbase "$SIGNER" --nodiscover --maxpeers 0 \
  --http --http.addr 127.0.0.1 --http.port $PORT --http.api eth,net,web3 --authrpc.port $AP \
  --verbosity 3 > "$BASE/p2.log" 2>&1 &
P=$!
# Mine long enough to cross cancunTime (+20s) AND seal several post-fork blocks
# (at period 5 that needs well over 20s so the parent of a post-fork block is
# itself a Cancun block — the exact spot the pre-fix miner panicked).
sleep 55
# Query the tip over HTTP while the node is still alive (avoids re-opening a second
# geth on the same datadir, which races the lock and can hang on the console).
TIP=$(curl -s "http://127.0.0.1:$PORT" -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' \
  | grep -oE '"number":"[^"]*"|"excessBlobGas":"[^"]*"|"withdrawalsRoot":"[^"]*"' | paste -sd' ')
EXCESS_TIP=$(echo "$TIP" | grep -oE '"excessBlobGas":"[^"]*"')
kill "$P" 2>/dev/null; wait "$P" 2>/dev/null; sleep 2
P2HEAD=$(grep -oE "Successfully sealed new block +number=[0-9]+" "$BASE/p2.log" | grep -oE "[0-9]+$" | tail -1)

# ---- Regression guards for the Cancun fork-boundary timing bug ----
PANICS=$(cat "$BASE/p1.log" "$BASE/p2.log" 2>/dev/null | grep -ic 'panic:')
# The pre-fix miner either panics (nil *parent.ExcessBlobGas on the block after
# the fork) or emits a header that fails Cancun verification. Grep for both.
BLOBERR=$(grep -icE 'missing (excessBlobGas|blobGasUsed|parentBeaconRoot)|invalid (excessBlobGas|blobGasUsed|parentBeaconRoot)|nil pointer' "$BASE/p2.log")

echo ""
echo "===================== RESULT ====================="
echo "genesis hash phase1: $(grep -oE 'hash=[0-9a-fx.]+' "$BASE/h1.txt" | head -1)"
echo "genesis hash phase2: $(grep -oE 'hash=[0-9a-fx.]+' "$BASE/h2.txt" | head -1)   (must match)"
echo "phase-1 head: ${P1HEAD:-0}    phase-2 head: ${P2HEAD:-0}   (phase-2 must be higher; chain continued)"
echo "panics: ${PANICS}   (must be 0)"
echo "cancun-field header errors in p2.log: ${BLOBERR}   (must be 0)"
echo "--- proof Cancun is live at the tip (latest header fields):"
echo "${TIP:-(tip query failed)}"

# ---- Verdict ----
FAIL=0
[ "${PANICS}" != "0" ] && { echo "FAIL: node panicked across the fork"; FAIL=1; }
[ "${BLOBERR}" != "0" ] && { echo "FAIL: Cancun header field errors around the boundary"; FAIL=1; }
[ -z "${EXCESS_TIP}" ] && { echo "FAIL: tip has no excessBlobGas (Cancun not live / malformed head)"; FAIL=1; }
if [ -n "${P2HEAD:-}" ] && [ -n "${P1HEAD:-}" ] && [ "${P2HEAD}" -le "${P1HEAD}" ]; then
  echo "FAIL: chain did not advance past the fork (stalled)"; FAIL=1
fi
if [ "$FAIL" = "0" ]; then echo "PASS: clean Istanbul->Cancun crossing at period ${PERIOD}"; fi
exit "$FAIL"
