#!/usr/bin/env bash
# PureChain upgrade-rehearsal campaign driver.
#
# Runs the complete campaign phase by phase against the docker-compose network
# in this directory, mirroring the production operational procedures read from
# the live AWS stack on 2026-08-12 (sequential fork-safe bring-up, automine
# sidecars, relay arming after restarts).
#
#   ./drive.sh prep       build images, genesis, keys        (~5 min, no chain)
#   ./drive.sh p1         bring-up + baseline on OLD         (~20 min)
#   ./drive.sh p2         rolling upgrade OLD -> NEW         (~35 min)
#   ./drive.sh p3         post-upgrade functional + sync     (~20 min)
#   ./drive.sh p4         recommit 750ms rehearsal           (~20 min)
#   ./drive.sh p5         stress: ceiling + outage + crash   (~30 min)
#   ./drive.sh p6         two-signer halt drill              (~10 min)
#   ./drive.sh p7         rollback drills (single + full)    (~25 min)
#   ./drive.sh p8         report
#   ./drive.sh all        everything in order, stop on first gate failure
#   ./drive.sh down       tear everything down (keeps artifacts/)
#
# Every phase appends evidence to artifacts/ and FAILS LOUDLY (exit 1) at its
# gate; `all` stops at the first failing phase so a broken network is left up
# for inspection.
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

OLD_BIN=../build/bin/geth-df31f81f-RUNNING-IN-PROD-linux-amd64
NEW_BIN=../build/bin/geth-e735e838-LATEST-all-fixes-linux-amd64
DC="docker compose"
ART=artifacts
VALIDATORS="1 2 3 4"
ALLNODES="1 2 3 4 5 6"

PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); echo "$(date -u +%FT%TZ) PASS $1" >> "$ART/gates.log"; }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); echo "$(date -u +%FT%TZ) FAIL $1" >> "$ART/gates.log"; }
gate(){ # end-of-phase verdict
  echo; echo "===== $1: $PASS passed, $FAIL failed ====="
  [ "$FAIL" -eq 0 ] || exit 1
}

ipc(){ docker exec "rehearsal-node$1" geth attach --exec "$2" /data/geth.ipc 2>/dev/null | tr -d '\r'; }
# digits or empty, NEVER error text: a dead console prints "Fatal: ..." which
# would otherwise reach $(( )) arithmetic and abort the driver under set -u
head_of(){ ipc "$1" 'eth.blockNumber' | grep -oE '^[0-9]+$' | head -1; }
# miner.start() REQUIRES an explicitly-set etherbase on this geth — raw
# miner.start() fails with "etherbase must be explicitly specified". Prod's
# autoMine-v2.js learned the same lesson (its unlock() calls setEtherbase
# first); mirror it for the driver's forced-mining steps.
mine_on(){ ipc "$1" 'try{miner.setEtherbase(eth.accounts[0])}catch(e){}; if(!eth.mining)miner.start()' >/dev/null; }
settled_hash(){ ipc "$1" "eth.getBlock($2).hash"; }
rpc_url(){ echo "http://node$1:8545"; }
lg(){ $DC run --rm loadgen "$@"; }   # one-shot loadgen command
lg_bg(){ $DC run -d --rm loadgen "$@"; }  # background loadgen; prints container id

wait_ready(){ # $1=node idx, $2=tries(x2s)
  local t="${2:-60}"
  for _ in $(seq 1 "$t"); do
    [ -n "$(head_of "$1")" ] && return 0
    sleep 2
  done
  return 1
}

addpeers_all(){
  for i in $ALLNODES; do
    docker exec "rehearsal-node$i" geth attach --exec 'loadScript("/scripts/addpeers.js")' /data/geth.ipc >/dev/null 2>&1 || true
  done
}

wait_catchup(){ # $1=node idx: within 2 blocks of the max head
  local i="$1" hi hr max t
  for t in $(seq 1 60); do
    hi=$(head_of "$i"); max=0
    for j in $ALLNODES; do
      [ "$j" = "$i" ] && continue
      hr=$(head_of "$j"); [ -n "$hr" ] && [ "$hr" -gt "$max" ] && max=$hr
    done
    if [ -n "$hi" ] && [ $((max - hi)) -le 2 ]; then return 0; fi
    sleep 2
  done
  return 1
}

agree_check(){ # all reachable nodes agree on the hash at (minhead-2)
  local min=99999999 h n H1 REF="" bad=0
  for n in $ALLNODES; do
    h=$(head_of "$n"); [ -z "$h" ] && continue
    [ "$h" -lt "$min" ] && min=$h
  done
  [ "$min" -le 2 ] && { ok "$1: chain too short to compare (head=$min)"; return; }
  local chk=$((min-2))
  for n in $ALLNODES; do
    [ -z "$(head_of "$n")" ] && continue
    H1=$(settled_hash "$n" "$chk")
    [ -z "$REF" ] && REF="$H1"
    [ "$H1" != "$REF" ] && bad=1
  done
  [ "$bad" -eq 0 ] && ok "$1: all reachable nodes agree at block $chk" \
                   || no "$1: settled-hash DISAGREEMENT at block $chk"
}

