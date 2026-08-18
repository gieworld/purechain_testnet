#!/usr/bin/env bash
# OUT-OF-TURN sealing under a sub-period recommit interval.
#
# Everything else in this suite runs a healthy multi-signer network, where every
# block is sealed by its in-turn signer at difficulty 2 and clique's out-of-turn
# wiggle is never drawn. This test forces the opposite: it stops a signer, so the
# blocks that signer owned must be sealed out-of-turn (difficulty 1) by someone
# else — the only path on which the wiggle exists.
#
# It runs with --miner.recommit BELOW the block period, which is the configuration
# that makes taskLoop interrupt and restart engine.Seal mid-period. Upstream
# clique draws a fresh wiggle on every Seal call, so each restart is another
# chance at a shorter delay, biasing an out-of-turn signer toward publishing early
# and racing the in-turn signer. consensus/clique/wiggle.go keys the draw to
# (parent, number) instead, so re-seals reuse it.
#
# What it proves: that the out-of-turn path is actually exercised (difficulty-1
# blocks exist); that under the risky config the chain keeps real forward
# progress and stays consistent — every node agreeing on every block hash, no
# splits, no panics; and, directly, that a block re-sealed mid-period keeps the
# delay it was first given. That last check reads clique.Seal's Debug log, so it
# needs --verbosity 4, and it is the one that distinguishes the fix from the bug
# rather than merely showing no regression.
#
# Note a chain split is a *probabilistic* consequence of redrawing, so the earlier
# checks can pass on a buggy binary; only the delay-stability check separates
# them. For that reason the delay-stability check is strict: if the Debug line
# never appears (wrong binary, wrong verbosity) or no block was ever re-sealed
# (load generator broken), the script FAILS rather than reporting an
# inconclusive PASS — the preconditions it needs are ones this script itself
# sets up, so their absence is a harness failure, not bad luck.
#
# Usage: out-of-turn.sh <geth> [recommit]
set -u

BIN="${1:?usage: out-of-turn.sh <geth> [recommit]}"
RECOMMIT="${2:-250ms}"
BASE=~/clique-oot
PERIOD=1
SETTLE=12         # seconds mining with all signers up
OUTAGE=40         # seconds mining with one signer stopped

