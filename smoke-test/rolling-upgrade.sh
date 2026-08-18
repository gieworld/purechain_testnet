#!/usr/bin/env bash
# ROLLING UPGRADE of a live multi-signer network, one node at a time, under load.
#
# This is the production-shaped rehearsal: the other upgrade tests each cover a
# piece (inplace-upgrade.sh = one node's datadir, mixed-version.sh = two nodes on
# different builds), but neither runs a whole signer set through an upgrade while
# the chain keeps producing blocks and accepting transactions.
#
# Clique constraint this exercises: a signer that sealed may not seal again for
# limit = len(signers)/2 + 1 blocks, so the chain needs at least that many signers
# online. With 4 signers limit is 3, meaning exactly ONE node may be down at a
# time. Taking two down stalls the chain. The rolling procedure below is therefore
# not a preference, it is the only safe order.
#
# Phases:
#   1  whole network on the OLD build, settle, record state
#   2  for each signer: stop -> chain must keep advancing on the remainder ->
#      restart on the NEW build against the SAME datadir -> must rejoin and agree
#   3  whole network on NEW: healthy, consistent, still mining transactions
#   4  roll ONE node back to OLD and confirm it rejoins — the abort path, in case
#      an upgrade looks wrong halfway through
#
# Every phase runs under continuous transaction load, which matters: the miner
# only rebuilds a pending block when a transaction has arrived, so an idle chain
# exercises far less of the sealing path.
#
# Usage: rolling-upgrade.sh <geth-old> <geth-new> [nsigners]
set -u

OLD="${1:?usage: rolling-upgrade.sh <geth-old> <geth-new> [nsigners]}"
NEW="${2:?usage: rolling-upgrade.sh <geth-old> <geth-new> [nsigners]}"
NSIG="${3:-4}"

BASE=~/clique-rolling
PERIOD=1
SETTLE=14
STEP_WAIT=14      # seconds to observe after each node action
RECOMMIT=250ms

KEYS=(
  ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
  59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
  5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
  7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
  47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
)
ADDRS=(
  f39Fd6e51aad88F6F4ce6aB8827279cffFb92266
  70997970C51812dc3A010C7d01b50e0d17dc79C8
  3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
  90F79bf6EB2c4f870365E785982E1f101E93b906
  15d34AAf54267DB7D7c367839AAf71A00a2C6A65
)
[ "$NSIG" -gt "${#ADDRS[@]}" ] && { echo "max ${#ADDRS[@]} signers"; exit 1; }
LIMIT=$(( NSIG/2 + 1 ))

PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

P0=8745; PP0=30503; AP0=8751
rpc(){ curl -s -m 5 -X POST -H 'Content-Type: application/json' --data "$2" "http://127.0.0.1:$1"; }
jget(){ printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | sed -E 's/.*:"([^"]*)"/\1/'; }
head_of(){ printf "%d" "$(jget "$(rpc $((P0+$1)) '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')" result)" 2>/dev/null || echo 0; }
hash_at(){ jget "$(rpc $((P0+$1)) "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$(printf '0x%x' "$2")\",false],\"id\":1}")" hash; }
alive(){ rpc $((P0+$1)) '{"jsonrpc":"2.0","method":"net_version","id":1}' | grep -q result; }