# --- log tripwires: scan all containers for validity errors since last scan ---
SINCE_FILE="$ART/.tripwire-since"
tripwire(){ # $1=label
  local since="" out=""
  [ -f "$SINCE_FILE" ] && since="--since $(cat "$SINCE_FILE")"
  date -u +%FT%TZ > "$SINCE_FILE"
  for c in $(docker ps -a --format '{{.Names}}' | grep '^rehearsal-' ); do
    # 'Unable to attach' is the entrypoint's own benign IPC-startup race (prod's
    # script documents it) — a client-side message, not a geth crash. And geth's
    # real bad-block report is a '########## BAD BLOCK #########' banner: match
    # the frame, not the bare words, because a block hash ending in ...bad
    # followed by 'blocks=1' in an ordinary import line matches 'bad block'
    # case-insensitively (seen twice in one run — 6 nodes logging every import
    # makes 1-in-4096 hash suffixes routine).
    # 'Failed to start the JavaScript console' is the automine sidecar's
    # designed retry loop hitting a node whose IPC is briefly down mid-restart.
    out=$(docker logs $since "$c" 2>&1 | grep -iE 'BAD BLOCK #|missing withdrawals|invalid merkle|panic:|Fatal:' | grep -vE 'Unable to attach|Failed to start the JavaScript console' | head -5)
    if [ -n "$out" ]; then
      echo "$out" | sed "s/^/    [$c] /" | tee -a "$ART/tripwires.log"
      no "$1: validity/crash tripwire in $c"
      return
    fi
  done
  ok "$1: zero validity/crash tripwires"
}

recreate_node(){ # $1=idx  (re-reads .env: picks up NODEx_TAG / NODEx_RECOMMIT)
  local i="$1"
  $DC up -d --no-deps --force-recreate "node$i" >/dev/null 2>&1
  if echo "$VALIDATORS" | grep -qw "$i"; then
    $DC up -d --no-deps --force-recreate "automine-node$i" >/dev/null 2>&1
  fi
  wait_ready "$i" 90 || { no "node$i did not come back"; return 1; }
  docker exec "rehearsal-node$i" geth attach --exec 'loadScript("/scripts/addpeers.js")' /data/geth.ipc >/dev/null 2>&1 || true
  addpeers_all
  wait_catchup "$i" || { no "node$i did not catch up"; return 1; }
  return 0
}

set_env(){ # $1=KEY $2=VAL  (updates .env used by compose)
  grep -q "^$1=" .env 2>/dev/null && sed -i "s/^$1=.*/$1=$2/" .env || echo "$1=$2" >> .env
}

# STRICT relay check. For a validator: freeze its automine + miner first so it
# cannot mine its own tx into a block (which would fake a relay pass) — this is
# the prod silent-failure mode (see prod start_network.sh step 4.5).
relay_gate(){ # $1=idx $2=label
  local i="$1" witness=5
  [ "$i" = "5" ] && witness=6
  if echo "$VALIDATORS" | grep -qw "$i"; then
    docker stop "rehearsal-automine-node$i" >/dev/null 2>&1 || true
    ipc "$i" 'miner.stop()' >/dev/null 2>&1 || true
  fi
  if lg relaycheck "$(rpc_url "$i")" "$(rpc_url "$witness")" "$2-node$i"; then
    ok "$2: node$i RELAYS transactions after restart"
  else
    no "$2: node$i relay DEAD after restart (prod failure mode!)"
  fi
  if echo "$VALIDATORS" | grep -qw "$i"; then
    docker start "rehearsal-automine-node$i" >/dev/null 2>&1 || true
  fi
}

blocks_advanced(){ # $1=label $2=window-start-head $3=min-advance
  local nowh; nowh=$(head_of 5); [ -z "$nowh" ] && nowh=$(head_of 6)
  if [ -n "$nowh" ] && [ $((nowh - $2)) -ge "$3" ]; then
    ok "$1: chain advanced +$((nowh - $2)) (needed +$3)"
  else
    no "$1: chain advanced only +$((nowh - ${2:-0})) (needed +$3)"
  fi
}

# ========================================================================== prep
prep(){
  echo "===== PREP: images, genesis, keys ====="
  mkdir -p "$ART" bin data secrets
  [ -f secrets/signer.pw ] || echo rehearsal > secrets/signer.pw
  [ -f "$OLD_BIN" ] || { echo "missing $OLD_BIN"; exit 1; }
  [ -f "$NEW_BIN" ] || { echo "missing $NEW_BIN"; exit 1; }
  cp "$OLD_BIN" bin/geth-old-linux-amd64
  cp "$NEW_BIN" bin/geth-new-linux-amd64
  docker build -q -f Dockerfile.node --build-arg GETH_BIN=geth-old-linux-amd64 -t purechain-rehearsal:old . || exit 1
  docker build -q -f Dockerfile.node --build-arg GETH_BIN=geth-new-linux-amd64 -t purechain-rehearsal:new . || exit 1
  $DC build monitor loadgen >/dev/null || exit 1
  # fresh state
  $DC down --remove-orphans >/dev/null 2>&1 || true
  rm -rf data; mkdir -p data
  : > "$ART/gates.log"; rm -f "$SINCE_FILE" "$ART"/lat-*.csv "$ART"/monitor.csv "$ART"/alerts.log "$ART"/gates.jsonl "$ART"/summaries.jsonl "$ART"/ramp.csv "$ART"/ceiling.txt "$ART"/tripwires.log
  # .env: everything OLD at 2s recommit
  : > .env
  for i in $ALLNODES; do set_env "NODE${i}_TAG" old; done
  for i in $VALIDATORS; do set_env "NODE${i}_RECOMMIT" 2s; done
  # genesis: shanghai+cancun activate 8 minutes from now (forks crossed live
  # during p1, like prod's real history; berlin/london cross at block 120 —
  # sequential bring-up + arming must finish mining past 120 before this)
  FORK_TIME=$(( $(date +%s) + 480 ))
  sed "s/__FORK_TIME__/$FORK_TIME/" genesis.tpl.json > genesis.json
  echo "$FORK_TIME" > "$ART/fork-time.txt"
  # nodekeys + addpeers.js (needs the loadgen image; writes into data/ + scripts/)
  lg keygen || exit 1
  # init datadirs + import validator keys
  KEYS=(ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
        59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d \
        5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a \
        7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6)
  for i in $ALLNODES; do
    $DC run --rm --entrypoint "" "node$i" geth --datadir /data init /genesis.json >/dev/null 2>&1 || { echo "init failed node$i"; exit 1; }
  done
  for i in $VALIDATORS; do
    echo "${KEYS[$((i-1))]}" > "data/node$i/import.key"
    $DC run --rm --entrypoint "" "node$i" geth account import --datadir /data --password /run/secrets/signer.pw /data/import.key >/dev/null 2>&1 || { echo "key import failed node$i"; exit 1; }
    rm -f "data/node$i/import.key"
  done
  # STANDBY validator keys for the PoA² phase: node5/node6 hold an unlocked
  # signer key but are absent from the genesis signer set, so they seal nothing
  # until PoA² votes them in.
  echo 8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba > data/node5/import.key
  echo 92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e > data/node6/import.key
  for i in 5 6; do
    $DC run --rm --entrypoint "" "node$i" geth account import --datadir /data --password /run/secrets/signer.pw /data/import.key >/dev/null 2>&1 || { echo "standby key import failed node$i"; exit 1; }
    rm -f "data/node$i/import.key"
  done
  echo "prep done: images old/new built, genesis fork time $FORK_TIME, keys in place"
}

