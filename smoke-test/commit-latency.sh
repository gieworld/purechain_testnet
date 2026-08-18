#!/usr/bin/env bash
# COMMIT LATENCY: does lowering --miner.recommit below the block period actually
# reduce inclusion time, and by how much?
#
# Everything else in this suite asks "is it correct". This asks "is it faster",
# because the recommit change was shipped on a mechanism argument alone and never
# benchmarked after the fact.
#
# Method mirrors the external harness that raised the issue: submit transactions
# strictly sequentially, waiting for each receipt before sending the next, and
# measure submit -> receipt. That self-synchronises to just after a block
# boundary, which is the worst case for a miner that freezes block content at the
# start of the period, and is why the reported median sat near two full periods.
#
# Run with ONE signer: every block is then in-turn, no out-of-turn wiggle is
# drawn, and the measurement isolates the recommit effect instead of mixing in
# sealing-order noise.
#
# Sweeps a range of --miner.recommit values rather than testing one, because the
# useful setting is not "as low as possible": every rebuild re-executes the
# pending block, so the cost rises as the interval falls while the latency benefit
# flattens out once the interval is comfortably below the block period. The
# rebuild count is reported alongside the latency so the knee is visible.
#
# Usage: commit-latency.sh <geth> [samples] [values...]
set -u

