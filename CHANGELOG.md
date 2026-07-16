# Changelog — clique-cancun branch

All changes are on top of **go-ethereum v1.13.15** (the last official Clique release).

---

## [Unreleased] — 2026-06-17 to 2026-07-02

### Overview

This branch enables **Cancun (+ Shanghai) hard forks on a Clique PoA network** without a beacon chain or PoS Merge. It also adds **free-gas (zero base fee)** support, operational tooling for in-place upgrades, and a compatibility shim for OP Stack tooling.

---

### New Features

#### Clique + Shanghai/Cancun Fork Support
`consensus/clique`, `params`, `core/evm`, `miner`

Stock go-ethereum v1.13.15 panics with *"unexpected excess blob gas value in clique"* when Shanghai/Cancun are activated on a PoA network. This is now fully supported:

- `params.Rules()` enables `IsShanghai` / `IsCancun` for Clique chains without requiring a Merge.
- `clique.verifyHeader` validates Shanghai/Cancun header fields (withdrawalsRoot, excessBlobGas, blobGasUsed, parentBeaconRoot) instead of rejecting them.
- `clique.verifyCascadingFields` validates EIP-4844 blob gas against the parent block.
- `clique.encodeSigHeader` appends post-London header fields in canonical order instead of panicking.
- `clique.FinalizeAndAssemble` emits an empty withdrawals list post-Shanghai so `withdrawalsRoot == EmptyWithdrawalsHash`.
- `miner/worker` falls back to a zero `parentBeaconRoot` when no beacon engine is present (Clique).
- `core/evm` exposes a zero PREVRANDAO for Clique post-Shanghai so opcode `0x44` does not nil-deref.

Prague and Verkle forks remain gated on PoS; non-Clique chains are unaffected.

---

#### Zero Base Fee (Free-Gas) Support
`params`, `core/eip1559`, `genesis`, `eth/backend`, `internal/ethapi`

New genesis config flag `"zeroBaseFee": true` (mirrors Besu behavior) for networks where all transactions must be free:

- `CalcBaseFee` returns `0` when `ZeroBaseFee` is set; block production and header verification stay consistent.
- Genesis default base fee is set to `0` when flag is active.
- `--miner.gasprice 0` is accepted **on `zeroBaseFee` chains** (previously rejected outright); on any other chain a zero is still sanitized back to the default.
- JSON-RPC guards on `gasPrice`/`maxFeePerGas` are relaxed so zero-fee transactions can be submitted via `eth_sendTransaction` / `eth_sendRawTransaction`.

**Known limitation:** same-nonce replacement (RBF) cannot work at uniform zero price since the txpool requires a strictly higher fee for replacement. This is rarely an issue on a fast PoA chain.

---

#### `eth_blobBaseFee` RPC Endpoint
`internal/ethapi`

Backport of the `eth_blobBaseFee` RPC method (added upstream after v1.13.15). Required for **OP Stack** compatibility: `op-batcher` and `op-proposer` call this unconditionally during gas estimation even for calldata transactions. Without it, the batcher fails every send against a Clique-Cancun L1 and the L2 safe head never advances.

Returns the blob base fee computed from `ExcessBlobGas` via `eip4844.CalcBlobFee` (returns 1 wei on a chain with no blobs). Nil-safe for pre-Cancun heads. Purely additive, read-only, non-consensus.

---

### Bug Fixes

#### `miner/worker` — Populate Cancun Header Fields After `clique.Prepare`
`miner/worker`

`prepareWork` decided whether to add the Cancun header fields (`excessBlobGas`, `blobGasUsed`, `parentBeaconRoot`) using `header.Time` **before** calling `engine.Prepare`. Clique's `Prepare` rewrites `header.Time` to `max(parent.Time + period, now)`, so at a timed Cancun activation a block prepared while `now < cancunTime` whose final time landed `≥ cancunTime` was sealed **without** the blob fields. The miner commits its own block without re-verifying it, so the malformed block was accepted locally and building the *next* block then nil-dereferenced `*parent.ExcessBlobGas` → miner panic (peers also reject the bad block).

The EIP-4844/4788 field population now runs **after** `engine.Prepare`, gated on the final `header.Time`. This is a no-op for PoS (fixed timestamp) and for genesis-activated Cancun.