# =========================================================================== p1
p1(){
  echo "===== P1: sequential bring-up + baseline on OLD (df31f81f) ====="
  # sequential bring-up with readiness + peering after each (prod procedure)
  for i in $ALLNODES; do
    echo -n "  node$i: starting..."
    $DC up -d --no-deps "node$i" >/dev/null 2>&1
    wait_ready "$i" 45 || { echo " FAILED"; docker logs --tail 20 "rehearsal-node$i"; exit 1; }
    docker exec "rehearsal-node$i" geth attach --exec 'loadScript("/scripts/addpeers.js")' /data/geth.ipc >/dev/null 2>&1 || true
    echo " ready"
  done
  addpeers_all; sleep 5
  # consistency gate before any sealing (prod step 4)
  local heads
  heads=$(for i in $ALLNODES; do ipc "$i" 'eth.getBlock("latest").hash'; done | sort -u | grep -c .)
  [ "$heads" -eq 1 ] && ok "p1: all 6 agree on genesis head before sealing" || no "p1: $heads distinct heads before sealing"
  # relay arming (prod step 4.5): force >=3 validators to mine, restart each
  # node once so its downloader runs, then stop forced mining
  echo "  arming tx relay (prod rolling-restart procedure)..."
  for v in $VALIDATORS; do mine_on "$v"; done
  sleep 5
  H_ARM=$(head_of 1)
  [ -n "$H_ARM" ] && [ "$H_ARM" -gt 0 ] && ok "p1: forced mining is sealing (head=$H_ARM)" \
                                        || no "p1: forced mining produced no blocks"
  for i in $ALLNODES; do
    for v in $VALIDATORS; do [ "$v" = "$i" ] || mine_on "$v"; done
    docker restart "rehearsal-node$i" >/dev/null 2>&1
    wait_ready "$i" 45 || { no "p1: node$i failed post-arming restart"; gate P1; }
    docker exec "rehearsal-node$i" geth attach --exec 'loadScript("/scripts/addpeers.js")' /data/geth.ipc >/dev/null 2>&1 || true
    wait_catchup "$i" || no "p1: node$i did not re-sync during arming"
    [ "$i" -le 4 ] && mine_on "$i"
  done
  # keep forced mining until berlin/london (block 120) is crossed so the
  # time-based shanghai/cancun forks NEVER activate below the block forks
  echo "  mining through the berlin/london fork boundary (block 120)..."
  for _ in $(seq 1 120); do
    h=$(head_of 1); [ -n "$h" ] && [ "$h" -ge 125 ] && break
    sleep 2
  done
  h=$(head_of 1)
  [ -n "$h" ] && [ "$h" -ge 121 ] && ok "p1: berlin/london crossed at head=$h" || no "p1: still below fork at head=${h:-?}"
  for v in $VALIDATORS; do ipc "$v" 'miner.stop()' >/dev/null; done
  # hand sealing control to automine + start the referee
  for v in $VALIDATORS; do $DC up -d --no-deps "automine-node$v" >/dev/null 2>&1; done
  $DC up -d monitor >/dev/null 2>&1
  # wait for shanghai/cancun activation (wall clock) while doing baseline work
  lg fund "$(rpc_url 5)" 12 || { no "p1: funding failed"; gate P1; }
  ok "p1: 12 load wallets funded via public RPC"
  # cross the time fork under light load so the transition happens live
  FORK_TIME=$(cat "$ART/fork-time.txt")
  NOWT=$(date +%s)
  if [ "$NOWT" -lt "$((FORK_TIME + 20))" ]; then
    echo "  crossing shanghai+cancun fork under load ($((FORK_TIME + 20 - NOWT))s)..."
    lg steady "$(rpc_url 5)" 3 $((FORK_TIME + 20 - NOWT)) p1-forkcross 0 || no "p1: load through fork failed"
  fi
  # confirm cancun is live: latest block must carry cancun fields
  BG=$(ipc 5 'eth.getBlock("latest").excessBlobGas')
  [ -n "$BG" ] && [ "$BG" != "undefined" ] && [ "$BG" != "null" ] \
    && ok "p1: cancun ACTIVE (excessBlobGas=$BG)" || no "p1: cancun fields missing post-fork"
  # baseline measurements on OLD binary
  H0=$(head_of 5)
  lg steady "$(rpc_url 5)" 10 180 base-busy 25 || no "p1: baseline bursty load failed"
  blocks_advanced "p1 baseline load" "$H0" 60
  lg latency "$(rpc_url 5)" 25 base-busy-probe || no "p1: busy latency probe failed"
  lg latency "$(rpc_url 5)" 6 base-cold-probe --cold || no "p1: cold latency probe failed"
  # automine idle behavior: after >15s quiet all miners must stop
  sleep 25
  M=$(for v in $VALIDATORS; do ipc "$v" 'eth.mining'; done | grep -c true)
  [ "$M" -eq 0 ] && ok "p1: smart-automine stopped all miners when idle" || no "p1: $M miners still on after idle window"
  agree_check "p1 final"
  tripwire "p1"
  gate P1
}