BIN="${1:?usage: commit-latency.sh <geth> [samples] [values...]}"
SAMPLES="${2:-40}"
shift 2 2>/dev/null || shift $#
VALUES=("$@")
[ ${#VALUES[@]} -eq 0 ] && VALUES=(2s 1s 750ms 500ms 250ms 100ms)

BASE=~/clique-latency
PERIOD=1
P=8845; AP=8851; PP=30603
KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SIGNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SIGNER_NO0X=f39Fd6e51aad88F6F4ce6aB8827279cffFb92266

rpc(){ curl -s -m 10 -X POST -H 'Content-Type: application/json' --data "$1" "http://127.0.0.1:$P"; }
jres(){ printf '%s' "$1" | grep -o '"result":"[^"]*"' | head -1 | sed -E 's/.*:"([^"]*)"/\1/'; }

pkill -f "clique-latency" 2>/dev/null; sleep 1
rm -rf "$BASE"; mkdir -p "$BASE/data"; echo password > "$BASE/pw.txt"; echo "$KEY" > "$BASE/key.hex"
VANITY=$(printf '0%.0s' $(seq 1 64)); SEAL=$(printf '0%.0s' $(seq 1 130))
cat > "$BASE/genesis.json" <<EOF
{
  "config": {
    "chainId": 13399,
    "homesteadBlock":0,"eip150Block":0,"eip155Block":0,"eip158Block":0,
    "byzantiumBlock":0,"constantinopleBlock":0,"petersburgBlock":0,"istanbulBlock":0,
    "berlinBlock":0,"londonBlock":0,"shanghaiTime":0,"cancunTime":0,
    "zeroBaseFee": true,
    "clique": { "period": ${PERIOD}, "epoch": 30000 }
  },
  "difficulty":"1","gasLimit":"0x1c9c380",
  "extradata":"0x${VANITY}${SIGNER_NO0X}${SEAL}",
  "alloc": { "${SIGNER}": { "balance": "0x56bc75e2d63100000" } }
}
EOF
"$BIN" --datadir "$BASE/data" init "$BASE/genesis.json" >/dev/null 2>&1
"$BIN" --datadir "$BASE/data" account import --password "$BASE/pw.txt" "$BASE/key.hex" >/dev/null 2>&1

measure(){ # $1 = recommit value, $2 = label
  local rc="$1" label="$2"
  "$BIN" --datadir "$BASE/data" --networkid 13399 \
    --unlock "$SIGNER" --password "$BASE/pw.txt" --allow-insecure-unlock \
    --mine --miner.etherbase "$SIGNER" --miner.gasprice 0 --txpool.pricelimit 0 \
    --miner.recommit "$rc" \
    --http --http.addr 127.0.0.1 --http.port $P --http.api eth,net,web3,admin,miner \
    --authrpc.port $AP --port $PP --nodiscover --verbosity 3 > "$BASE/$label.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 80); do rpc '{"jsonrpc":"2.0","method":"net_version","id":1}' | grep -q result && break; sleep 0.5; done
  sleep 4   # let sealing settle into a rhythm

  local times=() i t0 t1 txh got
  for i in $(seq 1 "$SAMPLES"); do
    t0=$(date +%s%3N)
    txh=$(jres "$(rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"$SIGNER\",\"to\":\"$SIGNER\",\"value\":\"0x1\",\"gas\":\"0x5208\",\"gasPrice\":\"0x0\"}],\"id\":1}")")
    [ -z "$txh" ] && continue
    got=0
    while :; do
      if rpc "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$txh\"],\"id\":1}" | grep -q '"blockNumber"'; then
        t1=$(date +%s%3N); got=1; break
      fi
      # 50ms poll: fine-grained enough not to dominate the measurement
      sleep 0.05
      [ $(( $(date +%s%3N) - t0 )) -gt 15000 ] && break
    done
    [ "$got" -eq 1 ] && times+=( $(( t1 - t0 )) )
  done

  kill "$pid" 2>/dev/null
  for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true

  # Cost side: every "Commit new sealing work" line is one rebuild of the pending
  # block. Normalised per block so the figure is comparable across runs.
  # Count over a single file with -h so grep never emits per-file "file:count"
  # lines; wc -l keeps the result a single integer even when nothing matches.
  local rebuilds blocks
  rebuilds=$(grep -hc "Commit new sealing work" "$BASE/$label.log" 2>/dev/null | head -1)
  blocks=$(grep -hc "Successfully sealed new block" "$BASE/$label.log" 2>/dev/null | head -1)
  [ -z "$rebuilds" ] && rebuilds=0
  [ -z "$blocks" ] && blocks=0

  local n=${#times[@]}
  if [ "$n" -eq 0 ]; then echo "  $label: NO SAMPLES"; return 1; fi
  local sorted; sorted=$(printf '%s\n' "${times[@]}" | sort -n)
  local med p95 sum=0 perblk="-"
  med=$(printf '%s\n' "$sorted" | awk -v n="$n" 'NR==int((n+1)/2){print}')
  p95=$(printf '%s\n' "$sorted" | awk -v n="$n" 'NR==int(n*0.95+0.5){print}')
  for t in "${times[@]}"; do sum=$((sum+t)); done
  [ "$blocks" -gt 0 ] && perblk=$(awk -v r="$rebuilds" -v b="$blocks" 'BEGIN{printf "%.1f", r/b}')
  printf '  %-8s median=%-7s mean=%-7s p95=%-7s rebuilds/block=%-5s (n=%s)\n' \
    "$1" "${med}ms" "$((sum/n))ms" "${p95}ms" "$perblk" "$n"
  printf '%s' "$med" > "$BASE/median.$label"
}

echo "===== commit latency sweep, 1 signer, period ${PERIOD}s, $SAMPLES sequential txs per value ====="
echo "  (single signer: every block in-turn, no out-of-turn wiggle, so this isolates recommit)"
echo
# A value that yields no samples is a harness failure for the whole sweep, not
# just that value: with a dead baseline the comparison table silently loses its
# reference point while the script would still exit 0.
SWEEP_OK=1
for v in "${VALUES[@]}"; do
  measure "$v" "rc-$v" || SWEEP_OK=0
done

echo
echo "  ---- summary ----"
BASELINE=$(cat "$BASE/median.rc-${VALUES[0]}" 2>/dev/null || echo 0)
BEST=""; BESTV=""
for v in "${VALUES[@]}"; do
  m=$(cat "$BASE/median.rc-$v" 2>/dev/null || echo 0)
  [ "$m" -le 0 ] && continue
  if [ "$BASELINE" -gt 0 ]; then
    printf '  %-8s %-7s  %s\n' "$v" "${m}ms" "$(awk -v a="$BASELINE" -v b="$m" 'BEGIN{d=a-b; printf "%+d ms vs %s (%+.0f%%)", -d, "'"${VALUES[0]}"'", -100.0*d/a}')"
  fi
  if [ -z "$BEST" ] || [ "$m" -lt "$BEST" ]; then BEST="$m"; BESTV="$v"; fi
done
echo
if [ -n "$BESTV" ] && [ "$SWEEP_OK" -eq 1 ]; then
  echo "  lowest median: $BESTV at ${BEST}ms"
  echo "  Pick the largest value that reaches the plateau, not the smallest value overall:"
  echo "  once the interval is well under the period the latency stops improving while"
  echo "  rebuilds/block keeps climbing, and each rebuild re-executes the pending block."
  exit 0
fi
echo "  RESULT: inconclusive (one or more values collected no samples) — benchmark harness failed"
exit 1