**Scope:** only affects a *timed* in-place Cancun activation on a chain with `clique.period ≥ 2`. At `period 1` the pre- and post-`Prepare` timestamps are algebraically identical, so the bug cannot arise; a genesis-activated chain (`cancunTime: 0`) has no boundary. Covered by the hardened `transition.sh` regression test below.

#### `eth/fetcher` — Preserve Withdrawals When Reassembling Announced Blocks
`eth/fetcher/block_fetcher`

The block fetcher reassembles blocks that arrive via `NewBlockHashes` announcements (header + body fetched separately), which is the propagation path for any peer that announces a block by hash rather than sending the full body. Upstream go-ethereum **discards the withdrawals list** on this path (`// Ignoring withdrawals here, since the block fetcher is not used post-merge.`), because on a PoS network block gossip is disabled after the Merge. A Clique/Cancun chain never merges, so the fetcher stays active and rebuilt every announced post-Shanghai block with a **nil** withdrawals list — while its header commits to `EmptyWithdrawalsHash`. Body validation then rejected the block with `missing withdrawals in block body` (`BAD BLOCK`).

Two reassembly paths were affected:
- **Body-completion path** — `WithBody(txs, uncles)` inherited a nil withdrawals slice from the header-only base block; the fetched body's withdrawals were dropped entirely (`Unpack()`'s third return value ignored).
- **Empty-body short circuit** — header-only blocks (no txs/uncles, the common case on a `period 1` chain) were built with `NewBlockWithHeader` and never given a withdrawals slice.

Both now attach the withdrawals list: the fetched body's list is threaded through `bodyFilterTask` → `FilterBodies` → block reassembly, and empty post-Shanghai blocks receive a non-nil empty slice matching `EmptyWithdrawalsHash`. Consensus safety was never at risk — `ValidateBody` correctly rejected the malformed body — but liveness was: the failure was intermittent (the direct `NewBlock` full-block path preserves withdrawals, so a competing delivery usually imported the block moments later), and under load or same-height block contention a node could latch onto a minority chain and stall until restarted. Regression-tested by `TestFetcherReassemblesWithdrawals`, which drives both reassembly paths and asserts the reconstructed block carries a non-nil withdrawals list matching the header commitment.

#### `internal/era` — Preserve Withdrawals in Era1 Block Reconstruction
`internal/era/era.go`, `internal/era/iterator.go`

Same root cause as the fetcher fix, on the Era1 history export/import path. `Era.Block` and `Iterator.Block` decode a full `types.Body` (which includes withdrawals) but rebuilt the block with `WithBody(body.Transactions, body.Uncles)`, dropping the withdrawals list. A post-Shanghai block read back from an Era1 archive would therefore fail re-import with `missing withdrawals in block body`. Both sites now append `.WithWithdrawals(body.Withdrawals)`.

**Scope:** only reachable via `geth export-history` / `import-history`; not exercised by normal p2p sync or block gossip. Fixed for correctness completeness — low exposure on this deployment.

#### `core/txpool/blobpool` — Don't Log a Per-Block Error When There Is No Finalized Block
`core/txpool/blobpool/blobpool.go`

On every new chain head after Cancun, the blob pool called `limbo.finalize(chain.CurrentFinalBlock())` to evict blobs older than finality. On a Clique chain there is no beacon chain and no finality gadget, so `CurrentFinalBlock()` is always nil and `finalize` logged `Nil finalized block cannot evict old blobs` at **error** level once per block — misleading operator noise. The call is now guarded on a non-nil finalized block (`finalize(nil)` was already a no-op, so behavior is unchanged; only the spurious error log is removed).

**Note:** the blob pool remains effectively idle on this chain (it only admits type-3 blob transactions, which a free-gas Clique network does not produce). If blob transactions were ever mined here, limbo eviction would need to key off a reorg-depth window rather than finality — out of scope for the current zero-blob deployment.

#### `NewEVMBlockContext` Nil-Deref Guard
`core/evm`

The Clique PREVRANDAO fix accesses `chain.Config()`, but block generation code (`BlockGen.AddTx`) passes a `(*BlockChain)(nil)` as `ChainContext` — a non-nil interface wrapping a nil pointer. A plain `chain != nil` check passes and `Config()` then nil-derefs.