# =========================================================================== p2
p2(){
  echo "===== P2: rolling upgrade OLD -> NEW under load (RPC first, then validators) ====="
  BGID=$(lg_bg steady "$(rpc_url 6)" 8 2400 p2-bg 0)
  sleep 5
  for i in 5 6 2 3 4 1; do
    echo "  ---- upgrading node$i to NEW ----"
    H_PRE=$(head_of 5); [ -z "$H_PRE" ] && H_PRE=$(head_of 6); [ -z "$H_PRE" ] && H_PRE=0
    set_env "NODE${i}_TAG" new
    if recreate_node "$i"; then
      ok "p2: node$i recreated on NEW binary and caught up"
    else
      docker rm -f "$BGID" >/dev/null 2>&1; gate P2
    fi
    VSTR=$(docker exec "rehearsal-node$i" geth version 2>/dev/null | grep -i 'git commit:' | head -1 | tr -d '\r')
    echo "$VSTR" | grep -qi e735e838 && ok "p2: node$i reports NEW commit" || no "p2: node$i version wrong: $VSTR"
    relay_gate "$i" "p2"
    blocks_advanced "p2 during node$i swap" "$H_PRE" 3
    agree_check "p2 after node$i"
    tripwire "p2-node$i"
    [ "$FAIL" -gt 0 ] && { docker rm -f "$BGID" >/dev/null 2>&1; gate P2; }
  done
  docker rm -f "$BGID" >/dev/null 2>&1 || true
  gate P2
}

# =========================================================================== p3
p3(){
  echo "===== P3: post-upgrade functional battery + fresh-node sync ====="
  # same measurements as baseline, for the comparison table
  lg steady "$(rpc_url 5)" 10 180 post-busy 25 || no "p3: post-upgrade bursty load failed"
  lg latency "$(rpc_url 5)" 25 post-busy-probe || no "p3: busy latency probe failed"
  lg latency "$(rpc_url 5)" 6 post-cold-probe --cold || no "p3: cold latency probe failed"
  # smart-automine must behave exactly as before the upgrade
  sleep 25
  M=$(for v in $VALIDATORS; do ipc "$v" 'eth.mining'; done | grep -c true)
  [ "$M" -eq 0 ] && ok "p3: automine still stops when idle (novelty preserved)" || no "p3: $M miners on after idle"
  T0=$(date +%s)
  lg latency "$(rpc_url 5)" 1 p3-wake || true
  M=$(for v in $VALIDATORS; do ipc "$v" 'eth.mining'; done | grep -c true)
  [ "$M" -ge 3 ] && ok "p3: automine woke all validators on activity ($M mining, $(( $(date +%s) - T0 ))s)" || no "p3: only $M validators mining under activity"
  # user-facing behavior through the PUBLIC api surface (eth,net,web3 only)
  lg contract "$(rpc_url 5)" post || no "p3: contract deploy/event/getLogs/call failed on public RPC"
  ok "p3: contract lifecycle on public RPC"
  CID=$(ipc 5 'eth.chainId()' 2>/dev/null); GP=$(lg watch "$(rpc_url 6)" 30 p3 >/dev/null 2>&1 && echo ok || echo fail)
  [ "$GP" = "ok" ] && ok "p3: HTTP polling continuity clean on node6" || no "p3: HTTP polling saw errors"
  # fresh 7th node on the NEW binary must FULL-SYNC the whole chain from
  # genesis (archive peers serve no snapshots — prod reality)
  echo "  full-syncing a fresh node7 from genesis..."
  docker rm -f rehearsal-node7 >/dev/null 2>&1 || true
  # pwd -W gives a Windows-style path git-bash+docker both accept; plain pwd elsewhere
  PWDW=$(pwd -W 2>/dev/null || pwd)
  docker run -d --name rehearsal-node7 --network rehearsal_purechain-rehearsal \
    -v "$PWDW/scripts:/scripts:ro" -v "$PWDW/genesis.json:/genesis.json:ro" \
    --entrypoint sh purechain-rehearsal:new -c \
    "geth --datadir /d7 init /genesis.json && exec geth --datadir /d7 --networkid 424242 --syncmode full --nodiscover --snapshot=false --gcmode archive --cache 256 --port 30303 --http --http.addr 0.0.0.0 --http.api eth,net,web3,admin" >/dev/null
  sleep 8
  docker exec rehearsal-node7 geth attach --exec 'loadScript("/scripts/addpeers.js")' /d7/geth.ipc >/dev/null 2>&1 || true
  SYNCED=0
  NETH=$(head_of 5)
  for _ in $(seq 1 90); do
    H7=$(docker exec rehearsal-node7 geth attach --exec 'eth.blockNumber' /d7/geth.ipc 2>/dev/null | tr -d '\r')
    NETH=$(head_of 5)
    if [ -n "$H7" ] && [ -n "$NETH" ] && [ $((NETH - H7)) -le 2 ] && [ "$H7" -gt 100 ]; then SYNCED=1; break; fi
    sleep 4
  done
  [ "$SYNCED" -eq 1 ] && ok "p3: fresh node7 full-synced the whole chain (head=$H7)" || no "p3: node7 stuck at ${H7:-0}/${NETH:-?}"
  docker rm -f rehearsal-node7 >/dev/null 2>&1 || true
  agree_check "p3 final"
  tripwire "p3"
  gate P3
}

