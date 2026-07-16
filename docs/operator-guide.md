# geth v1.13.15 — Clique + Cancun + Free Gas (private-network fork)

A patched go-ethereum **v1.13.15** that lets a **Clique (PoA)** network run the
**Shanghai** and **Cancun** hard forks **without a beacon chain**, with optional
**free gas** (zero base fee). Upstream Clique stops at London and was removed in
geth v1.14; this fork keeps it alive for private/permissioned networks.

Full design + security audit: [`implementation-plan.md`](implementation-plan.md).

## What changed vs upstream v1.13.15

| Area | Files | Summary |
|------|-------|---------|
| Clique → Cancun | `consensus/clique/clique.go`, `params/config.go`, `core/evm.go`, `miner/worker.go` | Accept Shanghai/Cancun headers, seal them (no panic), enable EVM forks for Clique, zero PREVRANDAO + zero parentBeaconRoot |
| Free gas | `params/config.go`, `consensus/misc/eip1559/eip1559.go`, `core/genesis.go`, `eth/backend.go`, `internal/ethapi/transaction_args.go` | `zeroBaseFee` genesis flag pins base fee to 0; allow `--miner.gasprice 0`; accept zero-fee txs over RPC |
| Fixes | `core/evm.go` | typed-nil `ChainContext` guard |

Non-Clique chains (mainnet/PoW/PoS) are unaffected — every change is gated on
`Clique != nil` / `zeroBaseFee` / `IsShanghai`.

## Build

**Recommended — portable static binary (this is the deployed release artifact).**
Works from any OS with the Go toolchain; produces a statically linked linux/amd64
binary that runs on any Linux x86-64, including minimal/Alpine containers:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o build/bin/geth-linux-amd64 ./cmd/geth
./build/bin/geth-linux-amd64 version   # -> 1.13.15-stable, Git Commit = your HEAD
```

See the CHANGELOG **"Release Binary (linux/amd64)"** section for the exact commit
of the current deployed build.

**Alternative — native build on WSL.** If you build *inside* WSL, use the native
filesystem — building on the Windows `/mnt/d` mount crashes the Go compiler (9p mount):

```bash
rsync -a --delete --exclude='.git' --exclude='build/bin' \
  /mnt/d/Projects/geth_cancun/ ~/geth_build/
cd ~/geth_build && go build -o geth ./cmd/geth
cp geth /mnt/d/Projects/geth_cancun/build/bin/geth
```

## Create a network

Generate a genesis from your chain ID + validator (signer) address(es). **Run the
generator inside WSL** so the file is written as UTF-8 (PowerShell redirects produce
UTF-16, which geth rejects):

```bash
bash network/gen-genesis.sh <chainId> <signer1> [signer2 ...] > network/genesis.json
```

A ready example (`network/genesis.json`) uses chain ID `424242` and one signer.
Edit before production: set your own `chainId`, your validator address(es), and
prefund the accounts you need.

Key genesis settings (already set):
- All forks at `0` incl. `shanghaiTime`/`cancunTime` → **Cancun from genesis**
- `"zeroBaseFee": true` → **free gas**
- `clique.period` = 5s block time; `gasLimit` = 30,000,000 (raise via genesis **and**
  `--miner.gaslimit` if you need bigger blocks)

## Run a signer node

```bash
geth --datadir <dir> init network/genesis.json          # once
geth --datadir <dir> account import <signer-key>         # once, per signer

geth --datadir <dir> --networkid <chainId> \
  --unlock <signer> --password <pwfile> --allow-insecure-unlock \
  --mine --miner.etherbase <signer> --miner.gasprice 0 \
  --txpool.pricelimit 0 \
  --http --http.addr 0.0.0.0 --http.api eth,net,web3 \
  --bootnodes <enode>            # peers; omit on the first node
```

> **Free gas requires `--txpool.pricelimit 0` on _every_ node**, including
> non-mining RPC/relay nodes. Without it a node's tx-pool floor stays at 1 wei and
> it will silently drop and refuse to relay zero-fee transactions from peers.

## Send a zero-fee transaction

Submit over JSON-RPC (legacy or EIP-1559 with zero fees):

```bash
curl -s http://127.0.0.1:8545 -H 'Content-Type: application/json' --data \
 '{"jsonrpc":"2.0","method":"eth_sendTransaction","params":[{"from":"0x..","to":"0x..","value":"0x1","gasPrice":"0x0"}],"id":1}'