declare -a PIDS BINOF
start_node(){ # $1=index $2=binary
  local i=$1 bin=$2 D="$BASE/n$i"
  "$bin" --datadir "$D" --networkid 13388 \
    --port $((PP0+i)) --http --http.addr 127.0.0.1 --http.port $((P0+i)) \
    --http.api eth,net,web3,admin,clique,miner --authrpc.port $((AP0+i)) \
    --unlock "0x${ADDRS[$i]}" --password "$BASE/pw.txt" --allow-insecure-unlock \
    --mine --miner.etherbase "0x${ADDRS[$i]}" --miner.gasprice 0 --txpool.pricelimit 0 \
    --miner.recommit "$RECOMMIT" \
    --nodiscover --verbosity 3 >> "$D/geth.log" 2>&1 &
  PIDS[$i]=$!; BINOF[$i]="$bin"
  for _ in $(seq 1 80); do alive "$i" && return 0; sleep 0.5; done
  return 1
}
stop_node(){ # $1=index
  local i=$1 p=${PIDS[$i]}
  kill "$p" 2>/dev/null
  for _ in $(seq 1 30); do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
  kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null || true
}
mesh(){ # re-announce every peer to every other (cheap, idempotent)
  local i j en
  for i in $(seq 0 $((NSIG-1))); do
    alive "$i" || continue
    en=$(jget "$(rpc $((P0+i)) '{"jsonrpc":"2.0","method":"admin_nodeInfo","id":1}')" enode)
    [ -z "$en" ] && continue
    for j in $(seq 0 $((NSIG-1))); do
      [ "$i" = "$j" ] && continue
      alive "$j" || continue
      rpc $((P0+j)) "{\"jsonrpc\":\"2.0\",\"method\":\"admin_addPeer\",\"params\":[\"$en\"],\"id\":1}" >/dev/null
    done
  done
}
# Agreement across every live node at a height they all have.
agree(){ # $1=label
  local h=999999999 i n hh bad=0 live=0
  local ref=""
  for i in $(seq 0 $((NSIG-1))); do
    alive "$i" || continue
    live=$((live+1)); n=$(head_of "$i"); [ "$n" -lt "$h" ] && h=$n
  done
  if [ "$live" -lt 2 ]; then
    echo "    (only $live node live; agreement not meaningful)"
    return 0
  fi
  h=$(( h > 2 ? h-2 : 1 ))   # step back to a height everyone has settled
  for i in $(seq 0 $((NSIG-1))); do
    alive "$i" || continue
    hh=$(hash_at "$i" "$h")
    [ -z "$hh" ] && continue
    if [ -z "$ref" ]; then
      ref="$hh"
    elif [ "$hh" != "$ref" ]; then
      bad=$((bad+1)); echo "    node$i block $h: $hh != $ref"
    fi
  done
  if [ -z "$ref" ]; then
    no "$1: no node returned block $h"
  elif [ "$bad" -eq 0 ]; then
    ok "$1: all $live live nodes agree on block $h"
  else
    no "$1: $bad node(s) disagree at block $h"
  fi
}

pkill -f "clique-rolling" 2>/dev/null; sleep 1
rm -rf "$BASE"; mkdir -p "$BASE"; echo password > "$BASE/pw.txt"

VANITY=$(printf '0%.0s' $(seq 1 64)); SEAL=$(printf '0%.0s' $(seq 1 130))
SIGNERS_HEX=$(printf '%s\n' "${ADDRS[@]:0:$NSIG}" | tr 'A-Z' 'a-z' | sort | tr -d '\n')
ALLOC=""; for a in "${ADDRS[@]:0:$NSIG}"; do ALLOC="${ALLOC}\"${a}\": { \"balance\": \"0x56bc75e2d63100000\" },"; done
cat > "$BASE/genesis.json" <<EOF
{
  "config": {
    "chainId": 13388,
    "homesteadBlock":0,"eip150Block":0,"eip155Block":0,"eip158Block":0,
    "byzantiumBlock":0,"constantinopleBlock":0,"petersburgBlock":0,"istanbulBlock":0,
    "berlinBlock":0,"londonBlock":0,"shanghaiTime":0,"cancunTime":0,
    "zeroBaseFee": true,
    "clique": { "period": ${PERIOD}, "epoch": 30000 }
  },
  "difficulty": "1", "gasLimit": "30000000",
  "extradata": "0x${VANITY}${SIGNERS_HEX}${SEAL}",
  "alloc": { ${ALLOC%,} }
}
EOF

echo "############################################################"
echo "# PHASE 1 - $NSIG signers on the OLD build (limit=$LIMIT, so $((NSIG-LIMIT)) may be down at once)"
echo "############################################################"
for i in $(seq 0 $((NSIG-1))); do
  D="$BASE/n$i"; mkdir -p "$D"; echo "${KEYS[$i]}" > "$D/key.hex"
  "$OLD" --datadir "$D" init "$BASE/genesis.json" >/dev/null 2>&1
  "$OLD" --datadir "$D" account import --password "$BASE/pw.txt" "$D/key.hex" >/dev/null 2>&1
  start_node "$i" "$OLD" || { no "node$i failed to start on OLD"; exit 1; }
done
mesh; sleep 2

# Continuous transaction load for the whole run.
(
  while :; do
    for i in $(seq 0 $((NSIG-1))); do
      rpc $((P0+i)) "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"0x${ADDRS[$i]}\",\"to\":\"0x${ADDRS[0]}\",\"value\":\"0x1\",\"gas\":\"0x5208\",\"gasPrice\":\"0x0\"}],\"id\":1}" >/dev/null 2>&1 || true
    done
    sleep 0.3
  done
) & LOADPID=$!
trap 'kill $LOADPID 2>/dev/null' EXIT

sleep "$SETTLE"
H_START=$(head_of 0)
echo "  head after settle: $H_START"
[ "$H_START" -ge 5 ] && ok "network producing on OLD build (head=$H_START)" || no "network not producing (head=$H_START)"
agree "phase 1"

