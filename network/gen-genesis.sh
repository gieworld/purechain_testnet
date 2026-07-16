#!/usr/bin/env bash
# Generate a free-gas, Cancun-enabled Clique genesis.json.
#
# Usage:
#   ./gen-genesis.sh <chainId> <signer-address> [more-signer-addresses...] > genesis.json
#
# Example (two validators):
#   ./gen-genesis.sh 424242 0xAbc...01 0xDef...02 > genesis.json
#
# Notes:
#   - Clique extradata = 32-byte vanity + each signer (20 bytes) + 65-byte seal.
#     This script builds it with exact byte counts so you never hand-craft it.
#   - All listed signers are prefunded (handy even on free-gas nets for value txs).
#   - The EIP-4788 beacon-roots contract is included so Cancun matches mainnet
#     semantics (the patched geth treats it as a no-op if absent, but including
#     it is cleaner for a fresh genesis).
set -euo pipefail

CHAINID="${1:?usage: gen-genesis.sh <chainId> <signer...>}"; shift
[ "$#" -ge 1 ] || { echo "error: provide at least one signer address" >&2; exit 1; }

VANITY=$(printf '0%.0s' $(seq 1 64))   # 32 bytes
SEAL=$(printf '0%.0s' $(seq 1 130))    # 65 bytes
SIGNERS=""
ALLOC=""
for s in "$@"; do
  a=$(echo "$s" | sed 's/^0[xX]//')
  [ "${#a}" -eq 40 ] || { echo "error: '$s' is not a 20-byte (40 hex) address" >&2; exit 1; }
  SIGNERS="${SIGNERS}${a}"
  ALLOC="${ALLOC}    \"0x${a}\": { \"balance\": \"1000000000000000000000\" },\n"
done
EXTRA="0x${VANITY}${SIGNERS}${SEAL}"

B4788='    "0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02": { "balance": "0", "code": "0x3373fffffffffffffffffffffffffffffffffffffffe14604d57602036146024575f5ffd5b5f35801560495762001fff810690815414603c575f5ffd5b62001fff01545f5260205ff35b5f5ffd5b62001fff42064281555f359062001fff015500" }'

cat <<EOF
{
  "config": {
    "chainId": ${CHAINID},
    "homesteadBlock": 0,
    "eip150Block": 0,
    "eip155Block": 0,
    "eip158Block": 0,
    "byzantiumBlock": 0,
    "constantinopleBlock": 0,
    "petersburgBlock": 0,
    "istanbulBlock": 0,
    "berlinBlock": 0,
    "londonBlock": 0,
    "shanghaiTime": 0,
    "cancunTime": 0,
    "zeroBaseFee": true,
    "clique": { "period": 5, "epoch": 30000 }
  },
  "difficulty": "1",
  "gasLimit": "0x1c9c380",
  "extradata": "${EXTRA}",
  "alloc": {
EOF
printf "%b" "$ALLOC"
echo "$B4788"
cat <<EOF
  }
}
EOF