# FOUR signers, not three, and that is load-bearing: clique timestamps are whole
# seconds, so Prepare's late-block bump (header.Time = now) floors to the same
# second for the whole first second past the period boundary. A wiggle drawn
# UNDER 1s therefore completes at the same absolute instant no matter how often
# the block is rebuilt — countdown-reset bugs are invisible. Only a draw >= 1s
# can recede (each second-crossing rebuild pushes the target another second
# out), and draws >= 1s exist only when the span exceeds 1s: 4 signers give
# span (4/2+1)*500ms = 1500ms. At 3 signers (span 1000ms) this test cannot
# detect a countdown-resetting wiggle at all. 4 is also the production shape.
KEYS=(
  ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
  59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
  5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
  7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
)
ADDRS=(
  f39Fd6e51aad88F6F4ce6aB8827279cffFb92266
  70997970C51812dc3A010C7d01b50e0d17dc79C8
  3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
  90F79bf6EB2c4f870365E785982E1f101E93b906
)
N=${#ADDRS[@]}

PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

rpc(){ curl -s -X POST -H 'Content-Type: application/json' --data "$2" "http://127.0.0.1:$1"; }
jget(){ printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | sed -E 's/.*:"([^"]*)"/\1/'; }
head_num(){ printf "%d" "$(jget "$(rpc "$1" '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')" result)" 2>/dev/null || echo 0; }
blk(){ rpc "$1" "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$(printf '0x%x' "$2")\",false],\"id\":1}"; }

pkill -f "clique-oot" 2>/dev/null; sleep 1
rm -rf "$BASE"; mkdir -p "$BASE"; echo password > "$BASE/pw.txt"

VANITY=$(printf '0%.0s' $(seq 1 64)); SEAL=$(printf '0%.0s' $(seq 1 130))
SIGNERS_HEX=$(printf '%s\n' "${ADDRS[@]}" | tr 'A-Z' 'a-z' | sort | tr -d '\n')
EXTRA=0x${VANITY}${SIGNERS_HEX}${SEAL}
ALLOC=""
for a in "${ADDRS[@]}"; do ALLOC="${ALLOC}\"${a}\": { \"balance\": \"0x56bc75e2d63100000\" },"; done
ALLOC=${ALLOC%,}

cat > "$BASE/genesis.json" <<EOF
{
  "config": {
    "chainId": 13377,
    "homesteadBlock":0,"eip150Block":0,"eip155Block":0,"eip158Block":0,
    "byzantiumBlock":0,"constantinopleBlock":0,"petersburgBlock":0,"istanbulBlock":0,
    "berlinBlock":0,"londonBlock":0,
    "shanghaiTime":0,"cancunTime":0,
    "zeroBaseFee": true,
    "clique": { "period": ${PERIOD}, "epoch": 30000 }
  },
  "difficulty": "1", "gasLimit": "30000000", "extradata": "${EXTRA}",
  "alloc": { ${ALLOC} }
}
EOF

echo "===== start $N signers, --miner.recommit $RECOMMIT, period ${PERIOD}s ====="
PIDS=()
for i in $(seq 0 $((N-1))); do
  D="$BASE/n$i"; mkdir -p "$D"; echo "${KEYS[$i]}" > "$D/key.hex"
  "$BIN" --datadir "$D" init "$BASE/genesis.json" >/dev/null 2>&1
  "$BIN" --datadir "$D" account import --password "$BASE/pw.txt" "$D/key.hex" >/dev/null 2>&1
  "$BIN" --datadir "$D" --networkid 13377 \
    --port $((30403+i)) --http --http.addr 127.0.0.1 --http.port $((8645+i)) \
    --http.api eth,net,web3,admin,clique --authrpc.port $((8651+i)) \
    --unlock "0x${ADDRS[$i]}" --password "$BASE/pw.txt" --allow-insecure-unlock \
    --mine --miner.etherbase "0x${ADDRS[$i]}" --miner.gasprice 0 --txpool.pricelimit 0 \
    --miner.recommit "$RECOMMIT" \
    --nodiscover --verbosity 4 > "$D/geth.log" 2>&1 &
  PIDS+=("$!")
done

for i in $(seq 0 $((N-1))); do
  for _ in $(seq 1 60); do
    rpc $((8645+i)) '{"jsonrpc":"2.0","method":"net_version","id":1}' | grep -q result && break
    sleep 0.5
  done
done

# Full mesh.
for i in $(seq 0 $((N-1))); do
  EN=$(jget "$(rpc $((8645+i)) '{"jsonrpc":"2.0","method":"admin_nodeInfo","id":1}')" enode)
  for j in $(seq 0 $((N-1))); do
    [ "$i" = "$j" ] && continue
    rpc $((8645+j)) "{\"jsonrpc\":\"2.0\",\"method\":\"admin_addPeer\",\"params\":[\"$EN\"],\"id\":1}" >/dev/null
  done
done
sleep 3
echo "  peers: $(rpc 8645 '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' | grep -o '"result":"[^"]*"')"

echo "===== settle ${SETTLE}s with all signers up ====="
sleep "$SETTLE"
H_BEFORE=$(head_num 8645)
echo "  head before outage: $H_BEFORE"

# Stop signer 0. Every block whose in-turn signer is index 0 must now be sealed
# out-of-turn (difficulty 1) by signer 1 or 2 -- the wiggle path.
echo "===== stop signer 0 (forces out-of-turn sealing) ====="
kill "${PIDS[0]}" 2>/dev/null
for _ in $(seq 1 20); do kill -0 "${PIDS[0]}" 2>/dev/null || break; sleep 0.5; done
kill -9 "${PIDS[0]}" 2>/dev/null; wait "${PIDS[0]}" 2>/dev/null || true

# Transaction load is REQUIRED for this test to mean anything. newWorkLoop's
# resubmit timer short-circuits when no new transaction has arrived
# (miner/worker.go: "if w.newTxs.Load() == 0 { continue }"), so on an idle chain
# the block is never rebuilt, Seal is never restarted, and the wiggle is drawn
# exactly once whether or not it is cached. Without load this test is vacuous.
echo "===== mine ${OUTAGE}s with $((N-1)) of $N signers, under continuous tx load ====="
# Each surviving node sends from ITS OWN unlocked account — asking a node to
# send from an account it never unlocked just errors out and thins the load.
# Independent senders on every survivor keep every pending block rebuilding,
# which is the condition under which a countdown-resetting wiggle stalls the
# chain — the exact regression the progress check below exists to catch. The
# cadence matters too: the stall mechanism needs at least one rebuild per
# wall-second, so the load must tick faster than 1s (it ticks at ~200ms).
(
  while :; do
    for i in $(seq 1 $((N-1))); do
      rpc $((8645+i)) "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"0x${ADDRS[$i]}\",\"to\":\"0x${ADDRS[0]}\",\"value\":\"0x1\",\"gas\":\"0x5208\",\"gasPrice\":\"0x0\"}],\"id\":1}" >/dev/null 2>&1 || true
    done
    sleep 0.2
  done
) &
LOADPID=$!
sleep "$OUTAGE"
kill "$LOADPID" 2>/dev/null; wait "$LOADPID" 2>/dev/null || true

TXCOUNT=$(cat "$BASE"/n*/geth.log 2>/dev/null | grep -c "Submitted transaction" || true)
echo "  transactions submitted during outage: $TXCOUNT"

MINH=""
for i in $(seq 1 $((N-1))); do
  h=$(head_num $((8645+i)))
  echo "  node$i head=$h"
  [ -z "$MINH" ] || [ "$h" -lt "$MINH" ] && MINH=$h
done

# Collect difficulties on node1; compare every survivor's hash against node1's.
D1=0; D2=0; MISMATCH=0
for n in $(seq 1 "$MINH"); do
  b1=$(blk 8646 "$n")
  d=$(jget "$b1" difficulty); h1=$(jget "$b1" hash)
  [ "$d" = "0x1" ] && D1=$((D1+1))
  [ "$d" = "0x2" ] && D2=$((D2+1))
  for i in $(seq 2 $((N-1))); do
    hi=$(jget "$(blk $((8645+i)) "$n")" hash)
    [ -n "$h1" ] && [ "$h1" != "$hi" ] && { MISMATCH=$((MISMATCH+1)); echo "    block $n: node1=$h1 != node$i=$hi"; }
  done
done
echo "  difficulty 1 (out-of-turn): $D1    difficulty 2 (in-turn): $D2    over $MINH blocks"

echo "===== stop remaining nodes ====="
for p in "${PIDS[@]:1}"; do kill "$p" 2>/dev/null; done
for p in "${PIDS[@]:1}"; do wait "$p" 2>/dev/null || true; done

echo
echo "===================== CHECKS ====================="
[ "$D1" -gt 0 ] \
  && ok "out-of-turn path EXERCISED ($D1 difficulty-1 blocks)" \
  || no "no out-of-turn blocks produced — the wiggle path was never reached, test is inconclusive"
# Real progress, not just "+1": a couple of blocks can land while signer 0 is
# still shutting down, so a strict -gt would pass on a chain that then stalled.
# With period 1s and worst-case wiggle 1.5s, a healthy 3-of-4 network seals
# well over OUTAGE/4 blocks in OUTAGE seconds; a wiggle whose >=1s draws recede
# on every second-crossing rebuild stalls at the first such height and seals
# ~none after that while the tx load runs.
MIN_ADVANCE=$((OUTAGE / 4))
[ "$MINH" -ge $((H_BEFORE + MIN_ADVANCE)) ] \
  && ok "chain kept real progress through the outage ($H_BEFORE -> $MINH, needed +$MIN_ADVANCE)" \
  || no "chain stalled or crawled during the outage ($H_BEFORE -> $MINH, needed +$MIN_ADVANCE) — liveness failure"
[ "$MISMATCH" -eq 0 ] \
  && ok "surviving nodes agree on every block hash (no same-height split)" \
  || no "$MISMATCH block(s) differ between nodes — chain split"
PAN=$(cat "$BASE"/n*/geth.log 2>/dev/null | grep -ci panic || true)
[ "$PAN" -eq 0 ] && ok "zero panics" || no "$PAN panic lines"
FORKS=$(cat "$BASE"/n*/geth.log 2>/dev/null | grep -ci "reorg\|Chain reorg" || true)
echo "  reorg log lines across nodes: $FORKS (informational; compare old vs new binary)"

# --- the direct check: is the out-of-turn delay a property of the block? ---
#
# clique.Seal logs "Out-of-turn signing requested ... number=N parent=0x.. drawn=MS".
# taskLoop restarts Seal on every mid-period rebuild, so a block that was rebuilt
# appears more than once. Upstream redraws per call, so those repeats disagree;
# with the draw keyed to (parent, number) they must all agree.
#
# Requires --verbosity 4 (Debug). STRICT: zero drawn-lines or zero re-sealed
# blocks is a FAIL, not "inconclusive". This script guarantees the
# preconditions itself (recommit < period, continuous two-sender load, a forced
# outage), so if there is nothing to compare, either the binary does not carry
# the instrumented wiggle (old/wrong binary — which must not be reported as
# passing this suite) or the harness is broken. Silently degrading to PASS here
# is how a vacuous test is born.
DRAWS=$(cat "$BASE"/n*/geth.log 2>/dev/null | grep -c "Out-of-turn signing requested" || true)
RESEALED=0; STABLE=0; UNSTABLE=0
for lg in "$BASE"/n*/geth.log; do
  [ -f "$lg" ] || continue
  # one line per seal: "<number>|<parent> <drawn>"
  grep -o 'Out-of-turn signing requested.*' "$lg" 2>/dev/null \
    | sed -E 's/.*number=([0-9]+).*parent=([0-9a-fx.]+).*drawn=([0-9]+).*/\1|\2 \3/' \
    | grep -E '^[0-9]+\|' > "$BASE/seals.$$" || true
  while read -r key vals; do
    n=$(printf '%s\n' "$vals" | wc -w)
    [ "$n" -lt 2 ] && continue          # sealed once: nothing to compare
    RESEALED=$((RESEALED+1))
    if [ "$(printf '%s\n' $vals | sort -u | wc -l)" -eq 1 ]; then
      STABLE=$((STABLE+1))
    else
      UNSTABLE=$((UNSTABLE+1))
      echo "    block $key redrew the delay: $vals"
    fi
  done < <(awk '{a[$1]=a[$1]" "$2} END{for(k in a) print k, a[k]}' "$BASE/seals.$$")
  rm -f "$BASE/seals.$$"
done

if [ "$DRAWS" -eq 0 ]; then
  no "wiggle debug line never appeared (0 'Out-of-turn signing requested' lines) — old/wrong binary or wrong verbosity; this test proves nothing about it"
elif [ "$RESEALED" -eq 0 ]; then
  no "no block was re-sealed ($DRAWS draw lines, all single-seal) — load generator or recommit broken; delay-stability unproven"
elif [ "$UNSTABLE" -eq 0 ]; then
  ok "out-of-turn delay STABLE across re-seals ($STABLE re-sealed blocks, 0 redrew, $DRAWS draw lines)"
else
  no "out-of-turn delay REDRAWN on re-seal ($UNSTABLE of $RESEALED re-sealed blocks) — this is the bug"
fi

echo
echo "===== RESULT: $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
