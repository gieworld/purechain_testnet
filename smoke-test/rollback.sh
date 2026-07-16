#!/usr/bin/env bash
# ROLLBACK test: can you go BACK from the patched Cancun binary to STOCK geth?
#
# Answer depends entirely on whether the chain has crossed shanghaiTime/cancunTime.
#
#   TEST 1  Rollback BEFORE any fork activates (forks scheduled far in the future).
#           Expect: SAFE. Stock geth reads the datadir the patched binary wrote,
#           keeps mining pre-fork blocks, no panic, state + block hashes intact.
#
#   TEST 2  Rollback AFTER the chain has produced Cancun blocks.
#           Expect: BLOCKED. Stock geth panics / cannot follow. The only recovery
#           is restoring the pre-upgrade datadir backup (which we then demonstrate).
#
# Usage: rollback.sh <geth-original> <geth-patched>
set -u

ORIG="${1:?Usage: $0 <geth-original> <geth-patched>}"
PATCHED="${2:?Usage: $0 <geth-original> <geth-patched>}"

BASE=~/clique-rollback
PORT=18571; AP=18581; PP=30471
KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SIGNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SIGNER_NO0X=f39Fd6e51aad88F6F4ce6aB8827279cffFb92266

pkill -f "clique-rollback" 2>/dev/null; sleep 1
rm -rf "$BASE"; mkdir -p "$BASE"
echo "password" > "$BASE/pw.txt"; echo "$KEY" > "$BASE/key.hex"
VANITY=$(printf '0%.0s' $(seq 1 64)); SEAL=$(printf '0%.0s' $(seq 1 130))
EXTRA=0x${VANITY}${SIGNER_NO0X}${SEAL}

PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $1"; [ $# -gt 1 ] && echo "        $2"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "have=[$2] want=[$3]"; fi; }
rpc() { curl -s "http://127.0.0.1:$PORT" -X POST -H 'Content-Type: application/json' --data "$1"; }
res() { echo "$1" | sed -E 's/.*"result":("[^"]*"|[0-9]+|null).*/\1/' | tr -d '"'; }
wait_rpc(){ for i in $(seq 1 40); do rpc '{"jsonrpc":"2.0","method":"net_version","id":1}' | grep -q result && return 0; sleep 0.5; done; return 1; }
head_num(){ printf '%d' "$(res "$(rpc '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}')")" 2>/dev/null || echo 0; }
blk_hash(){ rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$1\",false],\"id\":1}" | sed -E 's/.*"hash":"([^"]*)".*/\1/'; }

stop_node(){  # $1=pid — terminate and wait for the datadir lock to release
  kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; sleep 2
}
start_node(){  # $1=binary $2=datadir $3=logfile $4=mine(1/0)
  local mineflags=""
  [ "$4" = "1" ] && mineflags="--unlock $SIGNER --password $BASE/pw.txt --allow-insecure-unlock --mine --miner.etherbase $SIGNER --miner.gasprice 0 --txpool.pricelimit 0"
  "$1" --datadir "$2" --networkid 13371 $mineflags \
    --http --http.addr 127.0.0.1 --http.port $PORT --http.api eth,net,web3 \
    --authrpc.port $AP --port $PP --nodiscover --maxpeers 0 --verbosity 2 > "$3" 2>&1 &
  echo $!
}

istanbul_genesis(){ cat > "$1" <<EOF
{
  "config": {
    "chainId": 13371,
    "homesteadBlock": 0, "eip150Block": 0, "eip155Block": 0, "eip158Block": 0,
    "byzantiumBlock": 0, "constantinopleBlock": 0, "petersburgBlock": 0,
    "istanbulBlock": 0,
    "clique": { "period": 1, "epoch": 30000 }
  },
  "difficulty": "1", "gasLimit": "30000000", "extradata": "${EXTRA}",
  "alloc": { "${SIGNER_NO0X}": { "balance": "100000000000000000000" } }
}
EOF
}
cancun_genesis(){  # $1=path $2=londonBlock $3=forkTime
cat > "$1" <<EOF
{
  "config": {
    "chainId": 13371,
    "homesteadBlock": 0, "eip150Block": 0, "eip155Block": 0, "eip158Block": 0,
    "byzantiumBlock": 0, "constantinopleBlock": 0, "petersburgBlock": 0,
    "istanbulBlock": 0,
    "berlinBlock": ${2}, "londonBlock": ${2},
    "shanghaiTime": ${3}, "cancunTime": ${3},
    "zeroBaseFee": true,
    "clique": { "period": 1, "epoch": 30000 }
  },
  "difficulty": "1", "gasLimit": "30000000", "extradata": "${EXTRA}",
  "alloc": { "${SIGNER_NO0X}": { "balance": "100000000000000000000" } }
}
EOF
}

# ===========================================================================
echo "############################################################"
echo "# TEST 1 — rollback BEFORE activation (forks far in future)"
echo "############################################################"
D="$BASE/pre"; mkdir -p "$D"
istanbul_genesis "$BASE/g-ist.json"
"$ORIG" --datadir "$D" init "$BASE/g-ist.json" >/dev/null 2>&1
"$ORIG" --datadir "$D" account import --password "$BASE/pw.txt" "$BASE/key.hex" >/dev/null 2>&1

# stock builds an Istanbul chain
PID=$(start_node "$ORIG" "$D" "$D/1-stock.log" 1); wait_rpc || { echo FATAL; exit 1; }
sleep 5; H_STOCK=$(head_num); HASH_STOCK=$(blk_hash "latest")
stop_node $PID
echo "stock built Istanbul chain to head=$H_STOCK"