```

## Caveats

- **Every node must run this binary and the same genesis.** Past the Shanghai/Cancun
  activation, stock geth cannot follow the chain — it's a deliberate hard-fork boundary.
- **Console can't send zero-fee txs:** the bundled `web3.js` blocks it client-side.
  Use JSON-RPC or a modern library (ethers / web3 v4) — the node accepts them.
- **No RBF at zero price:** a pending tx can't be replaced/cancelled when all fees are
  0 (the pool needs a strictly higher fee). Rare on a 5s PoA chain.
- **Free gas = no economic spam cost.** Protection is the permissioned signer set +
  block gas limit + txpool per-account limits — keep RPC access restricted.
- **Contract size stays 24 KB** (EIP-170). Use proxy/library patterns for larger code.
- **`zeroBaseFee` affects the genesis hash only if London is active at block 0.** On a
  fresh free-gas chain (London at 0) the genesis starts at base fee 0 — fine. When
  upgrading an existing chain in place, London activates at a *future* block, so block 0
  stays pre-London and the genesis hash is unchanged (required for `geth init` to accept
  the existing data). Do not add `zeroBaseFee` to a chain that already had London at genesis.

## Verify / test

```bash
bash smoke-test/run.sh             <geth>          # mine Cancun blocks without panic
bash smoke-test/freegas-rpc.sh     <geth>          # zero-fee tx mines with effectiveGasPrice 0
bash smoke-test/metamask-compat.sh <geth>          # MetaMask / wallet RPC (eth_feeHistory etc.)
bash smoke-test/push0.sh           <geth>          # PUSH0 opcode — Solidity 0.8.20+ contracts
bash smoke-test/ethers-compat.sh   <geth>          # ethers.js v6 provider + tx sending
bash smoke-test/transition.sh      <geth>          # Istanbul -> Cancun in-place upgrade
bash smoke-test/transition-prod.sh <orig> <patched> # production-param rehearsal
bash smoke-test/upgrade-rigorous.sh <orig> <patched> # full upgrade audit (state, consensus, 22 checks)
bash smoke-test/rollback.sh        <orig> <patched> # rollback-to-stock safety (before/after activation)
bash smoke-test/fee-toggle.sh      <geth>          # introduce gas fees via a min tip (escape hatch)
```

The **rigorous upgrade test** is the one to run before a production upgrade: it
builds a real Istanbul chain on stock geth (contract + funded accounts), re-inits
in place with the patched binary, crosses every fork, and asserts state/balances/
contract storage survive byte-for-byte, pre-fork blocks don't reorg, a second node
agrees on head hashes across the fork, and stock geth refuses the post-fork chain.

## Upgrading an existing Istanbul chain

Keep the original genesis params byte-identical, add the new fields with **future**
activation (`berlinBlock`/`londonBlock` above current head; `shanghaiTime`/`cancunTime`
in the future; `zeroBaseFee` if wanted), then `geth init <updated-genesis>` on each
node's datadir (updates config, preserves the chain). Upgrade all nodes before
activation. London turns on EIP-1559 — `zeroBaseFee` keeps it free.

See the full step-by-step runbook: [`upgrade-runbook.md`](upgrade-runbook.md).

## Rolling back to stock geth

Rollback is reversible **only up to the first consensus-affecting fork your config
enables** — verified by `smoke-test/rollback.sh`:

- **Before activation — safe.** Stock geth reads a datadir the patched binary wrote
  and keeps mining; pre-fork block hashes are unchanged. With `zeroBaseFee` set, the
  binding limit is **`londonBlock`** (not Shanghai): once London is crossed, patched
  nodes write `baseFee: 0` blocks that stock geth rejects (it computes a non-zero
  baseFee). Without `zeroBaseFee`, the limit is `shanghaiTime`/`cancunTime`.
- **After activation — blocked.** Stock geth panics on Cancun header fields
  (`unexpected withdrawal hash value in clique`) and cannot read the chain. Recovery
  is restoring the **pre-upgrade datadir backup** (Phase 2 of the runbook) or
  rewinding every node past the fork — not a simple binary swap.
- **Config persistence.** After `geth init`, the stored config still carries
  `cancunTime`/`zeroBaseFee`. Stock geth drops `zeroBaseFee` (unknown field) but
  honours `cancunTime`, so a rolled-back stock node runs pre-fork and then panics
  when wall-clock passes `cancunTime`. To fully revert, restore the pre-upgrade
  genesis/datadir — swapping only the binary does not un-schedule the fork.

**Takeaway:** schedule forks comfortably in the future and keep the backup; you have
a clean abort window right until activation.

## If you ever need to charge gas fees later

The network ships as free gas, but that is **not a one-way door**. You can introduce
a fee at any time with **no fork, no genesis change, and no chain reset** — it is
pure node policy and is fully reversible. Verified by `smoke-test/fee-toggle.sh`.

Use a **minimum priority tip**, not the base fee. On every node:

```bash
--miner.gasprice <tip-wei>        # miner won't include txs paying less
--txpool.pricelimit <tip-wei>     # pool rejects txs paying less
--txpool.nolocals                 # apply the floor to this node's own RPC submissions too
```

With e.g. `tip = 1000000000` (1 gwei): zero-fee txs are rejected (`transaction
underpriced`), and a paying tx mines with `effectiveGasPrice == tip`. The base fee
stays `0x0`, so the entire fee is the tip and goes to your **signer** (nothing is
burned). To return to free gas, set the limits back to `0` and drop `--txpool.nolocals`,
then restart. Both directions take effect on restart, per node.

> **Don't try to do this by turning off `zeroBaseFee`.** EIP-1559's base fee is
> multiplicative on the parent's, so it cannot rise from 0 by more than 1 wei per
> block (≈31 years to reach 1 gwei at 1s blocks). Flipping the flag is also a
> consensus change requiring a coordinated restart — all cost, no benefit. The tip
> mechanism above is the supported path. (A true burned-base-fee market would need a
> scheduled `zeroBaseFee` deactivation that reseeds the base fee to `InitialBaseFee`;
> that is not implemented — ask if you ever actually need it.)

**When this matters:** the usual reason to want fees is spam/DoS pressure. On a
permissioned PoA chain that is handled by the signer set + restricted RPC + gas
limits, so free gas is safe as long as RPC access stays controlled. Opening RPC
more widely is the signal to reach for the tip knob — not the branding.
