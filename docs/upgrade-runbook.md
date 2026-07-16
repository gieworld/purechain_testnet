# Upgrade Runbook: Istanbul → Cancun (in place, free gas)

Upgrade an existing **Clique** network from **Istanbul** to **Cancun** with **free
gas**, **without resetting the chain**. Example parameters below (substitute your
network's own values — chainId, signer, period, gas limit):

- chainId `424242`, signer `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
- `clique.period` 1s, `gasLimit` `0xffffffffffffff`

> **The one rule that matters:** the genesis block hash must stay **identical**.
> Only ADD `config` fork entries (at FUTURE activation points) + `zeroBaseFee`.
> Change nothing else in the genesis. If the hash changes, `geth init` refuses and
> you'd be starting a different chain.

This is a **hard fork**: every node must run the patched binary and the updated
genesis **before** the activation point, or the chain splits at activation.

---

## Phase 0 — Prerequisites

- [ ] Patched `geth` binary built (this fork). Check: `geth version` → `1.13.15-stable`, and the `Git Commit` matches your release commit (see the CHANGELOG **"Release Binary (linux/amd64)"** section).
- [ ] You can stop/start every node and have shell access to each datadir.
- [ ] A maintenance window (brief restart of all nodes).

---

## Phase 1 — Capture current state (per node)

Record these so you can verify nothing changed unexpectedly:

```bash
# genesis hash (MUST stay the same after upgrade)
geth attach --exec 'eth.getBlock(0).hash' <ipc-or-rpc>
# current head (you'll pick the London block above this)
geth attach --exec 'eth.blockNumber' <ipc-or-rpc>
```

- [ ] Genesis hash recorded: `________________`
- [ ] Current head recorded: `________`

---

## Phase 2 — Back up every node

```bash
# stop the node first, then:
cp -r <datadir> <datadir>.bak-$(date +%Y%m%d)
```

- [ ] All node datadirs backed up. (This is your rollback — see Phase 7.)

---

## Phase 3 — Choose the activation points

| Field | Value | Rule |
|-------|-------|------|
| `berlinBlock`, `londonBlock` | current head **+ buffer** (e.g. +300) | must be a future block, above every node's head |
| `shanghaiTime`, `cancunTime` | a Unix time **after** all nodes are restarted **and** after the chain reaches `londonBlock` | future timestamp; `date -d '+30 min' +%s` |

Example: head ≈ 1,000,000 → `londonBlock: 1000300`; activate forks ~30 min out →
`shanghaiTime`/`cancunTime` = `<now+1800>`. With `period:1`, block 1,000,300 is
~300s away, well before the timestamp. Keep `berlinBlock == londonBlock` and
`shanghaiTime == cancunTime`.

- [ ] `FUTURE_BLOCK` chosen: `________`
- [ ] `FUTURE_UNIX_TIME` chosen: `________`

> **Note on `clique.period`:** this network is `period 1`, where the miner's fork
> timing is exact. On chains with `clique.period ≥ 2`, the signer prepares a block
> a few seconds before its slot, so the block that crosses `cancunTime` is decided
> against a timestamp earlier than the one it is finally sealed with. The miner
> populates the Cancun header fields from the *final* timestamp (fixed in this
> build), so the activation block is well-formed regardless of period — no special
> handling needed. Regression-tested by `smoke-test/transition.sh` at `period 5`.

---

## Phase 4 — Prepare the upgraded genesis

Save as `upgraded-genesis.json` — **identical to your current genesis except the 5
lines added in `config`**. Replace the two `<...>` values from Phase 3.

```json
{
    "config": {
        "chainId": 424242,
        "homesteadBlock": 0,
        "eip150Block": 0,
        "eip155Block": 0,
        "eip158Block": 0,
        "byzantiumBlock": 0,
        "constantinopleBlock": 0,
        "petersburgBlock": 0,
        "istanbulBlock": 0,
        "berlinBlock":  <FUTURE_BLOCK>,
        "londonBlock":  <FUTURE_BLOCK>,
        "shanghaiTime": <FUTURE_UNIX_TIME>,
        "cancunTime":   <FUTURE_UNIX_TIME>,
        "zeroBaseFee": true,
        "clique": { "period": 1, "epoch": 30000 }
    },
    "nonce": "0x0ada",
    "extraData": "0x0000000000000000000000000000000000000000000000000000000000000000f39Fd6e51aad88F6F4ce6aB8827279cffFb922660000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
    "gasLimit": "0xffffffffffffff",
    "difficulty": "1",
    "mixHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
    "coinbase": "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
    "alloc": {
        "f39Fd6e51aad88F6F4ce6aB8827279cffFb92266": {
            "balance": "1000000000000000000000000000000"
        }
    },
    "number": "0x0",
    "gasUsed": "0x0",
    "parentHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
    "baseFeePerGas": null
}
```

> Save the file as **UTF-8** (not UTF-16). On Windows, write it with an editor set to
> UTF-8, or generate it inside WSL — a PowerShell `>` redirect produces UTF-16 and
> geth will reject it with `invalid character 'ÿ'`.

- [ ] `upgraded-genesis.json` prepared and copied to every node.

---

## Phase 5 — Apply in place (per node)

Do this on **every** node:

```bash
# 1. stop the node (graceful)
# 2. swap in the patched geth binary
# 3. update the chain config in place (does NOT wipe the chain):
geth --datadir <datadir> init upgraded-genesis.json
```

Expected: `Successfully wrote genesis state ... hash=<SAME AS PHASE 1>`.

- [ ] Every node re-initialized; **genesis hash matches Phase 1** on each.

If the hash differs or init errors → **stop**. A genesis field was altered. Restore
from backup (Phase 7) and fix the genesis before retrying.

---

## Phase 6 — Restart and verify

Restart each signer node (free-gas flags included):

```bash
geth --datadir <datadir> --networkid 424242 \
  --unlock 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  --password <pwfile> --allow-insecure-unlock \
  --mine --miner.etherbase 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  --miner.gasprice 0 --miner.gaslimit 0xffffffffffffff \
  --txpool.pricelimit 0 \
  --http --http.addr 0.0.0.0 --http.api eth,net,web3 \
  --bootnodes <enodes-of-other-nodes>
```

**Immediately after restart (still pre-fork):**
- [ ] Chain keeps advancing (`eth.blockNumber` increasing), peers connected.
- [ ] No `does not support` / `panic` in logs.

**After `FUTURE_BLOCK` (London) is reached:**
- [ ] Blocks still sealing. Note the gas limit roughly doubles at the London block
      (EIP-1559 target/max split) — expected, harmless with zero base fee.

**After `FUTURE_UNIX_TIME` (Shanghai+Cancun):**
- [ ] `eth.getBlock('latest').baseFeePerGas` → `0` (free gas active).
- [ ] `eth.getBlock('latest').withdrawalsRoot` and `excessBlobGas` are present
      (Cancun active).
- [ ] Send a zero-fee tx over RPC and confirm it mines with `effectiveGasPrice` 0:
```bash
curl -s http://127.0.0.1:8545 -H 'Content-Type: application/json' --data \
 '{"jsonrpc":"2.0","method":"eth_sendTransaction","params":[{"from":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","to":"0x0000000000000000000000000000000000000001","value":"0x1","gasPrice":"0x0"}],"id":1}'
```
- [ ] All nodes report the **same** block hashes at the same height (no split).

---

## Phase 7 — Rollback (if anything goes wrong before activation)

Before the activation block/time, rollback is trivial — nothing has forked yet:

```bash
# stop node, restore the pre-upgrade datadir + old binary, restart
rm -rf <datadir> && mv <datadir>.bak-<date> <datadir>
```

After activation, rollback means rewinding past the fork on all nodes (set
activation points to the future again and `debug.setHead` / re-sync) — avoid by
testing first (see below) and keeping the activation window comfortably ahead.

---

## Notes & caveats

- **All nodes, same binary + same genesis.** Stock geth cannot follow the chain past
  activation.
- **`--txpool.pricelimit 0` on every node** (mining and non-mining). Without it a node's
  tx-pool floor stays at 1 wei and it silently drops / won't relay zero-fee txs from peers.
- **Zero-fee txs:** submit via JSON-RPC or a modern library (ethers / web3 v4). The
  bundled geth console (`web3.js`) blocks zero-price txs client-side; the node accepts them.
- **No RBF at zero price:** a pending tx can't be replaced/cancelled when all fees are 0.
  Rare on a 1s chain.
- **Free gas = no economic spam limit.** Protection is your permissioned signer + the
  block gas limit + txpool per-account limits. Keep RPC access restricted.
- **Contract size stays 24 KB** (EIP-170).
- **EIP-4788 contract is absent** (can't add to alloc without changing the genesis hash);
  the beacon-root system call is a harmless no-op on this chain.

---

## Recommended: rehearse first

Before touching production, run the rehearsal script against a **copy of this exact
genesis** to confirm a clean Istanbul→Cancun crossing (same genesis hash, no panic,
free gas live):

```bash
bash smoke-test/transition-prod.sh <geth>
```