# back up the datadir at this point (the safe rollback artifact)
cp -r "$D" "$BASE/pre.bak"

# upgrade: re-init with forks FAR in the future, then run patched a while
cancun_genesis "$BASE/g-future.json" 100000 $(( $(date +%s) + 99999 ))
G_RE=$("$PATCHED" --datadir "$D" init "$BASE/g-future.json" 2>&1 | grep -oE 'hash=[0-9a-fx.]+' | head -1)
PID=$(start_node "$PATCHED" "$D" "$D/2-patched.log" 1); wait_rpc || { echo FATAL; exit 1; }
sleep 5; H_PATCHED=$(head_num)
stop_node $PID
echo "patched ran (still pre-fork) to head=$H_PATCHED"
[ "$H_PATCHED" -gt "$H_STOCK" ] && ok "patched binary continued the stock chain" || bad "patched did not advance"

# NOW ROLL BACK to stock geth on the same datadir
PID=$(start_node "$ORIG" "$D" "$D/3-rollback.log" 1)
if wait_rpc; then
  sleep 5; H_RB=$(head_num)
  PANIC=$(grep -c -i panic "$D/3-rollback.log")
  HASH_RB_AT_STOCK=$(blk_hash "0x$(printf %x $H_STOCK)")
  stop_node $PID
  eq "stock geth STARTS after running patched (pre-fork)" "$PANIC" "0"
  [ "$H_RB" -gt "$H_PATCHED" ] && ok "stock geth keeps MINING after rollback (head $H_PATCHED->$H_RB)" || bad "stock geth did not advance after rollback" "head=$H_RB"
  eq "pre-fork block #$H_STOCK hash unchanged after rollback" "$HASH_RB_AT_STOCK" "$HASH_STOCK"
  echo "  VERDICT: rollback BEFORE activation is SAFE."
else
  stop_node $PID
  bad "stock geth failed to start after rollback (pre-fork)" "$(tail -3 "$D/3-rollback.log")"
fi

# ===========================================================================
echo "############################################################"
echo "# TEST 2 — rollback AFTER Cancun blocks exist"
echo "############################################################"
D="$BASE/post"; mkdir -p "$D"
"$ORIG" --datadir "$D" init "$BASE/g-ist.json" >/dev/null 2>&1
"$ORIG" --datadir "$D" account import --password "$BASE/pw.txt" "$BASE/key.hex" >/dev/null 2>&1
PID=$(start_node "$ORIG" "$D" "$D/1-stock.log" 1); wait_rpc || { echo FATAL; exit 1; }
sleep 4; H0=$(head_num)
stop_node $PID
cp -r "$D" "$BASE/post.bak"     # pre-upgrade backup (the recovery artifact)

# upgrade with NEAR forks and cross into Cancun
FT=$(( $(date +%s) + 8 ))
cancun_genesis "$BASE/g-near.json" $(( H0 + 3 )) $FT
"$PATCHED" --datadir "$D" init "$BASE/g-near.json" >/dev/null 2>&1
PID=$(start_node "$PATCHED" "$D" "$D/2-patched.log" 1); wait_rpc || { echo FATAL; exit 1; }
for i in $(seq 1 30); do [ "$(date +%s)" -gt "$FT" ] && [ "$(head_num)" -gt "$(( H0 + 3 ))" ] && break; sleep 1; done
sleep 3
LATEST=$(rpc '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}')
H_CANCUN=$(head_num)
stop_node $PID
echo "$LATEST" | grep -q '"excessBlobGas"' && ok "chain crossed into Cancun (head=$H_CANCUN, excessBlobGas present)" || bad "chain did not reach Cancun"

# ATTEMPT rollback to stock on the Cancun datadir
PID=$(start_node "$ORIG" "$D" "$D/3-rollback.log" 1)
sleep 8
stop_node $PID
if grep -qiE "panic|does not support|unexpected (withdrawal|excess blob)" "$D/3-rollback.log"; then
  ok "stock geth REFUSES the Cancun chain (rollback blocked, as expected)"
  echo "        -> $(grep -iE 'panic|does not support|unexpected (withdrawal|excess blob)' "$D/3-rollback.log" | head -1 | cut -c1-88)"
else
  H_RB2=$(head_num 2>/dev/null || echo n/a)
  bad "stock geth did NOT clearly reject the Cancun chain" "head=$H_RB2; inspect $D/3-rollback.log"
fi

# DEMONSTRATE the supported recovery: restore the pre-upgrade backup + stock binary
rm -rf "$D"; cp -r "$BASE/post.bak" "$D"
PID=$(start_node "$ORIG" "$D" "$D/4-restore.log" 1)
if wait_rpc; then
  sleep 4; H_RESTORE=$(head_num); PANIC=$(grep -c -i panic "$D/4-restore.log")
  stop_node $PID
  eq "RECOVERY: restoring pre-upgrade backup runs on stock geth (no panic)" "$PANIC" "0"
  [ "$H_RESTORE" -ge "$H0" ] && ok "RECOVERY: restored chain mines again on stock (head>=$H0)" || bad "restored chain stuck" "head=$H_RESTORE"
  echo "  VERDICT: rollback AFTER activation requires restoring a pre-upgrade backup"
  echo "           (or rewinding past the fork on every node) — NOT a simple binary swap."
else
  stop_node $PID
  bad "restore from backup failed to start" "$(tail -3 "$D/4-restore.log")"
fi

pkill -f "clique-rollback" 2>/dev/null
echo ""
echo "================== RESULT: $PASS passed, $FAIL failed =================="
[ "$FAIL" -eq 0 ]