Added `chainContextIsNil()` to detect both untyped-nil interfaces and typed-nil pointers. Fixes a panic in `TestEstimateGas` and any chain-generation path.

#### `txpool/legacypool` — Allow Price Limit of Zero
`core/txpool/legacypool`

Non-mining RPC/relay nodes on a free-gas network must run `--txpool.pricelimit 0`. Previously the pool floor was hardcoded to 1 wei, causing those nodes to silently drop and refuse to relay zero-fee transactions from peers. Now `PriceLimit == 0` is allowed **on `zeroBaseFee` chains**; on any other chain the 1-wei floor is retained (a zero is sanitized back to the default) so a misconfigured node cannot accept and gossip unmineable zero-fee spam. `sanitize()` takes the chain config to make this decision.

#### `clique.verifyHeader` — Enforce Zero `parentBeaconRoot`
`consensus/clique`

`verifyHeader` now requires `parentBeaconRoot` to be the zero hash on Cancun blocks (the only legitimate value without a beacon chain; the miner always produces it). Previously any non-nil value was accepted, which would allow a misbehaving signer to write arbitrary data via EIP-4788.

---

### Tests

#### MetaMask / Wallet RPC Compatibility Test
`smoke-test/metamask-compat.sh`

Exercises every RPC endpoint MetaMask calls during fee estimation: `eth_feeHistory`, `eth_maxPriorityFeePerGas`, `eth_gasPrice`, `eth_blobBaseFee`, and `eth_getBlockByNumber`. Asserts `baseFeePerGas: 0x0` is present in block headers and that a zero-fee EIP-1559 tx is accepted and mined. These calls all fail or error on a pre-London Istanbul node.

#### ethers.js v6 Compatibility Test
`smoke-test/ethers-compat.sh`

Node.js harness (installs ethers v6 into a temp directory via npm) that connects a `JsonRpcProvider`, calls `getFeeData()` (which internally calls `eth_feeHistory`), then sends and confirms both a legacy (type 0) and EIP-1559 (type 2) zero-fee transaction. Skips gracefully when Node/npm are not installed. On an Istanbul node, `getFeeData()` throws because `eth_feeHistory` does not exist.

#### PUSH0 Opcode (EIP-3855 / Shanghai) Test
`smoke-test/push0.sh`

Deploys hand-crafted bytecode that uses the PUSH0 opcode (0x5f) for every zero push, calls the contract, and asserts the return value is 42. Also verifies the stored on-chain bytecode contains `5f`. Solidity 0.8.20+ emits PUSH0 by default (`--evm-version shanghai`); on a pre-Shanghai node the opcode is `INVALID` and every such contract reverts.

#### Clique + Cancun Mining Smoke Test
`smoke-test/run.sh`

Self-contained script that boots a 1-second-period Clique chain with `shanghaiTime=0` / `cancunTime=0`, imports a signer, mines for 12 seconds, and checks for block-sealing vs panic markers. Used to A/B the patched geth against the baseline.

#### In-Place Istanbul → Cancun Transition Test
`consensus/clique` (Go test)

Proves an existing Istanbul-only Clique chain can be upgraded in place to Berlin + London + Shanghai + Cancun via genesis re-init with future fork block numbers. Verifies:
- Genesis hash is unchanged after re-init.
- Pre-fork blocks are preserved.
- Chain continues monotonically across all forks.
- No panic.
- The chain tip is a valid Cancun block (`excessBlobGas` set, `withdrawalsRoot == EmptyWithdrawalsHash`).

#### Fork-Boundary Timing Regression
`smoke-test/transition.sh`, `smoke-test/transition-prod.sh`

`transition.sh` now mines across a **timed** Shanghai/Cancun activation at `clique.period 5` — the configuration that actually exercises the miner fork-boundary fix above — and enforces a hard pass/fail: genesis hash stable, chain advances past the fork, **zero panics**, no Cancun-field header errors, and the tip carries `excessBlobGas`. Verified to **FAIL** on the pre-fix binary (miner panic, chain stalled at the boundary) and **PASS** on the fixed binary (clean crossing). `transition-prod.sh` keeps the real `period 1` production parameters — where the timing bug cannot arise — and gained the same pass/fail guards plus a note pointing to `transition.sh` for period ≥ 2 coverage.

