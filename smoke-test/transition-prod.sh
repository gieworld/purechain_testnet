#!/usr/bin/env bash
# Rehearsal of the Istanbul -> Cancun in-place upgrade, using representative
# production-like params (chainId 424242, gasLimit 0xffffffffffffff,
# period 1, nonce 0x0ada). All values here are examples — a real deployment
# substitutes its own chainId, signer, and genesis fields.
#
# Phase A: ORIGINAL (baseline) geth + Istanbul-only genesis  -> build the chain.
# Phase B: PATCHED geth + upgraded genesis (same datadir)    -> cross into Cancun.
#
# NOTE: at clique period 1 the miner's pre-Prepare
# timestamp and Clique's post-Prepare header.Time are algebraically identical, so
# the fork-boundary Cancun-field timing bug cannot arise here. The period>=2 case
# (e.g. network/genesis.json uses period 5) is covered by transition.sh.
set -u

ORIG="$1"   # baseline geth-original
PATCHED="$2"
BASE=~/clique-prod-rehearsal
KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SIGNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SIGNER_NO0X=f39Fd6e51aad88F6F4ce6aB8827279cffFb92266
IPC="$BASE/data/geth.ipc"

CHAINID=424242
GASLIMIT=0xffffffffffffff
NONCE=0x0ada
MIXHASH=0x0000000000000000000000000000000000000000000000000000000000000000

rm -rf "$BASE"; mkdir -p "$BASE"
echo "password" > "$BASE/pw.txt"; echo "$KEY" > "$BASE/key.hex"
VANITY=$(printf '0%.0s' $(seq 1 64)); SEAL=$(printf '0%.0s' $(seq 1 130))
EXTRA=0x${VANITY}${SIGNER_NO0X}${SEAL}

common_fields() {  # $1 = extra config lines
cat <<EOF
{
  "config": {
    "chainId": ${CHAINID},
    "homesteadBlock": 0, "eip150Block": 0, "eip155Block": 0, "eip158Block": 0,
    "byzantiumBlock": 0, "constantinopleBlock": 0, "petersburgBlock": 0,
    "istanbulBlock": 0,
${1}
    "clique": { "period": 1, "epoch": 30000 }
  },
  "nonce": "${NONCE}",
  "extraData": "${EXTRA}",
  "gasLimit": "${GASLIMIT}",
  "difficulty": "1",
  "mixHash": "${MIXHASH}",
  "coinbase": "${SIGNER}",
  "alloc": { "${SIGNER_NO0X}": { "balance": "1000000000000000000000000000000" } },
  "number": "0x0", "gasUsed": "0x0",
  "parentHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "baseFeePerGas": null
}
EOF
}

# ---------- PHASE A: original binary + Istanbul-only genesis ----------
common_fields "" > "$BASE/genesis-istanbul.json"
echo "===== PHASE A: ORIGINAL geth, Istanbul genesis ====="
HASH_A=$("$ORIG" --datadir "$BASE/data" init "$BASE/genesis-istanbul.json" 2>&1 | grep -oE 'hash=[0-9a-fx.]+' | head -1)
echo "genesis hash (phase A): $HASH_A"
"$ORIG" --datadir "$BASE/data" account import --password "$BASE/pw.txt" "$BASE/key.hex" >/dev/null 2>&1
"$ORIG" --datadir "$BASE/data" --networkid $CHAINID \
  --unlock "$SIGNER" --password "$BASE/pw.txt" --allow-insecure-unlock \
  --mine --miner.etherbase "$SIGNER" --miner.gaslimit $GASLIMIT \
  --nodiscover --maxpeers 0 --verbosity 3 > "$BASE/a.log" 2>&1 &
P=$!; sleep 6; kill "$P" 2>/dev/null; wait "$P" 2>/dev/null
HEAD_A=$(grep -oE 'Successfully sealed new block +number=[0-9]+' "$BASE/a.log" | grep -oE '[0-9]+$' | tail -1)
echo "phase-A head: ${HEAD_A:-0}   (original binary mined an Istanbul chain)"