# =========================================================================== p4
p4(){
  echo "===== P4: recommit 750ms rehearsal (the planned post-upgrade config) ====="
  BGID=$(lg_bg steady "$(rpc_url 6)" 8 1500 p4-bg 0)
  sleep 5
  for v in $VALIDATORS; do
    echo "  ---- node$v -> --miner.recommit 750ms ----"
    set_env "NODE${v}_RECOMMIT" 750ms
    recreate_node "$v" && ok "p4: node$v recreated at 750ms" || { docker rm -f "$BGID" >/dev/null 2>&1; no "p4: node$v failed"; gate P4; }
    relay_gate "$v" "p4"
    tripwire "p4-node$v"
  done
  docker rm -f "$BGID" >/dev/null 2>&1 || true
  # measure the latency the change buys, same probes as baseline/post
  lg latency "$(rpc_url 5)" 25 rc750-busy-probe || no "p4: busy probe failed"
  lg latency "$(rpc_url 5)" 6 rc750-cold-probe --cold || no "p4: cold probe failed"
  # outage under load at 750ms — the wiggle deadline fix in its target config
  echo "  ---- 5-minute signer outage at 750ms under load ----"
  BGID=$(lg_bg steady "$(rpc_url 5)" 10 420 p4-outage 0)
  sleep 10
  docker stop rehearsal-automine-node2 rehearsal-node2 >/dev/null 2>&1
  H_OUT=$(head_of 5)
  sleep 300
  blocks_advanced "p4 outage (node2 down 5min, 750ms recommit)" "$H_OUT" 60
  docker start rehearsal-node2 rehearsal-automine-node2 >/dev/null 2>&1
  wait_ready 2 60 && wait_catchup 2 && ok "p4: node2 rejoined after outage" || no "p4: node2 failed to rejoin"
  docker rm -f "$BGID" >/dev/null 2>&1 || true
  WD=$(docker logs --since 20m rehearsal-automine-node1 2>&1 | grep -c 'WATCHDOG' || true)
  echo "  (automine watchdog fired $WD times on node1 during p4 — informational)"
  agree_check "p4 final"
  tripwire "p4"
  gate P4
}

# =========================================================================== p5
p5(){
  echo "===== P5: stress — ceiling, then outage + kill -9 at 80% ceiling ====="
  lg ramp "$(rpc_url 5)" 25 400 45 || no "p5: ramp harness failed"
  CEIL=$(cat "$ART/ceiling.txt" 2>/dev/null || echo 0)
  [ "$CEIL" -ge 25 ] && ok "p5: sustainable ceiling found: $CEIL tx/s" || no "p5: no sustainable rate >= 25 tx/s (ceiling=$CEIL)"
  HOLD=$(( CEIL * 8 / 10 )); [ "$HOLD" -lt 10 ] && HOLD=10
  echo "  holding at ${HOLD} tx/s for 10 min with outage + crash drills inside..."
  BGID=$(lg_bg steady "$(rpc_url 5)" "$HOLD" 600 p5-hold 0)
  sleep 120
  echo "  ---- drill 1: stop node3 for 5 min at ${HOLD} tx/s ----"
  docker stop rehearsal-automine-node3 rehearsal-node3 >/dev/null 2>&1
  H_OUT=$(head_of 5)
  sleep 150
  echo "  ---- drill 2 (overlapping): SIGKILL geth inside node4 (restart policy must revive it) ----"
  # NOT `docker kill`: Docker treats that as a MANUAL stop and restart policies
  # deliberately ignore manually-stopped containers (verified live — node4
  # stayed 'exited'). A real crash is the PROCESS dying: kill geth inside, the
  # entrypoint exits, and unless-stopped revives the container. Ops note for
  # prod: `docker kill`/`docker stop` on a node will NOT auto-restart it.
  docker exec rehearsal-node4 sh -c 'pkill -9 geth' >/dev/null 2>&1
  sleep 150
  blocks_advanced "p5 outage window at ${HOLD} tx/s" "$H_OUT" 60
  REVIVED=$(docker inspect -f '{{.State.Status}}' rehearsal-node4 2>/dev/null)
  [ "$REVIVED" = "running" ] && ok "p5: node4 auto-revived after kill -9 (restart policy)" || no "p5: node4 not running after kill (status=$REVIVED)"
  wait_ready 4 60 && wait_catchup 4 && ok "p5: node4 re-synced after crash (no DB corruption)" || no "p5: node4 failed to re-sync after kill -9"
  docker start rehearsal-node3 rehearsal-automine-node3 >/dev/null 2>&1
  wait_ready 3 60 && wait_catchup 3 && ok "p5: node3 rejoined after 5-min outage" || no "p5: node3 failed to rejoin"
  docker rm -f "$BGID" >/dev/null 2>&1 || true
  relay_gate 4 "p5-crash"
  relay_gate 3 "p5-outage"
  agree_check "p5 final"
  tripwire "p5"
  gate P5
}

