#!/usr/bin/env bash
# MIXED-VERSION test: can a node running the PREVIOUS fork build and a node
# running the NEW (backported) build coexist on the same Clique+Cancun chain?
#
# Proves the rolling-upgrade path: old sealer + new peer, then new sealer +
# old peer. Both directions must peer, sync, and agree on block hashes.
#
# Usage: mixed-version.sh <geth-old> <geth-new>
set -u

OLD="${1:?usage: $0 <geth-old> <geth-new>}"
NEW="${2:?usage: $0 <geth-old> <geth-new>}"

BASE=~/clique-mixed
P1=18601; P2=18602; AP1=18611; AP2=18612; PP1=30501; PP2=30502
KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SIGNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SIGNER_NO0X=f39Fd6e51aad88F6F4ce6aB8827279cffFb92266

PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

rpc(){ curl -s -X POST -H 'Content-Type: application/json' --data "$2" "http://127.0.0.1:$1"; }
head_num(){ printf "%d" "$(rpc "$1" '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | sed -E 's/.*"result":"([^"]*)".*/\1/')" 2>/dev/null || echo 0; }
# grep -o so a null/error response yields EMPTY (caught by the -n guard at the
# call site) instead of sed passing the whole error JSON through, which would
# let two identical error responses "agree" on a hash that was never compared.
blk_hash(){ rpc "$1" "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$2\",false],\"id\":1}" | grep -o '"hash":"0x[0-9a-f]*"' | head -1 | sed -E 's/.*:"([^"]*)"/\1/'; }
peers(){ printf "%d" "$(rpc "$1" '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' | sed -E 's/.*"result":"([^"]*)".*/\1/')" 2>/dev/null || echo 0; }
wait_rpc(){ for _ in $(seq 1 60); do rpc "$1" '{"jsonrpc":"2.0","method":"net_version","id":1}' | grep -q result && return 0; sleep 0.5; done; return 1; }
stopnode(){ kill "$1" 2>/dev/null; for _ in $(seq 1 20); do kill -0 "$1" 2>/dev/null || break; sleep 0.5; done; kill -9 "$1" 2>/dev/null; wait "$1" 2>/dev/null || true; }

pkill -f "clique-mixed" 2>/dev/null; sleep 1
rm -rf "$BASE"; mkdir -p "$BASE"
echo "password" > "$BASE/pw.txt"; echo "$KEY" > "$BASE/key.hex"
VANITY=$(printf '0%.0s' $(seq 1 64)); SEAL=$(printf '0%.0s' $(seq 1 130))

# Cancun active from genesis, free gas -- the production shape of this fork.
cat > "$BASE/genesis.json" <<EOF
{
  "config": {
    "chainId": 13399,
    "homesteadBlock":0,"eip150Block":0,"eip155Block":0,"eip158Block":0,
    "byzantiumBlock":0,"constantinopleBlock":0,"petersburgBlock":0,"istanbulBlock":0,
    "berlinBlock":0,"londonBlock":0,
    "shanghaiTime":0,"cancunTime":0,
    "zeroBaseFee": true,
    "clique": { "period": 1, "epoch": 30000 }
  },
  "difficulty":"1","gasLimit":"0x1c9c380",
  "extradata":"0x${VANITY}${SIGNER_NO0X}${SEAL}",
  "alloc": { "${SIGNER}": { "balance": "0x56bc75e2d63100000" } }
}
EOF

init(){ # $1=binary $2=datadir
  mkdir -p "$2"
  "$1" --datadir "$2" init "$BASE/genesis.json" > /dev/null 2>&1
  "$1" --datadir "$2" account import --password "$BASE/pw.txt" "$BASE/key.hex" > /dev/null 2>&1
  return 0
}

start_sealer(){ # $1=bin $2=dir $3=httpport $4=authport $5=p2pport $6=log
  "$1" --datadir "$2" --networkid 13399 \
    --unlock "$SIGNER" --password "$BASE/pw.txt" --allow-insecure-unlock \
    --mine --miner.etherbase "$SIGNER" --miner.gasprice 0 --txpool.pricelimit 0 \
    --http --http.addr 127.0.0.1 --http.port "$3" --http.api eth,net,web3,admin \
    --authrpc.port "$4" --port "$5" --nodiscover --maxpeers 5 --verbosity 2 > "$6" 2>&1 &
  echo $!
}
start_peer(){ # same but no mining. The account is unlocked here too — not to
  # seal, but so eth_sendTransaction works on this endpoint: the tx-gossip check
  # below submits on the peer and expects the tx to cross versions to the
  # sealer. Without the unlock the submit always errors and that check would
  # silently never run.
  "$1" --datadir "$2" --networkid 13399 \
    --unlock "$SIGNER" --password "$BASE/pw.txt" --allow-insecure-unlock \
    --http --http.addr 127.0.0.1 --http.port "$3" --http.api eth,net,web3,admin \
    --authrpc.port "$4" --port "$5" --nodiscover --maxpeers 5 --verbosity 2 > "$6" 2>&1 &
  echo $!
}

connect(){ # $1=sealer httpport  $2=peer httpport
  local en
  en=$(rpc "$1" '{"jsonrpc":"2.0","method":"admin_nodeInfo","id":1}' | sed -E 's/.*"enode":"([^"]*)".*/\1/')
  rpc "$2" "{\"jsonrpc\":\"2.0\",\"method\":\"admin_addPeer\",\"params\":[\"$en\"],\"id\":1}" > /dev/null
}

run_direction(){ # $1=label $2=sealer-bin $3=peer-bin
  local label="$1" sbin="$2" pbin="$3"
  echo
  echo "############################################################"
  echo "# $label"
  echo "############################################################"
  local D1="$BASE/${label}-s" D2="$BASE/${label}-p"
  rm -rf "$D1" "$D2"
  init "$sbin" "$D1"; init "$pbin" "$D2"

  local PS PP_
  PS=$(start_sealer "$sbin" "$D1" $P1 $AP1 $PP1 "$D1/n.log")
  wait_rpc $P1 || { no "$label: sealer never came up"; tail -5 "$D1/n.log"; return; }
  PP_=$(start_peer "$pbin" "$D2" $P2 $AP2 $PP2 "$D2/n.log")
  wait_rpc $P2 || { no "$label: peer never came up"; tail -5 "$D2/n.log"; stopnode "$PS"; return; }

  connect $P1 $P2

  # wait for peering
  local i connected=0
  for i in $(seq 1 40); do
    [ "$(peers $P2)" -ge 1 ] && { connected=1; break; }
    sleep 0.5
  done
  [ "$connected" -eq 1 ] && ok "$label: old/new nodes PEERED (RLPx handshake ok)" \
                         || no "$label: nodes never peered"

  # wait for sealer to make blocks and peer to follow
  for i in $(seq 1 45); do
    local h1 h2
    h1=$(head_num $P1); h2=$(head_num $P2)
    [ "$h1" -ge 6 ] && [ "$h2" -ge 5 ] && break
    sleep 1
  done
  local H1 H2
  H1=$(head_num $P1); H2=$(head_num $P2)
  echo "        sealer head=$H1  peer head=$H2"
  [ "$H1" -ge 5 ] && ok "$label: sealer produced blocks (head=$H1)" || no "$label: sealer stalled (head=$H1)"
  [ "$H2" -ge 4 ] && ok "$label: peer SYNCED blocks across versions (head=$H2)" || no "$label: peer did not sync (head=$H2)"

  # hash agreement at a common height
  local CH=4 HA HB
  HA=$(blk_hash $P1 "0x4"); HB=$(blk_hash $P2 "0x4")
  if [ -n "$HA" ] && [ "$HA" = "$HB" ]; then
    ok "$label: block #$CH hash IDENTICAL on both versions (no consensus split)"
  else
    no "$label: block #$CH hash MISMATCH ($HA vs $HB)"
  fi

  # tx submitted to the peer's endpoint must gossip to the sealer and mine.
  # A failed submit is a FAIL, not a skip: the peer has the account unlocked
  # precisely so this check can run, so an error here means the check's own
  # preconditions broke and the coverage it claims would otherwise be a lie.
  local TXH
  TXH=$(rpc $P2 "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"$SIGNER\",\"to\":\"$SIGNER\",\"value\":\"0x1\",\"gas\":\"0x5208\",\"gasPrice\":\"0x0\"}],\"id\":1}" | grep -o '"result":"0x[0-9a-f]*"' | head -1 | sed -E 's/.*:"([^"]*)"/\1/')
  if [ -n "$TXH" ] && [ "${TXH:0:2}" = "0x" ]; then
    local mined=0
    for i in $(seq 1 25); do
      rpc $P1 "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$TXH\"],\"id\":1}" | grep -q '"blockNumber"' && { mined=1; break; }
      sleep 1
    done
    [ "$mined" -eq 1 ] && ok "$label: tx gossiped across versions and mined" \
                       || no "$label: tx never mined across versions"
  else
    no "$label: tx submit on peer failed — gossip check could not run"
  fi

  local PAN
  PAN=$(cat "$D1/n.log" "$D2/n.log" 2>/dev/null | grep -ci panic || true)
  [ "$PAN" -eq 0 ] && ok "$label: zero panics on both nodes" || no "$label: $PAN panic lines"

  stopnode "$PP_"; stopnode "$PS"
}

run_direction "OLDsealer-NEWpeer" "$OLD" "$NEW"
run_direction "NEWsealer-OLDpeer" "$NEW" "$OLD"

echo
echo "================== RESULT: $PASS passed, $FAIL failed =================="
[ "$FAIL" -eq 0 ]