#### Rigorous In-Place Upgrade Test (stock → patched, 22 checks)
`smoke-test/upgrade-rigorous.sh`

End-to-end upgrade harness that goes beyond "the chain keeps producing blocks" and exercises the failure modes that actually corrupt funds or split a network. Stock geth builds a **real** Istanbul chain (deployed storage contract, funded accounts, recorded state); the patched binary then re-inits in place and crosses London + Shanghai + Cancun. Five phases, 22 assertions:

- **State continuity** — every account balance/nonce, and the Istanbul-era contract's code *and* storage slot, are byte-identical after the fork; the contract is still callable.
- **Block immutability** — pre-fork block hashes are unchanged (no silent reorg); genesis hash preserved.
- **Genesis safety** — an in-place re-init that only *adds* fork fields keeps the hash; a tampered genesis (changed `gasLimit`) is rejected.
- **Consensus** — a **second** patched node syncs the chain over p2p and must agree on the exact head hash across the fork (catches seal-hash field-ordering divergence — the scariest bug class) and replicates contract storage.
- **Fork boundary** — stock geth pointed at the upgraded datadir panics (`unexpected withdrawal hash value in clique`), confirming the boundary holds.
- Also confirms a PUSH0 contract *cannot* deploy on Istanbul but *can* after Shanghai, and zero-fee txs mine post-Cancun.

Verified green twice against `build/bin/geth` (patched) and `build/bin/geth-original` (stock).

#### Rollback-to-Stock Safety Test
`smoke-test/rollback.sh`

Empirically establishes when you can revert from the patched binary back to stock
geth. 8 assertions across two regimes:

- **Before activation — safe (4/4).** Stock geth reads a datadir the patched binary
  wrote, keeps mining pre-fork blocks, no panic, pre-fork block hashes unchanged.
- **After activation — blocked.** Stock geth panics (`unexpected withdrawal hash
  value in clique`) on the Cancun chain; the test then demonstrates the supported
  recovery: restoring the pre-upgrade datadir backup runs on stock geth again.

Surfaces the key operational rule: the point of no return is the activation
timestamp (and, with `zeroBaseFee`, the `londonBlock` — since stock geth rejects
zero-baseFee London blocks), **not** the binary swap. Schedule forks in the future
and keep a backup for a clean abort window.

#### Fee-Toggle Reference Test
`smoke-test/fee-toggle.sh`

Documents and proves the escape hatch for the free-gas product: a `zeroBaseFee`
network can charge gas fees at any time with **no fork, genesis change, or chain
reset** — purely via a minimum priority tip (`--miner.gasprice` /
`--txpool.pricelimit` / `--txpool.nolocals`), fully reversible. 5/5: a zero-fee tx
is rejected (`transaction underpriced`), a tip-paying tx mines with
`effectiveGasPrice == tip`, and the header base fee stays `0x0`. Includes the note
that flipping `zeroBaseFee` off does **not** work (EIP-1559 base fee can't bootstrap
from 0). See the "If you ever need to charge gas fees later" section of the operator
guide.

---

### Documentation & Tooling

#### Istanbul → Cancun In-Place Upgrade Runbook
`docs/upgrade-runbook.md`, `smoke-test/transition-prod.sh`

Operator runbook for upgrading an existing Clique network to Cancun + free-gas **without resetting the chain**:
- Capture and verify genesis hash before upgrade.
- Back up datadir.
- Set future fork activation timestamps.
- Run `geth init` in place with the upgraded genesis.
- Restart with new flags.
- Verify Cancun tip fields and `baseFeePerGas: 0x0`.
- Rollback procedure.

Rehearsal script (`transition-prod.sh`) exercises the exact flow with representative production-like parameters (chainId `424242`, `gasLimit 0xffffffffffffff`, `period 1`).

#### Production Free-Gas Cancun Genesis & README
`network/genesis.json`, `network/gen-genesis.sh`, `docs/operator-guide.md`

- `gen-genesis.sh`: generates a free-gas Cancun Clique genesis from a chain ID and signer list, building Clique extradata with exact byte counts and including the EIP-4788 contract.
- `genesis.json`: ready-to-use example (chainId `424242`, one signer); verified to `geth init` cleanly with `baseFee: 0`.
- `docs/operator-guide.md`: concise operator guide covering what changed, how to build (WSL), create/run a network, send zero-fee transactions, known caveats, and the in-place upgrade path.

