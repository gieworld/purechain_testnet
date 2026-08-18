# Changelog — PureChain execution client

All changes are on top of **go-ethereum v1.13.15** (the last official Clique release).

---

## [Unreleased] — 2026-08-13 — upgrade rehearsal harness

### Added — `rehearsal/`: a dress-rehearsal harness for node upgrades

A 6-node Docker network (4 signers + 2 non-signing RPC nodes) for rehearsing a
binary upgrade before it touches a real deployment. It is deliberately built to
resemble an operating network rather than a test fixture: full sync, archive
gcmode, `snapshot=false`, bounded memory, SIGINT with a long grace period,
static peering, a sequential fork-safe bring-up, on-demand sealing sidecars,
and a genesis that reproduces a realistic fork history (Berlin/London by block,
Shanghai+Cancun by timestamp, both crossed live during the run).

`rehearsal/drive.sh` runs the campaign as gated phases — baseline, rolling
upgrade under load, functional battery, recommit tuning, stress to saturation
with outage and crash drills, a signer-quorum halt drill, and rollback in both
directions. Any failed gate stops the campaign with the network left up for
inspection. See `rehearsal/README.md`.

### Verified — the upgrade path, under load

- **Rolling upgrade**: nodes replaced one at a time under continuous traffic —
  the chain never paused (+125–127 blocks during every swap), each node
  re-joined and resumed relaying transactions, and mixed old/new versions
  agreed on every settled hash.
- **Rollback works in both directions**, including a whole-network rollback in
  which the older binary ran +120 blocks on data the newer binary had written —
  no resync, no datadir migration.
- **Latency** (sequential submit→receipt through a public RPC node): **2001 ms**
  median before, unchanged by the upgrade itself at the 2 s default recommit,
  and **1013/1083 ms** at `--miner.recommit 750ms` — the configuration this
  release makes safe on multi-signer chains (see the out-of-turn delay fix
  below). Re-measured through a 5-minute signer outage: +278/+281 blocks.
- **Stress**: ≥ 400 tx/s sustained (the probe's ceiling — the network never
  saturated). With a signer stopped and another process-killed mid-load at
  320 tx/s the chain still advanced +266 blocks; the killed node's archive
  database reopened clean and re-synced.
- **History integrity**: a fresh node full-synced the entire chain from genesis
  under the new binary, re-executing both fork boundaries.
- **On-demand sealing preserved**: idle-stop and wake-on-transaction (≈ 3 s)
  behaved identically before and after the upgrade.

### Notes for operators

- After a **whole-network** restart, a node accepts transactions over RPC but
  does not gossip them until a sync re-arms it — on a chain that only seals
  when there is work, that combination can look healthy while nothing is mined.
  Rolling restarts under load re-arm naturally; a full restart should follow a
  deliberate arming procedure (`rehearsal/drive.sh recover` implements one).
- Clique halts when fewer than `len(signers)/2 + 1` signers are available, and
  the recent-signers window cannot rotate while the chain is frozen — so
  restoring a single signer may not be enough to resume. Restore quorum and
  start the returning signers' miners explicitly.
- Container restart policies only revive a container whose **process** died;
  `docker kill`/`docker stop` are manual stops and are not auto-restarted.

---

## [Unreleased] — 2026-07-28 — upstream backports (v1.13.15 → v1.17.5)

Reviewed the full upstream delta to v1.17.5 and ported back the fixes that apply
to v1.13.15-era code. Nothing here changes consensus rules or block validity, and
no new hard fork is introduced. Full adoption matrix, including what was rejected
and why, in [`docs/upstream-backports.md`](docs/upstream-backports.md).

### Security — pre-authentication crypto

Four upstream fixes to code reachable from the p2p port before authentication.