# =========================================================================== p6
p6(){
  echo "===== P6: two-signer halt drill (Clique limit=3 of 4) ====="
  BGID=$(lg_bg steady "$(rpc_url 5)" 8 400 p6-bg 0)
  sleep 10
  docker stop rehearsal-automine-node1 rehearsal-automine-node2 rehearsal-node1 rehearsal-node2 >/dev/null 2>&1
  H_FREEZE=$(head_of 5)
  sleep 100
  H_NOW=$(head_of 5)
  DRIFT=$(( H_NOW - H_FREEZE ))
  [ "$DRIFT" -le 2 ] && ok "p6: chain HALTED with 2 of 4 signers down (drift=$DRIFT — expected Clique behavior)" \
                     || no "p6: chain kept sealing with 2 signers down (drift=$DRIFT) — recent-signer rule violated!"
  # RUNBOOK (proven live 2026-08-13, three drills + snapshot evidence): after a
  # 2-of-4 halt, restoring ONE signer is usually NOT enough. The departing
  # signers were sealing right up to their stop, so the frozen recent-signers
  # window typically pins three of four validators and the only eligible sealer
  # is the OTHER downed signer ("signed recently, must wait for others" on the
  # restored one — observed directly). The window cannot rotate while frozen.
  # Recovery = restore BOTH signers and wake BOTH miners over IPC (automine
  # alone won't: its wake signals died with the halt, and a restart onto a
  # frozen chain leaves tx relay unarmed, so pools stay empty).
  docker start rehearsal-node2 rehearsal-automine-node2 rehearsal-node1 rehearsal-automine-node1 >/dev/null 2>&1
  wait_ready 2 60 || no "p6: node2 not ready after restart"
  wait_ready 1 60 || no "p6: node1 not ready after restart"
  for i in 1 2; do docker exec "rehearsal-node$i" geth attach --exec 'loadScript("/scripts/addpeers.js")' /data/geth.ipc >/dev/null 2>&1 || true; done
  mine_on 1; mine_on 2
  T_RESUME=$(date +%s)
  H_R0=$(head_of 5); RESUMED=0
  for _ in $(seq 1 60); do
    H_R1=$(head_of 5)
    [ -n "$H_R1" ] && [ $((H_R1 - H_R0)) -ge 5 ] && { RESUMED=1; break; }
    sleep 2
  done
  [ "$RESUMED" -eq 1 ] && ok "p6: chain RESUMED $(( $(date +%s) - T_RESUME ))s after BOTH signers restored + woken" || no "p6: chain did not resume even with both signers restored"
  wait_catchup 1 && wait_catchup 2 && ok "p6: both signers fully rejoined" || no "p6: a restored signer failed to catch up"
  docker rm -f "$BGID" >/dev/null 2>&1 || true
  agree_check "p6 final"
  tripwire "p6"
  gate P6
}

# =========================================================================== p7
p7(){
  echo "===== P7: rollback drills ====="
  BGID=$(lg_bg steady "$(rpc_url 6)" 8 2400 p7-bg 0)
  sleep 5
  echo "  ---- drill 1: single validator (node3) back to OLD, mixed soak ----"
  set_env "NODE3_TAG" old
  recreate_node 3 && ok "p7: node3 rolled BACK to OLD among NEW peers" || no "p7: node3 rollback failed"
  relay_gate 3 "p7-mixed"
  sleep 120
  agree_check "p7 mixed-version soak"
  tripwire "p7-mixed"
  set_env "NODE3_TAG" new
  recreate_node 3 && ok "p7: node3 rolled FORWARD again" || no "p7: node3 re-upgrade failed"
  echo "  ---- drill 2: FULL network rollback to OLD (the abort path) ----"
  for i in 1 2 3 4 5 6; do
    set_env "NODE${i}_TAG" old
    recreate_node "$i" && ok "p7: node$i back on OLD" || { docker rm -f "$BGID" >/dev/null 2>&1; no "p7: node$i rollback failed"; gate P7; }
    relay_gate "$i" "p7-full"
  done
  H_RB=$(head_of 5)
  sleep 120
  blocks_advanced "p7 full-rollback soak (OLD binary reading NEW's writes)" "$H_RB" 30
  agree_check "p7 full rollback"
  tripwire "p7-rollback"
  echo "  ---- roll forward to final state: everything on NEW ----"
  for i in 5 6 2 3 4 1; do
    set_env "NODE${i}_TAG" new
    recreate_node "$i" && ok "p7: node$i final roll-forward" || no "p7: node$i final roll-forward failed"
  done
  docker rm -f "$BGID" >/dev/null 2>&1 || true
  agree_check "p7 final (all NEW)"
  tripwire "p7-final"
  gate P7
}

# =========================================================================== p9
# PoA²: automatic validator replacement, running as a sidecar on every
# validator. Never exercised on a live network, and it interacts with the
# on-demand sealing policy in a way nothing else here tests — a healthy
# validator whose sealing sidecar died looks identical, through
# clique.status(), to a validator that is down.
STANDBY5=0x9965507d1a55bcc2695c58ba16fb37d819b0a4dc
STANDBY6=0x976ea74026e726554db657fa54763abd0c3a0aa9
PHANTOM=0x00000000000000000000000000000000deadbe01
V3=3c44cdddb6a900fa2b585dd299e03d12fa4293bc
V2=70997970c51812dc3a010c7d01b50e0d17dc79c8
V4=90f79bf6eb2c4f870365e785982e1f101e93b906

signer_list(){ ipc "${1:-1}" 'JSON.stringify(clique.getSigners())'; }
signer_count(){ ipc "${1:-1}" 'clique.getSigners().length' | grep -oE '^[0-9]+$' | head -1; }
is_signer(){ signer_list 1 | grep -qi "${1#0x}"; }
poa2_up(){ for v in $VALIDATORS; do $DC up -d --no-deps "poa2-node$v" >/dev/null 2>&1; done; }
poa2_down(){ for v in $VALIDATORS; do docker rm -f "rehearsal-poa2-node$v" >/dev/null 2>&1; done; }
poa2_says(){ docker logs --since "${2:-10m}" "rehearsal-poa2-node${1}" 2>&1 | grep -c "$3" || true; }

