#!/usr/bin/env bash
# Cancun EVM opcode correctness: TSTORE/TLOAD (EIP-1153 transient storage),
# MCOPY (EIP-5656), BLOBHASH (EIP-4844). push0.sh already covers PUSH0, which is
# *Shanghai*; these are the Cancun-specific opcodes and were previously untested.
#
# Uses eth_call with a state 'code' override, so no deployment or mining is
# needed: the node executes the given runtime bytecode under the chain's Cancun
# rules and returns its output. Pre-Cancun each of these opcodes is INVALID (the
# call reverts / errors and yields no result), so a correct return value is
# itself proof the opcode is live and behaves per spec.
#
# Usage: cancun-opcodes.sh <geth>
set -u

BIN="${1:?usage: cancun-opcodes.sh <geth>}"
BASE=~/clique-opcodes
KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SIGNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SIGNER_NO0X=f39Fd6e51aad88F6F4ce6aB8827279cffFb92266
PORT=8545; RPC="http://127.0.0.1:$PORT"
ADDR=0x00000000000000000000000000000000c0de0001

PASS=0; FAIL=0
rpc(){ curl -s "$RPC" -X POST -H 'Content-Type: application/json' --data "$1"; }
res(){ echo "$1" | grep -oE '"result":"0x[0-9a-f]*"' | grep -oE '0x[0-9a-f]*'; }
# $1=label $2=runtime-hex $3=expected-result
callcheck(){
  local out r
  out=$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$ADDR\",\"data\":\"0x\"},\"latest\",{\"$ADDR\":{\"code\":\"0x$2\"}}],\"id\":1}")
  r=$(res "$out")
  if [ "$r" = "$3" ]; then echo "  PASS  $1 -> $r"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; echo "        want $3  got: $(echo "$out" | head -c 200)"; FAIL=$((FAIL+1)); fi
}

rm -rf "$BASE"; mkdir -p "$BASE"
echo "password" > "$BASE/pw.txt"; echo "$KEY" > "$BASE/key.hex"
VANITY=$(printf '0%.0s' $(seq 1 64)); SEAL=$(printf '0%.0s' $(seq 1 130))
EXTRA=0x${VANITY}${SIGNER_NO0X}${SEAL}

cat > "$BASE/genesis.json" <<EOF
{
  "config": {
    "chainId": 13373,
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
"$BIN" --datadir "$BASE/data" --networkid 13373 \
  --unlock "$SIGNER" --password "$BASE/pw.txt" --allow-insecure-unlock \
  --mine --miner.etherbase "$SIGNER" --miner.gasprice 0 --txpool.pricelimit 0 \
  --http --http.addr 127.0.0.1 --http.port $PORT --http.api eth,net,web3 \
  --nodiscover --maxpeers 0 --verbosity 3 > "$BASE/geth.log" 2>&1 &
PID=$!
for _ in $(seq 1 40); do rpc '{"jsonrpc":"2.0","method":"net_version","id":1}' | grep -q result && break; sleep 0.5; done
sleep 3   # let it seal a couple of Cancun blocks so "latest" is a real Cancun head

echo "--- head is Cancun? ---"
HEAD=$(rpc '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}')
echo "  head number=$(echo "$HEAD" | grep -oE '"number":"0x[0-9a-f]*"') excessBlobGas=$(echo "$HEAD" | grep -oE '"excessBlobGas":"0x[0-9a-f]*"')"

echo "===== opcode checks (eth_call with code override) ====="
Z=0000000000000000000000000000000000000000000000000000000000000000
V2A=000000000000000000000000000000000000000000000000000000000000002a

# TSTORE 0x2a@slot0 ; TLOAD slot0 ; return  -> 0x..2a  (EIP-1153)
callcheck "TSTORE/TLOAD (EIP-1153)" "602a60005d60005c60005260206000f3" "0x$V2A"
# MSTORE 0x2a@0x20 ; MCOPY 32 bytes 0x20->0x00 ; return mem[0..32] -> 0x..2a (EIP-5656)
callcheck "MCOPY (EIP-5656)"        "602a6020526020602060005e60206000f3" "0x$V2A"
# BLOBHASH(index 0) on a non-blob call -> 0 ; return -> 0x..0  (EIP-4844, opcode valid)
callcheck "BLOBHASH (EIP-4844)"     "60004960005260206000f3" "0x$Z"

PANICS=$(grep -c -i 'panic:' "$BASE/geth.log")
[ "$PANICS" -eq 0 ] && { echo "  PASS  zero panics in node log"; PASS=$((PASS+1)); } || { echo "  FAIL  $PANICS panics"; FAIL=$((FAIL+1)); }

kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
echo ""
echo "===== RESULT: $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