Two of them (`3b17e7827`, `9b78f45e3`) carry no PR number and terse messages —
"use aes blocksize", "fix coordinate check" — which is how undisclosed security
fixes are usually shipped. `9b78f45e3` is the commit immediately preceding the
v1.17.0 release; `3b17e7827` landed 88 commits earlier in the same cycle, and one
of the ordinary-PR fixes (`c974722dc`, #33669) landed between them, so treat these
as individually quiet fixes rather than one coordinated batch. The other two came
through normal PRs: `fa9a2ff86` (#31100, first tagged v1.15.0) and `c974722dc`
(#33669, v1.17.0).

- `crypto/ecies`: `Decrypt` accepted a ciphertext shorter than one AES block and
  panicked out of bounds — an unauthenticated remote node kill via the RLPx
  handshake, whose length prefix is attacker-controlled.
- `crypto/ecies`: `GenerateShared` ran `ScalarMult` on an unvalidated point
  (invalid-curve attack plus a decrypt-success oracle against the static key).
- `crypto`: `UnmarshalPubkey` had no on-curve check. Reachable in the **cgo**
  build because `BitCurve` implements `Unmarshal`, so `elliptic.Unmarshal`
  delegates to it and skips Go's own range and on-curve validation. (Under
  `CGO_ENABLED=0` the btcec curve has no `Unmarshal`, so Go's checks still ran —
  the gap was cgo-only, which is the production build.)
- `crypto/secp256k1`, `crypto/signature_nocgo`: the on-curve check was bypassable
  with coordinates ≥ P. The nocgo path needed a `btCurve` wrapper, which forced
  two follow-on changes: `SigToPub`/`DecompressPubkey` now name the wrapped curve
  explicitly, and `Sign`'s guard accepts both `S256()` and `btcec.S256()` so keys
  created before the wrapper still sign. Verified under both `CGO_ENABLED=0`
  and `=1`.

### Security — p2p and public RPC hardening

- `p2p/rlpx`: cap handshake messages at 2 KB (was up to 64 KB pre-auth).
- `eth/fetcher`: announcement DoS cap kept the overflow instead of the allowance.
- `eth/filters`: cap filter addresses at 1000 (previously unbounded).
- `eth/gasprice`: cap `eth_feeHistory` percentiles at 100.
- `rpc`: cap JSON-RPC method names at 2048 (response amplification).
- `internal/ethapi`: `decodeHash` checks length before hex-decoding.

### Fixed — RPC host matching

`node/rpcstack`: `--http.vhosts` compared the request `Host` against the allowlist
without case folding, while the allowlist itself is lower-cased at construction.
`Host: LOCALHOST` was therefore **rejected** with a 403 even when `localhost` was
allowlisted. Hostnames are case-insensitive, so the request host is now folded
too. This can only turn a false 403 into a 200 — it cannot admit a host that is
not in the allowlist.

### Fixed — transaction propagation and pool

- `eth/protocols/eth`: all three direct send paths marked transactions as known
  *before* sending, so a failed send recorded the peer as knowing a transaction it
  never received. (Scope: the async broadcast paths still mark at enqueue, as
  upstream leaves them, so this is correctness hygiene rather than a latency fix.)
- `eth/protocols/eth`: `dispatchResponse` could block forever on a disconnecting
  peer, leaking a goroutine and stalling its read loop.
- `eth/fetcher`: dropped peers were never removed from `alternates`.
- `core/txpool`: overflow in `list.Add` corrupted the pool's cost accounting; the
  reset goroutine could block forever if shutdown raced an in-flight reset (more
  likely at period 1, where a reset is in flight most of the time); no nonce upper
  bound (EIP-2681); redundant pubkey recovery per state validation.
- `core/txpool/blobpool`: limbo store now opens with `Repair: true` — without it
  an unclean shutdown made the **node refuse to start**; fixed a zero-index panic
  and return `ErrAlreadyKnown` for duplicates instead of penalising honest peers.

### Fixed — core, state, database

- `core/state`: `StateDB.Copy()` copied **both** `accountsOrigin` and
  `storagesOrigin` from the empty destination instead of the source, silently
  dropping both from every copy. Latent under the hash scheme, which discards the
  triestate set, but it would corrupt state history under `--state.scheme=path`.
- `core`: added `txLookupLock` so a concurrent reader cannot repopulate the tx
  lookup cache with pre-reorg entries mid-reorg. A stale entry made
  `eth_getTransactionByHash` report the wrong block, and nothing corrected it
  until the 1024-entry LRU evicted it or a later reorg purged the cache.
- `core/state/snapshot`: `StorageList()` mis-accounted diff-layer memory — it
  added the length of the account map instead of the slot list just computed,
  skewing the 4 MiB aggregator flush threshold in either direction depending on
  layer shape. Also added missing locks in `Release()` and `disklayer()`, and
  downgraded `generating()`/`DiskRoot()` from `Lock` to `RLock` so they no longer
  contend with the read lock `Release()` now takes.
- `core/rawdb`: nil-deref at startup when `Lstat` failed with anything other than
  NotExist.

### Changed — transaction rejection messages (client-visible)

Two txpool errors now carry the reason, so a rejected submission is diagnosable
instead of opaque. `eth_sendRawTransaction` returns these verbatim in the
JSON-RPC error message, so **a client matching on the exact string will break** —
`errors.Is` is unaffected.

| Case | Before | After |
|---|---|---|
| unsupported tx type | `transaction type not supported` | `transaction type not supported: received type 3` |
| bad signature / wrong chain id | `invalid sender` | `invalid sender: <recovery error>` |

The second is the one likely to be seen in practice: it fires on a wrong-chainId
signature, a common client misconfiguration.

Also in this category, from the blobpool: re-submitting a byte-identical blob
transaction now returns `already known` instead of
`replacement transaction underpriced`.

### Fixed — RPC correctness

- `eth/filters`: poll filters leaked subscriptions on error; `eth_subscribe`
  raced and could drop events fired before the goroutine was scheduled;
  `timeoutLoop` never terminated.
- `eth/gasprice`: oracle discarded its head subscription, leaking a goroutine.
- `internal/ethapi`: `debug_getRawHeader`/`getRawBlock`/`getRawReceipts`
  nil-dereferenced on an unknown block number.

### Changed — miner commit latency

`minRecommitInterval` lowered from 1s to 100ms so sealers can run
`--miner.recommit` **below** the Clique period. Default stays 2s; no behavioural
change unless configured.

Upstream v1.17.5 removed this floor entirely when the miner became a
beacon-driven payload builder that rebuilds until `getPayload` — freezing block
content at delivery rather than at the start of the slot. Our v1.13 sealer
freezes at the start of the period and does not rebuild when transactions arrive
mid-period. On a period-1 chain a transaction therefore misses the block already
being sealed and lands in the one after: a 1–2 s wait, uniform in where the
transaction falls within the period, so ~1.5 s expected. An external end-to-end
benchmark measured ~2.0 s median submit-to-receipt; the gap above 1.5 s is
submission, gossip to the sealer, and receipt-polling granularity, none of which
this change affects.

The rebuild machinery already existed in `newWorkLoop`; the 1s floor made it
unreachable.

**Measured** (`smoke-test/commit-latency.sh`, 1 signer, period 1, sequential
submit-and-wait-for-receipt transactions, values swept):

| `--miner.recommit` | median | p95 | rebuilds/block |
|---|---|---|---|
| 2s (default) | 2014 ms | 2022 ms | — |
| 1s (= period) | 2016 ms | — | — |
| **750ms** | **1013 ms** | 1016 ms | 1.8 |
| 500ms | 1013 ms | 1017 ms | — |
| 250ms | 1013 ms | 1015 ms | 1.8 |
| 100ms | 1010 ms | 1014 ms | — |

The improvement is a **step, not a gradient**. At 1s — equal to the block period —
there is no gain at all: at most one rebuild lands per block and it coincides with
sealing. Any value below the period yields the full 1001 ms (49%), and going
further buys nothing. The spread tightens too: p95 2022 ms → 1016 ms.

**750ms is the recommended value**: the largest interval that reaches the plateau,
so it deviates least from the default while capturing the entire win.

An honest caveat on cost. 750ms and 250ms measured **identical** rebuild rates
(1.8/block), because `newWorkLoop` skips the rebuild when no transaction has
arrived — so the rate is set by transaction arrivals, not by the interval. At
heavier load the two should diverge (arithmetic bound ~1.3/block at 750ms versus
~4 at 250ms), but **that was not measured**. At the traffic level tested the two
values are indistinguishable in both latency and cost.

The 2014 ms baseline also reproduces, to within 2 ms, the ~2012 ms median an
external benchmark measured against the live network from another country. That
agreement is the strongest evidence that the latency was the miner's block-content
freeze rather than network distance, queueing, or client behaviour.

Measured with a single signer, so no out-of-turn wiggle is involved. On a
multi-signer chain ship the out-of-turn delay fix below before lowering this.

**Multi-signer chains additionally need the out-of-turn delay fix below.** Without
it, a mid-period resubmit restarts `Seal` with a fresh wiggle, so an out-of-turn
signer publishes earlier than intended and same-height contention increases; with
it, the delay is stable across re-seals and lowering the recommit interval is safe
at any signer count. A single-signer chain is unaffected either way, since every
block is in-turn and no wiggle is drawn.

### Fixed — Clique out-of-turn delay is redrawn on every re-seal

`consensus/clique` — **not an upstream backport.** Upstream deleted Clique in
v1.14, so there is no commit to port; this is original work and should be reviewed
on its own terms.

When a signer is not the one whose turn it is, `clique.Seal` waits
`rand(0, (signers/2+1) × 500ms)` before publishing, so it does not collide with
the in-turn signer. That draw happened **inside `Seal`**, so it was redrawn on
every call. `taskLoop` restarts `Seal` whenever the seal hash changes, which is
every mid-period rebuild — so once `--miner.recommit` drops below the block
period, a block gets several draws instead of one. Because a restart happens after
`header.Time` has passed, publication is `max(now, drawn)`: each redraw is another
chance at a small value, and the delay collapses toward zero.

Measured on a 3-signer chain at period 1 with `--miner.recommit 250ms` and
transaction load, **28 of 28 out-of-turn blocks were redrawn**, 3-8 times each:

    block 17  787 245 156 673 516 982 853 664 ms
    block 41  792 703 948 3 ms
    block 24  526 686 423 462 669 18 ms

Two of 28 ended on a sub-20 ms delay — published essentially at `header.Time`, in
a dead heat with the in-turn signer. That is the same-height race the wiggle
exists to prevent.

The draw is now keyed to `(parentHash, number)` and cached, so re-sealing a block
reuses the delay it was first given: the wiggle becomes a property of the block,
which is what Clique intended. Same conditions after the fix: 27 blocks re-sealed,
**0 redrawn**.

**Second stage — the cache must hold a deadline, not a duration.** The first cut
of this fix cached the drawn duration only, and a branch audit found it traded
the redraw bug for a liveness bug. `Prepare` bumps `header.Time` to "now" on any
late block, and an out-of-turn wait is always past the period boundary, so every
mid-period rebuild restarted the full countdown. Clique timestamps are whole
seconds, which quantizes the bump: a draw **under 1 s** still completes at a
fixed absolute instant (the bump floors to the same second, so restarts converge
on the same target), but a draw **≥ 1 s** recedes by one second at every
second-crossing rebuild and never completes while transactions keep arriving.
Draws ≥ 1 s exist only when the span exceeds 1 s — i.e. **4 or more signers**
(span = (n/2+1) × 500 ms = 1.5 s at 4-5 signers), which is the production shape.
Reproduced at 4 signers, period 1 s, recommit 250 ms, one signer down, load at
~15 tx/s: the duration-cache build sealed **2 blocks in 40 s** — a full stall at
the first out-of-turn height, zero difficulty-1 blocks ever produced — while the
deadline build sealed **34 blocks including 26 out-of-turn** under identical
conditions. The cache now stores the absolute deadline (first-seal
`header.Time` + draw), so a rebuild can neither shorten the wait (re-roll) nor
extend it (countdown reset). On a free-gas chain the stalling load is free to
generate, so the duration-cache variant was never deployable; it existed only
between commits on this branch.

Three things worth knowing:

- **It only manifests under transaction load.** `newWorkLoop` skips the rebuild
  when no new transaction arrived, so an idle chain never re-seals and never
  redraws — verified: an idle run produced zero re-seals on both binaries.
- **This is what makes `--miner.recommit` below the period safe on a multi-signer
  chain.** Without it, the recommit change above should only be used with a single
  signer.
- **Testing Clique timing needs ≥ 4 signers.** At 3 signers the span is exactly
  1.0 s, so the ≥ 1 s draw regime — the only one where countdown-reset bugs are
  observable — is unreachable, and a 3-signer run passes on the broken build.
  `out-of-turn.sh` runs 4 signers for this reason (a comment in the script
  explains it).

Covered by `TestWiggleStableAcrossReseals` (unit, now also asserting the deadline
is immovable) and `smoke-test/out-of-turn.sh`, which stops a signer on a 4-signer
network to force out-of-turn sealing, asserts real forward progress through the
outage under load, and asserts from the sealer's own debug log that a re-sealed
block keeps its delay — strictly: a run in which the debug line never appears or
no block is re-sealed FAILS instead of passing vacuously.

### Fixed — consensus (cosmetic)

`consensus/clique`: blob-gas validation errors printed pointer addresses instead
of values (same defect upstream fixed in theirs).

### Added — release-to-release upgrade tests

`smoke-test/`

The suite verified that a Clique chain can adopt Cancun (stock geth → patched),
but nothing verified that operators can move between two releases of *this* fork
— the upgrade actually performed in production. Two scenarios close that gap:

- `inplace-upgrade.sh` — stops the previous build and starts the new one on the
  **same datadir**, asserting no rewind, unchanged genesis, byte-identical
  pre-upgrade block hashes, continued mining, Cancun/Shanghai header fields still
  emitted, and a zero-fee tx still mining. A third phase swaps back to the
  previous build so the downgrade path is proven too. 14 assertions.
- `mixed-version.sh` — runs both builds as peers in both directions, asserting
  they complete the RLPx handshake, sync, and agree on block hashes. Identical
  hashes across versions is what rules out a consensus split, and therefore what
  makes a rolling upgrade safe one node at a time. Up to 12 assertions (6 per
  direction); the cross-version tx-propagation check is skipped when the peer
  node has no unlocked account, which is why a normal run reports 10.

Also fixed a vacuous assertion in `upgrade-rigorous.sh`: the "genesis hash still
== G0" check compared the live node's block 0 against *itself*, so it could never
fail while still counting toward the advertised 22. It now captures the genesis
hash before the upgrade and compares the post-upgrade value against it. Still
22/22, but one of them now actually tests something.

Both new scripts are wired into `run-all.sh` behind an optional third argument, so
existing two-argument invocations are unchanged and simply skip them:

    run-all.sh <geth-original> <geth-patched> [geth-previous]

### Building a release binary (linux/amd64)

Build from a clean **branch checkout**, not a `git worktree` — on Go 1.21 a
worktree build silently omits the VCS stamp, leaving `Git Commit` empty and
making the artifact impossible to trace back to a commit:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o build/bin/geth-linux-amd64 ./cmd/geth
./build/bin/geth-linux-amd64 version   # Git Commit must match your checkout
```

Statically linked (`CGO_ENABLED=0`, Go 1.21.12) so it drops onto an Alpine-based
image without a libc dependency. This release introduces no genesis, config, or
on-disk format change, so upgrading is cumulative: roll nodes one at a time, and
downgrading to the previous build works the same way.

### Verification

- `go build`, `go vet`, `gofmt` clean. The 52 test packages covering the touched
  code and its dependents pass — not the full suite (114 packages have tests).
  `eth/catalyst` is excluded: it fails identically on the base commit because its
  test hardcodes port 8545. `crypto` verified under both `CGO_ENABLED=0` and
  `=1`, since the curve wrapper only affects the nocgo path. Full caveats in
  [`docs/upstream-backports.md`](docs/upstream-backports.md).
- Docker smoke suite **14/14**, including `transition-prod` (production
  parameters, period 1) and `upgrade-rigorous` (22 assertions).
- `inplace-upgrade` **14/14**; `mixed-version` **10 of 10 executed** (2 skipped by
  design, see above) — both against the previous release build.

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