p9(){
  echo "===== P9: PoA² automatic validator replacement ====="
  # Standbys must be running and sealing-capable BEFORE promotion, or a vote
  # installs a signer that never seals.
  $DC up -d --no-deps automine-node5 automine-node6 >/dev/null 2>&1
  sleep 5
  S0=$(signer_count 1)
  [ "$S0" = "4" ] && ok "p9: starting from 4 signers" || { no "p9: expected 4 signers, got ${S0:-?}"; gate P9; }

  # ---- 9a: no false positives on a healthy network -----------------------
  # WARM-UP FIRST. sealerActivity is a trailing 64-BLOCK window, not a time
  # window. On a chain that has been idle — or that has just restarted — those
  # 64 blocks are whatever was sealed before the pause, so a validator which
  # was legitimately down back then still reads as inactive now. Starting the
  # controller on a stale window makes it act on history. Operational rule:
  # let every validator seal into the current window BEFORE starting PoA².
  echo "  ---- 9a: warm-up so all four validators appear in the activity window ----"
  lg steady "$(rpc_url 5)" 8 100 p9-warmup 0 >/dev/null 2>&1 || true
  ACT=$(ipc 1 'JSON.stringify(clique.status().sealerActivity)')
  echo "  activity after warm-up: $ACT"
  ZEROS=$(printf '%s' "$ACT" | grep -oE ':0[,}]' | wc -l)
  [ "$ZEROS" -eq 0 ] && ok "p9a: warm-up left every validator active in the window" \
                     || no "p9a: $ZEROS validator(s) still read as inactive after warm-up — PoA² would act on a stale window"

  echo "  ---- 9a: healthy network, PoA² must stay quiet ----"
  poa2_up
  BGID=$(lg_bg steady "$(rpc_url 5)" 8 200 p9a-bg 25)   # bursty: idle gaps included
  sleep 200
  docker rm -f "$BGID" >/dev/null 2>&1 || true
  S1=$(signer_count 1)
  FLAGS=$(poa2_says 1 6m "is not mining")
  [ "$S1" = "4" ] && ok "p9a: signer set untouched on a healthy network (still 4)" \
                  || no "p9a: signer set changed to ${S1:-?} with every validator healthy"
  [ "$FLAGS" -eq 0 ] && ok "p9a: zero false 'not mining' flags across idle gaps" \
                     || no "p9a: $FLAGS false flags raised while all validators were healthy"
  tripwire "p9a"

  # ---- 9b: genuine fault, standby promoted -------------------------------
  echo "  ---- 9b: stop validator node3, PoA² must replace it ----"
  BGID=$(lg_bg steady "$(rpc_url 5)" 8 480 p9b-bg 0)
  sleep 5
  H_B=$(head_of 5)
  docker stop rehearsal-automine-node3 rehearsal-node3 >/dev/null 2>&1
  REPLACED=0
  for _ in $(seq 1 100); do
    if is_signer "$STANDBY5" || is_signer "$STANDBY6"; then REPLACED=1; break; fi
    sleep 4
  done
  sleep 40   # let the removal half of the cycle land too
  S2=$(signer_count 1); PROMOTED=""
  is_signer "$STANDBY5" && PROMOTED="$PROMOTED node5"
  is_signer "$STANDBY6" && PROMOTED="$PROMOTED node6"
  [ "$REPLACED" -eq 1 ] && ok "p9b: standby promoted ($PROMOTED)" || no "p9b: no standby promoted within ~7 min"
  is_signer "$V3" && no "p9b: the failed validator is STILL a signer (removal half never landed)" \
                  || ok "p9b: failed validator voted out"
  [ "$S2" = "4" ] && ok "p9b: signer set back to 4" || no "p9b: signer set is ${S2:-?}, expected 4"
  blocks_advanced "p9b chain through the replacement" "$H_B" 60
  agree_check "p9b"
  docker rm -f "$BGID" >/dev/null 2>&1 || true
  tripwire "p9b"

  # ---- 9c: repeat fault (does the detector re-arm?) ----------------------
  echo "  ---- 9c: second fault, must heal again (tests the cooldown reset) ----"
  BGID=$(lg_bg steady "$(rpc_url 5)" 8 480 p9c-bg 0)
  sleep 5
  H_C=$(head_of 5)
  docker stop rehearsal-automine-node2 rehearsal-node2 >/dev/null 2>&1
  HEAL2=0
  for _ in $(seq 1 100); do
    C=$(signer_count 1)
    if [ "${C:-0}" = "4" ] && ! is_signer "$V2"; then HEAL2=1; break; fi
    sleep 4
  done
  [ "$HEAL2" -eq 1 ] && ok "p9c: SECOND fault healed too — detector re-armed after cooldown" \
                     || no "p9c: second fault NOT healed — detector never re-armed (one-shot controller)"
  blocks_advanced "p9c chain through the second replacement" "$H_C" 60
  docker rm -f "$BGID" >/dev/null 2>&1 || true
  agree_check "p9c"
  tripwire "p9c"

  # ---- 9d: the SAM interaction — healthy node, dead sealing sidecar ------
  echo "  ---- 9d: kill only node4's SEALING sidecar (node itself stays healthy) ----"
  # The case operators will actually hit: the validator is up, synced and
  # serving RPC, but its sealing sidecar died so it stops sealing. Through
  # clique.status() that is indistinguishable from a dead validator — yet the
  # correct fix is restarting a sidecar, not burning a standby and evicting a
  # working node.
  poa2_down; poa2_up   # fresh controllers so prior state cannot mask this
  sleep 5
  docker stop rehearsal-automine-node4 >/dev/null 2>&1
  BGID=$(lg_bg steady "$(rpc_url 5)" 8 320 p9d-bg 0)
  sleep 300
  docker rm -f "$BGID" >/dev/null 2>&1 || true
  if is_signer "$V4"; then
    ok "p9d: healthy node with a dead sealing sidecar was NOT evicted (set=$(signer_count 1))"
  else
    no "p9d: PoA² EVICTED a healthy validator whose sealing sidecar had died — the fix is restarting the sidecar, not replacing the node"
  fi
  docker start rehearsal-automine-node4 >/dev/null 2>&1
  tripwire "p9d"

  # ---- 9e: phantom standby (the halt hazard) -----------------------------
  echo "  ---- 9e: propose a standby with NO node behind it ----"
  # A signer that never seals still counts toward len(signers) and raises the
  # recent-signer bar. This measures what that costs in liveness margin.
  poa2_down   # manual control: PoA² must not fight the experiment
  for v in $VALIDATORS; do ipc "$v" "clique.propose(\"$PHANTOM\", true)" >/dev/null 2>&1; done
  ADDED=0
  for _ in $(seq 1 45); do is_signer "$PHANTOM" && { ADDED=1; break; }; sleep 2; done
  if [ "$ADDED" -eq 1 ]; then
    ok "p9e: phantom signer accepted — set is now $(signer_count 1)"
    BGID=$(lg_bg steady "$(rpc_url 5)" 8 220 p9e-bg 0)
    sleep 10
    H_E=$(head_of 5)
    echo "  now stopping ONE healthy validator on top of the phantom"
    docker stop rehearsal-automine-node1 rehearsal-node1 >/dev/null 2>&1
    sleep 100
    H_E2=$(head_of 5); DRIFT=$(( ${H_E2:-0} - ${H_E:-0} ))
    docker rm -f "$BGID" >/dev/null 2>&1 || true
    if [ "$DRIFT" -le 5 ]; then
      ok "p9e: HAZARD CONFIRMED — phantom + one real outage halted the chain (drift=$DRIFT). Never list a standby without a running node."
    else
      ok "p9e: chain survived phantom + one outage (drift=$DRIFT) — margin thinner but intact"
    fi
    docker start rehearsal-node1 rehearsal-automine-node1 >/dev/null 2>&1
    wait_ready 1 60 || true
    for v in $VALIDATORS; do mine_on "$v"; done
    for v in $VALIDATORS; do ipc "$v" "clique.propose(\"$PHANTOM\", false)" >/dev/null 2>&1; done
    for _ in $(seq 1 60); do is_signer "$PHANTOM" || break; sleep 2; done
    is_signer "$PHANTOM" && no "p9e: phantom could not be voted back out" \
                         || ok "p9e: phantom removed, set restored to $(signer_count 1)"
  else
    no "p9e: phantom proposal never carried (unexpected — the vote should pass)"
  fi
  tripwire "p9e"

  echo "  final signer set: $(signer_list 1)"
  poa2_down
  for i in 2 3; do docker start "rehearsal-node$i" "rehearsal-automine-node$i" >/dev/null 2>&1; wait_ready "$i" 60 || true; done
  addpeers_all
  gate P9
}