echo
echo "############################################################"
echo "# PHASE 2 - roll each signer onto the NEW build, one at a time"
echo "############################################################"
for i in $(seq 0 $((NSIG-1))); do
  echo "----- upgrading node$i -----"
  stop_node "$i"
  # Baseline AFTER the stop completes: geth shuts down gracefully over a few
  # seconds, and blocks sealed during that window must not count as "survived
  # the outage". Nor is +1 block survival — a chain about to stall typically
  # lands a block or two before the recently-signed rule bites. Demand steady
  # progress across the whole observation window instead (period 1s, worst-case
  # wiggle ~1.5s -> a healthy remainder seals well over STEP_WAIT/3 blocks).
  OTHER=$(( i == 0 ? 1 : 0 ))
  H_BEFORE=$(head_of "$OTHER")
  sleep "$STEP_WAIT"
  H_DURING=$(head_of "$OTHER")
  MIN_ADV=$(( STEP_WAIT / 3 ))
  [ "$H_DURING" -ge $(( H_BEFORE + MIN_ADV )) ] \
    && ok "node$i down: chain kept real progress ($H_BEFORE -> $H_DURING, needed +$MIN_ADV)" \
    || no "node$i down: chain STALLED or crawled ($H_BEFORE -> $H_DURING, needed +$MIN_ADV; need >= $LIMIT signers online)"

  start_node "$i" "$NEW" || { no "node$i failed to restart on NEW build"; continue; }
  mesh; sleep "$STEP_WAIT"
  H_AFTER=$(head_of "$i"); H_PEER=$(head_of "$OTHER")
  # Rejoined if within a few blocks of a peer.
  DIFF=$(( H_PEER - H_AFTER )); [ "$DIFF" -lt 0 ] && DIFF=$(( -DIFF ))
  [ "$DIFF" -le 3 ] \
    && ok "node$i rejoined on NEW build (head $H_AFTER vs peer $H_PEER)" \
    || no "node$i did not catch up (head $H_AFTER vs peer $H_PEER)"
  agree "after upgrading node$i"
done

echo
echo "############################################################"
echo "# PHASE 3 - whole network on the NEW build"
echo "############################################################"
sleep "$STEP_WAIT"
H_END=$(head_of 0)
[ "$H_END" -gt "$H_START" ] && ok "chain advanced across the whole upgrade ($H_START -> $H_END)" \
                            || no "chain did not advance ($H_START -> $H_END)"
agree "phase 3"
MINED=$(cat "$BASE"/n*/geth.log 2>/dev/null | grep -c "Submitted transaction" || true)
[ "$MINED" -gt 0 ] && ok "transactions accepted throughout ($MINED submissions logged)" \
                   || no "no transactions were submitted — load generator failed, sealing path under-exercised"

echo
echo "############################################################"
echo "# PHASE 4 - roll node0 BACK to the OLD build (abort path)"
echo "############################################################"
H_B4=$(head_of 1)
stop_node 0
start_node 0 "$OLD" || no "node0 failed to restart on OLD build (downgrade broken)"
mesh; sleep "$STEP_WAIT"
H_RB=$(head_of 0); H_P=$(head_of 1)
DIFF=$(( H_P - H_RB )); [ "$DIFF" -lt 0 ] && DIFF=$(( -DIFF ))
[ "$DIFF" -le 3 ] && ok "node0 rejoined after downgrade (head $H_RB vs peer $H_P)" \
                  || no "node0 failed to rejoin after downgrade ($H_RB vs $H_P)"
[ "$H_P" -gt "$H_B4" ] && ok "chain kept advancing through the downgrade" \
                       || no "chain stalled during downgrade"
agree "phase 4 (mixed old/new)"

kill "$LOADPID" 2>/dev/null || true
for i in $(seq 0 $((NSIG-1))); do alive "$i" && stop_node "$i"; done

PAN=$(cat "$BASE"/n*/geth.log 2>/dev/null | grep -ci "panic" || true)
[ "$PAN" -eq 0 ] && ok "zero panics across every node and every phase" || no "$PAN panic lines"
BAD=$(cat "$BASE"/n*/geth.log 2>/dev/null | grep -ci "BAD BLOCK\|invalid merkle root\|missing withdrawals" || true)
if [ "$BAD" -eq 0 ]; then
  ok "no BAD BLOCK / invalid-root / missing-withdrawals errors"
else
  no "$BAD block-validity errors"
  # Evidence, not just a count: show which node said what, or this is
  # undebuggable once the environment is torn down.
  grep -in "BAD BLOCK\|invalid merkle root\|missing withdrawals" "$BASE"/n*/geth.log 2>/dev/null | head -10 | sed 's/^/        /'
fi

echo
echo "===== RESULT: $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
