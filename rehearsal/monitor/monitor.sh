#!/bin/bash
# Rehearsal referee. Every 2s, for all 6 nodes: head number, the hash at
# head-2 (settled — the current head may legitimately differ mid-block), and
# eth_mining. Records everything to /artifacts/monitor.csv and raises alerts
# in /artifacts/alerts.log when settled hashes diverge or a reachable node
# stops advancing. A node being DOWN is recorded but not alerted — the driver
# takes nodes down on purpose; the driver's gates decide what was expected.
set -u
CSV=/artifacts/monitor.csv
ALERTS=/artifacts/alerts.log
NODES="node1 node2 node3 node4 node5 node6"

echo "ts,$(echo $NODES | tr ' ' ','),distinct_settled_hashes,miners" >> "$CSV"

rpc() { # $1=host $2=method $3=params
  curl -sf -m 3 -X POST -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":${3:-[]},\"id\":1}" \
    "http://$1:8545" 2>/dev/null | jq -r '.result // empty' 2>/dev/null
}

LASTMAX=0
STUCK=0
while :; do
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  HEADS=""; MAX=0; MINERS=0
  declare -A H
  for n in $NODES; do
    hn=$(rpc "$n" eth_blockNumber)
    if [ -z "$hn" ]; then H[$n]="down"; HEADS+=",down"; continue; fi
    d=$((16#${hn#0x}))
    H[$n]=$d; HEADS+=",$d"
    [ "$d" -gt "$MAX" ] && MAX=$d
    m=$(rpc "$n" eth_mining)
    [ "$m" = "true" ] && MINERS=$((MINERS+1))
  done
  # settled-hash agreement at MAX-2 across reachable nodes at/above that height
  DIST=0
  if [ "$MAX" -gt 2 ]; then
    CHECK=$((MAX-2)); HX=$(printf '0x%x' "$CHECK"); SEEN=""
    for n in $NODES; do
      [ "${H[$n]}" = "down" ] && continue
      [ "${H[$n]}" -lt "$CHECK" ] && continue
      h=$(rpc "$n" eth_getBlockByNumber "[\"$HX\",false]" | head -c 400)
      hh=$(printf '%s' "$h" | jq -r '.hash // empty' 2>/dev/null)
      [ -z "$hh" ] && hh=$(curl -sf -m 3 -X POST -H 'Content-Type: application/json' \
          --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$HX\",false],\"id\":1}" \
          "http://$n:8545" 2>/dev/null | jq -r '.result.hash // empty')
      [ -n "$hh" ] && SEEN+="$hh"$'\n'
    done
    DIST=$(printf '%s' "$SEEN" | sort -u | grep -c . || true)
    if [ "$DIST" -gt 1 ]; then
      echo "$TS ALERT settled-hash divergence at block $CHECK ($DIST distinct)" | tee -a "$ALERTS"
      printf '%s' "$SEEN" | sort | uniq -c >> "$ALERTS"
    fi
  fi
  # stall detection: only alert when someone is MINING yet the head is frozen
  # (an idle chain standing still is normal under smart-automine)
  if [ "$MAX" -le "$LASTMAX" ] && [ "$MINERS" -gt 0 ]; then
    STUCK=$((STUCK+2))
    [ "$STUCK" -ge 30 ] && { echo "$TS ALERT head frozen ${STUCK}s at $MAX with $MINERS miner(s)" >> "$ALERTS"; STUCK=0; }
  else
    STUCK=0
  fi
  LASTMAX=$MAX
  echo "${TS}${HEADS},${DIST},${MINERS}" >> "$CSV"
  sleep 2
done