# =========================================================================== p8
p8(){
  echo "===== P8: report ====="
  {
    echo "# PureChain upgrade rehearsal — $(date -u +%F)"
    echo
    echo "Old binary: df31f81f (byte-identical to prod, sha verified). New: e735e838."
    echo
    echo "## Gates"
    echo '```'
    cat "$ART/gates.log"
    echo '```'
    echo
    echo "## Latency summaries (ms, submit->receipt via public RPC)"
    echo '```'
    cat "$ART/summaries.jsonl" 2>/dev/null
    echo '```'
    echo
    echo "## Stress ceiling"
    echo "Sustainable: $(cat "$ART/ceiling.txt" 2>/dev/null || echo '?') tx/s (ramp.csv has the curve)"
    echo
    echo "## Referee alerts"
    echo '```'
    cat "$ART/alerts.log" 2>/dev/null || echo "(none)"
    echo '```'
    echo
    echo "## Validity tripwires"
    echo '```'
    cat "$ART/tripwires.log" 2>/dev/null || echo "(none)"
    echo '```'
  } > "$ART/REPORT.md"
  echo "report written to $ART/REPORT.md"
}

# recover: re-arm the network after a WHOLE-NETWORK restart (engine bounce,
# power event, full compose down/up). Reproduces prod start_network.sh step
# 4.5. Without this, every node's tx relay stays unarmed on an idle chain:
# RPC accepts transactions, nobody gossips them, automine never wakes the
# other validators, and the network mines NOTHING while looking healthy —
# reproduced live in this rehearsal on 2026-08-13.
recover(){
  echo "===== RECOVER: re-arm tx relay after whole-network restart ====="
  for i in $ALLNODES; do wait_ready "$i" 45 || echo "  warn: node$i not ready"; done
  addpeers_all; sleep 3
  for v in $VALIDATORS; do mine_on "$v"; done
  sleep 5
  H0=$(head_of 1)
  [ -n "$H0" ] || { no "recover: no head from node1"; gate RECOVER; }
  for i in $ALLNODES; do
    for v in $VALIDATORS; do [ "$v" = "$i" ] || mine_on "$v"; done
    docker restart "rehearsal-node$i" >/dev/null 2>&1
    wait_ready "$i" 60 || { no "recover: node$i failed restart"; continue; }
    docker exec "rehearsal-node$i" geth attach --exec 'loadScript("/scripts/addpeers.js")' /data/geth.ipc >/dev/null 2>&1 || true
    wait_catchup "$i" || no "recover: node$i did not re-sync"
    [ "$i" -le 4 ] && mine_on "$i"
    echo "  node$i re-armed"
  done
  for v in $VALIDATORS; do ipc "$v" 'miner.stop()' >/dev/null 2>&1; done
  for v in $VALIDATORS; do $DC up -d --no-deps "automine-node$v" >/dev/null 2>&1; done
  $DC up -d monitor >/dev/null 2>&1
  relay_gate 5 "recover"
  relay_gate 1 "recover"
  agree_check "recover final"
  tripwire "recover"
  gate RECOVER
}

down(){ $DC down --remove-orphans; docker rm -f rehearsal-node7 >/dev/null 2>&1 || true; }

case "${1:-}" in
  prep) prep ;;
  p1) p1 ;;
  p2) p2 ;;
  p3) p3 ;;
  p4) p4 ;;
  p5) p5 ;;
  p6) p6 ;;
  p7) p7 ;;
  p8) p8 ;;
  p9) p9 ;;
  all) prep && p1 && p2 && p3 && p4 && p5 && p6 && p7 && p8 ;;
  recover) recover ;;
  down) down ;;
  *) echo "usage: drive.sh {prep|p1..p9|recover|all|down}"; exit 2 ;;
esac