# ---------- PHASE B: patched binary + upgraded genesis (same datadir) ----------
FB=$(( ${HEAD_A:-0} + 3 )); NOW=$(date +%s); FT=$((NOW + 8))
EXTRACFG=$(printf '    "berlinBlock": %d, "londonBlock": %d,\n    "shanghaiTime": %d, "cancunTime": %d,\n    "zeroBaseFee": true,\n' "$FB" "$FB" "$FT" "$FT")
common_fields "$EXTRACFG" > "$BASE/genesis-cancun.json"
echo "===== PHASE B: PATCHED geth, upgraded genesis (london@${FB}, forks@+8s) ====="
HASH_B=$("$PATCHED" --datadir "$BASE/data" init "$BASE/genesis-cancun.json" 2>&1 | grep -oE 'hash=[0-9a-fx.]+' | head -1)
echo "genesis hash (phase B): $HASH_B"
"$PATCHED" --datadir "$BASE/data" --networkid $CHAINID \
  --unlock "$SIGNER" --password "$BASE/pw.txt" --allow-insecure-unlock \
  --mine --miner.etherbase "$SIGNER" --miner.gasprice 0 --miner.gaslimit $GASLIMIT \
  --txpool.pricelimit 0 \
  --http --http.addr 127.0.0.1 --http.port 8545 --http.api eth,net,web3 \
  --nodiscover --maxpeers 0 --verbosity 3 > "$BASE/b.log" 2>&1 &
P=$!
for i in $(seq 1 30); do [ -S "$IPC" ] && break; sleep 0.5; done
sleep 18
# send a zero-fee tx via RPC
TX=$(curl -s http://127.0.0.1:8545 -H 'Content-Type: application/json' --data \
  "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"$SIGNER\",\"to\":\"0x0000000000000000000000000000000000000001\",\"value\":\"0x1\",\"gasPrice\":\"0x0\"}],\"id\":1}")
echo "zero-fee tx submit: $TX"
sleep 4
kill "$P" 2>/dev/null; wait "$P" 2>/dev/null

HEAD_B=$(grep -oE 'Successfully sealed new block +number=[0-9]+' "$BASE/b.log" | grep -oE '[0-9]+$' | tail -1)
PANICS=$(grep -c -i panic "$BASE/b.log")
BLOBERR=$(grep -icE 'missing (excessBlobGas|blobGasUsed|parentBeaconRoot)|invalid (excessBlobGas|blobGasUsed|parentBeaconRoot)|nil pointer' "$BASE/b.log")
echo ""
echo "===================== RESULT ====================="
echo "genesis hash A == B : $HASH_A  vs  $HASH_B"
echo "head: A=${HEAD_A:-0} -> B=${HEAD_B:-0}  (london at ${FB}; chain must continue, not reset)"
echo "panics (A,B): $(grep -c -i panic "$BASE/a.log") ${PANICS}   (must be 0)"
echo "cancun-field header errors in b.log: ${BLOBERR}   (must be 0)"
echo "--- tip via RPC (expect baseFeePerGas 0x0, withdrawalsRoot + excessBlobGas present):"
TIPJSON=$("$PATCHED" --datadir "$BASE/data" --networkid $CHAINID --nodiscover --maxpeers 0 --verbosity 1 \
  --exec 'var b=eth.getBlock("latest"); JSON.stringify({number:b.number, baseFeePerGas:b.baseFeePerGas, withdrawalsRoot:b.withdrawalsRoot, excessBlobGas:b.excessBlobGas, gasLimit:b.gasLimit})' console 2>/dev/null | tail -1)
echo "$TIPJSON"

# ---- Verdict ----
FAIL=0
[ "$HASH_A" != "$HASH_B" ] && { echo "FAIL: genesis hash changed (re-genesis, not in-place)"; FAIL=1; }
[ "${PANICS}" != "0" ] && { echo "FAIL: patched node panicked crossing the fork"; FAIL=1; }
[ "${BLOBERR}" != "0" ] && { echo "FAIL: Cancun header field errors around the boundary"; FAIL=1; }
# NB: the console --exec tip is a JSON *string* with escaped quotes (\"excessBlobGas\"),
# so match the bare key (JSON.stringify omits it entirely when the field is undefined).
echo "$TIPJSON" | grep -q 'excessBlobGas' || { echo "FAIL: tip has no excessBlobGas (Cancun not live / malformed head)"; FAIL=1; }
if [ -n "${HEAD_B:-}" ] && [ -n "${HEAD_A:-}" ] && [ "${HEAD_B}" -le "${HEAD_A}" ]; then
  echo "FAIL: chain did not advance past the upgrade"; FAIL=1
fi
if [ "$FAIL" = "0" ]; then echo "PASS: clean in-place Istanbul->Cancun upgrade (period 1)"; fi
exit "$FAIL"