#### Clique + Cancun Implementation Plan & Security Audit
`docs/implementation-plan.md`

Design document covering the implementation approach with a line-by-line audit of consensus risks: PREVRANDAO nil-deref, `encodeSigHeader` panic, imported-withdrawals gap, and backward-compatibility notes.

---

### Verification — A/B Results (patched vs stock v1.13.15)

Every smoke test was run against both binaries (`build/bin/geth` = patched,
`build/bin/geth-original` = stock v1.13.15) using the same free-gas Cancun genesis.

| Test | Patched geth | Original geth v1.13.15 |
|---|---|---|
| `metamask-compat.sh` | **20 / 20 pass** | **5 / 20** — node panics; every fee RPC (`eth_feeHistory`, `eth_blobBaseFee`, header `baseFeePerGas`) returns empty |
| `push0.sh` | **5 / 5 pass** | **0 / 3** — node panics; PUSH0 contract never deploys |
| `ethers-compat.sh` | **11 / 11 pass** | **FATAL `ECONNREFUSED`** — RPC never comes up |
| `transition-prod.sh` | builds on stock, **continues on patched** | n/a (control) |

**Root cause on stock geth** (from the node log, identical across all runs):

```
WARN  Sanitizing invalid miner gas price     provided=0 updated=1,000,000,000
WARN  Sanitizing invalid txpool price limit  provided=0 updated=1
panic: unexpected excess blob gas value in clique
```

One failure demonstrates all three patched areas at once: stock geth (1) panics
the instant the miner seals a Cancun-in-Clique block, (2) rewrites
`--miner.gasprice 0` → 1 gwei, and (3) rewrites `--txpool.pricelimit 0` → 1 wei.
The patched binary emits **neither warning** and mines zero-fee txs with
`effectiveGasPrice: 0x0`.

### Backward Compatibility

Verified by `transition-prod.sh`, which builds the chain with **stock geth** and
then continues it with the **patched** binary on the same datadir:

- ✅ **Patched binary reads stock chains.** Genesis hash is byte-identical
  (`d7192e..8bac74` on both); the patched binary read a datadir that stock geth
  created at block 6 and continued it to block 31 with zero panics, then crossed
  London → Shanghai → Cancun. Pre-fork blocks are processed identically — drop the
  new binary onto an existing Istanbul network without resetting the chain.
- ❌ **Stock geth cannot follow past activation.** Once the chain crosses
  `shanghaiTime`/`cancunTime`, stock geth panics and diverges. This is an
  intentional hard-fork boundary (true of any fork): **upgrade every node to the
  patched binary before the activation timestamp.**

---

### Base

| Item | Value |
|---|---|
| Upstream base | go-ethereum v1.13.15 |
| Base commit | `c5ba367eb` |
| Branch | `clique-cancun` |
| Supported forks | Istanbul → Berlin → London → Shanghai → Cancun |
| Merge / PoS required | No |
| Beacon chain required | No |

### Release Binary (linux/amd64)

Deployable build of the patched node:

| Item | Value |
|---|---|
| Artifact | `build/bin/geth-linux-amd64` |
| `geth version` | `1.13.15-stable` |
| Git commit | `df31f81fdb360dd8a540286fee10e959f7d3cade` |
| Target | linux/amd64, statically linked (`CGO_ENABLED=0`) — runs on any Linux x86-64, incl. Alpine |
| Go | go1.21.12 |
| Built | 2026-07-05 |

Reproduce:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o build/bin/geth-linux-amd64 ./cmd/geth
geth version   # Git Commit must read df31f81f...
```

> Supersedes the earlier `96545ba1c` build. This build adds the block-fetcher
> withdrawals fix (and the Era1 / blob-pool-log fixes) above; rebuild and
> redeploy all nodes to pick it up. No genesis, config, or on-disk format
> change — a straight binary swap and restart.

> The stock baseline `build/bin/geth-original-linux-amd64` (upstream v1.13.15 @ `c5ba367eb`)
> is a **test-only** binary for the A/B upgrade harness — do not deploy it.
> Binaries live under `build/bin/` (git-ignored); rebuild from source per above.
