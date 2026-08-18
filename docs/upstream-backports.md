# Upstream backports: go-ethereum v1.13.15 → v1.17.5

This fork is pinned to **go-ethereum v1.13.15**, the last upstream release that
shipped Clique. Upstream removed Clique in v1.14 and, in the same release,
removed the pre-merge block-gossip paths this network depends on. We therefore
cannot follow upstream releases; instead we review the upstream delta
periodically and port back the fixes that apply to v1.13.15-era code.

This document records what was adopted, what was rejected, and why. It is the
reference for the next review — start from the "Not adopted" section so the same
commits are not re-litigated.

Upstream range reviewed: `v1.13.15..v1.17.5` (2,340 commits, 1,878 files).

---

## Never adopt: the pre-merge teardown

Upstream `f4d53133f` ("remove support for non-merge mode of operation", v1.14.0)
deleted 2,990 lines that this network runs on every block:

- `eth/fetcher/block_fetcher.go` — block announce/fetch reassembly
- `eth/sync.go` — the pre-merge chain syncer
- `eth/handler_eth.go` block-announce and block-broadcast handlers
- `eth/protocols/eth/broadcast.go: broadcastBlocks()`
- the `knownBlocks` tracking in `eth/protocols/eth/peer.go`

and turned block gossip into a protocol violation — `handleNewBlockhashes` and
`handleNewBlock` now return an error, which drops the peer.

Follow-ups in the same teardown, equally out of bounds: `723aae2b4` (drops the
eth/68 handler map, where the block-message handlers live), `45baf2111` (purges
pre-merge downloader sync), `b0b67be0a` (removes the forkchoicer), `39638c81c`
(removes total difficulty).

Practical consequence: any upstream commit touching those files after v1.14.0
does not apply here, and any upstream refactor of the `handleMessage` handler
maps needs our `0x01`/`0x07` entries re-inserted by hand.

Also permanently rejected: upstream's Clique itself. In v1.17.5
`consensus/clique` hard-rejects both forks (`"clique does not support shanghai
fork"`, `"clique does not support cancun fork"`) and `f21adaf24` deleted the
Clique RPC API. Our Cancun-enabled Clique is the entire point of this fork.

---

## Adopted

### Consensus

**Blob-gas error formatting** (upstream #33296) — `consensus/clique/clique.go`

Our added Cancun-field validation had the same defect upstream found in theirs:
`%d` was applied to `*uint64`, so a rejected header logged a pointer address
instead of the offending blob-gas value. Dereferenced, matching upstream.
(The `parentBeaconRoot` case was already fine — `common.Hash` has a value-receiver
`Format` method, so `%#x` on the pointer already printed correctly; it was
dereferenced only for consistency with upstream's hunk.)

Worth noting for confidence: upstream independently made the same fork-boundary
fix we did in `miner/worker.go` (#29242, "modify header before checking
time-based fields") — moving `engine.Prepare` ahead of the EIP-4844/4788 block
because Clique rewrites `header.Time`. Our version already carried it.

### Miner — commit latency

**Recommit floor lowered 1s → 100ms** — `miner/worker.go`

Upstream v1.17.5 removed the recommit floor entirely when the miner became a
beacon-driven payload builder (`miner/payload_building.go`): it builds an empty
block immediately, then rebuilds from the txpool every `Recommit` until the
consensus client calls `getPayload`, so block content is frozen at *delivery*
rather than at the start of the slot.

Our v1.13 self-scheduling Clique sealer freezes content at the *start* of the
period — it commits on the chain-head event, and `clique.Seal` then sleeps until
`header.Time`. A transaction arriving mid-period only bumps a counter
(`w.newTxs.Add`, worker.go) and does not trigger a rebuild, and the recommit
timer never fires because it is reset to 2s on every 1s chain-head event. Net
effect on a period-1 chain: a transaction submitted at time *t* waits until the
*next* boundary to be built and the one after to be published — 1–2 s, uniform in
where *t* falls within the period, so ~1.5 s expected. An external benchmark
measured ~2.0 s median **submit-to-receipt**; the difference is submission,
gossip to the sealer, and receipt-polling granularity, which this change does not
affect.

The `newWorkLoop` resubmit path already implements upstream's rebuild loop; it
was simply unreachable, because `minRecommitInterval = 1s` sanitized any smaller
value up to the block period. Lowering the floor makes a sub-period
`--miner.recommit` configurable on sealers, which reproduces v1.17.5's semantics:
build at the period start, refresh while the period runs, publish the newest
content at `header.Time`. **Measured** with `smoke-test/commit-latency.sh` (1 signer,
period 1, sequential submit-to-receipt samples, values swept):

| `--miner.recommit` | median | p95 | rebuilds/block |
|---|---|---|---|
| 2s (default) | 2014 ms | 2022 ms | — |
| 1s (= period) | 2016 ms | — | — |
| **750ms** | **1013 ms** | 1016 ms | 1.8 |
| 500ms | 1013 ms | 1017 ms | — |
| 250ms | 1013 ms | 1015 ms | 1.8 |
| 100ms | 1010 ms | 1014 ms | — |

A step function, not a gradient: nothing at 1s (equal to the period), the full
1001 ms at anything below it, flat thereafter. **Recommend 750ms** — the largest
value on the plateau, so the smallest deviation from the default that still gets
the whole win.

The 2014 ms baseline matches the ~2012 ms median measured externally against the
live network to within 2 ms. That agreement is what confirms the diagnosis: the
delay was the miner freezing block content at the start of the period, not the
network, not queueing, not the client.

Cost caveat, stated because it contradicts what this document previously implied:
750ms and 250ms measured the **same** rebuild rate (1.8/block). `newWorkLoop`
skips the rebuild when no transaction has arrived, so the rate follows transaction
arrivals rather than the interval. The two should separate under heavier load
(~1.3/block versus ~4 by arithmetic) but that was **not measured**; at the traffic
tested they are indistinguishable.

The floor is not removed outright: upstream's loop is bounded by a 12 s slot
timeout, whereas `newWorkLoop`'s timer rearms unconditionally, so a zero interval
would busy-spin on an idle chain. Default remains 2 s — no behavioural change
unless an operator sets the flag.

> **Only lower `--miner.recommit` on a single-signer chain.**
>
> Clique draws the out-of-turn delay *inside* `Seal`:
> `wiggle = rand(0, (len(signers)/2+1) × 500ms)` (`consensus/clique/clique.go`).
> A resubmit that changes the seal hash makes `taskLoop`
> (`miner/worker.go`) interrupt the in-flight `Seal` and call it again, which
> draws a **new** wiggle. Because the restart happens after `header.Time` has
> passed, `delay = wiggle − elapsed`, so each re-draw is another chance to land a
> small value and publish immediately. Over several resubmits per period the
> effective delay is the minimum of the draws, not a single uniform draw.
>
> Consequence on a multi-signer chain: an out-of-turn signer publishes earlier
> than intended, eroding the head start that lets the in-turn signer win the
> height. That means more same-height competition and more reorgs — exactly the
> class of problem the earlier non-merge liveness work addressed.
>
> With a **single** signer every block is in-turn (`diffInTurn`), the
> `diffNoTurn` branch never runs, and no wiggle is drawn — so the latency win is
> free.
>
> **Resolved for multi-signer chains.** The wiggle is now drawn once per
> `(parentHash, number)` and — critically — cached as an **absolute deadline**,
> not a duration (`consensus/clique/wiggle.go`), so a re-seal resumes the same
> countdown instead of re-rolling it or restarting it. This is original work,
> not an upstream backport — upstream deleted Clique, so there was nothing to
> port. Reproduced and fixed on a 3-signer chain: 28 of 28 out-of-turn blocks
> redrew before the fix (two landing under 20 ms, i.e. racing the in-turn
> signer), 0 of 27 after. See the CHANGELOG entry and
> `smoke-test/out-of-turn.sh`.
>
> The deadline anchoring is not a refinement — it is the difference between a
> fix and a worse bug. A first cut of this change cached only the drawn
> *duration*, and a branch audit found (and a 4-signer A/B run then proved)
> that it could stall the chain outright: `Prepare` bumps `header.Time` to
> "now" on late blocks, so each rebuild restarted the full countdown. Clique
> timestamps are whole seconds, which quantizes that bump — draws under 1 s
> still complete at a fixed instant, but a draw ≥ 1 s recedes by one second at
> every second-crossing rebuild and never completes while transactions keep
> arriving. Draws ≥ 1 s require a span over 1 s, i.e. **4 or more signers**
> (span = (n/2+1) × 500 ms = 1.5 s at 4-5 signers); measured at 4 signers,
> period 1 s, recommit 250 ms under load, the duration-cache build sealed 2
> blocks in 40 s after a signer outage (a full stall at the first out-of-turn
> height), the deadline build 34. This is also why `out-of-turn.sh` runs 4
> signers: at 3 signers (span exactly 1.0 s) the stall regime is unreachable
> and the test would pass on the broken build.
>
> Note the hazard only exists under transaction load: `newWorkLoop` skips the
> rebuild when no new transaction arrived, so an idle chain never re-seals.

### Security — pre-authentication crypto (highest priority)

Four fixes to code that an internet-exposed p2p port serves *before*
authentication.

Two of them — `3b17e7827` ("use aes blocksize") and `9b78f45e3` ("fix coordinate
check") — carry no PR number and terse messages, which is how undisclosed
security fixes are normally shipped. Do not over-read the pattern, though:
`9b78f45e3` is the commit immediately preceding the v1.17.0 release, but
`3b17e7827` landed 88 commits earlier, and `c974722dc` — an ordinary PR — sits
between them. They are individually quiet fixes, not one coordinated batch.

The other two arrived through normal PRs: `fa9a2ff86` (#31100, first tagged
v1.15.0) and `c974722dc` (#33669, v1.17.0). Verified with
`git tag --contains <sha> | sort -V | head -1` and `git rev-list --count <sha>..v1.17.0`.

- **`3b17e7827`** `crypto/ecies` — `Decrypt` accepted a ciphertext shorter than
  one AES block (`rLen + hLen + 1` instead of `+ params.BlockSize`), so
  `symDecrypt` sliced out of bounds and panicked. Reachable from the RLPx
  handshake, whose length prefix is attacker-controlled, with no `recover()` on
  the path — an unauthenticated remote node kill.
- **`c974722dc`** `crypto/ecies` — `GenerateShared` ran `ScalarMult` on an
  unvalidated point. Invalid-curve / small-subgroup attack plus a decrypt-success
  oracle against the node's *static* private key. Added the `IsOnCurve` check.
- **`fa9a2ff86`** (#31100, first tagged v1.15.0) `crypto.UnmarshalPubkey` — no
  on-curve check. Reached from enode/ENR parsing and the handshake. Reachable
  here specifically because `BitCurve` implements `Unmarshal`, so
  `elliptic.Unmarshal` delegates to it and skips Go's own range and on-curve
  validation. (An earlier draft attributed this to CVE-2025-30147; that
  identifier could not be substantiated from the upstream repository, so treat
  the vulnerability class — missing on-curve validation — as the claim, not the
  CVE number.)
- **`9b78f45e3`** `crypto/secp256k1`, `crypto/signature_nocgo` — the on-curve
  check itself was bypassable with coordinates ≥ P. Added the range check to
  `BitCurve.IsOnCurve` (cgo path) and a `btCurve` wrapper (nocgo path).

The nocgo wrapper needed two adaptations upstream also made: `Sign`'s curve
equality check and the `SigToPub`/`DecompressPubkey` constructors have to name
the wrapped curve, or every nocgo signature breaks and `TestPubkeyRandom` fails
on the `Curve` field. Verified green under both `CGO_ENABLED=0` and `=1`.

### Security — p2p / network

- **`27654d302`** `p2p/rlpx` — cap handshake messages at 2 KB. The 16-bit length
  prefix previously let an unauthenticated peer make the node allocate and read
  up to 64 KB per connection.
- **`e9e12a97d`** `eth/fetcher` — the announcement DoS cap kept the *overflow*
  instead of the *allowance* (`[:want-maxTxAnnounces]` vs
  `[:maxTxAnnounces-used]`), so the 4096 cap admitted roughly double and dropped
  good announcements under load.
- **`929807463`** `eth/protocols/eth` — `dispatchResponse` blocked forever on a
  peer that disconnected between response arrival and delivery, leaking a
  goroutine and stalling that peer's read loop. Added the `p.term` case.
- **`88576c52e`** `eth/fetcher` — dropped peers were removed from `announced` but
  not `alternates`, so dead peers accumulated and were repeatedly scheduled for
  fetches.

### Transaction propagation (latency-relevant)

**`10a198220` + `5016e5440` + `1f87331fb`** — `eth/protocols/eth/peer.go`

All three send paths marked hashes in `knownTxs` *before* `p2p.Send`, so a failed
send recorded the peer as knowing a transaction it never received. Marking now
happens only after a successful send.

Scope this correctly: the two **async** entry points (`AsyncSendTransactions`,
`AsyncSendPooledTransactionHashes`) still mark at *enqueue* time, and those are
what the broadcaster uses — upstream did not change them. So the practical effect
here is limited to `ReplyPooledTransactionsRLP` (serving a peer's explicit
request), and `knownTxs` evicts randomly once full rather than suppressing
forever. Take this as correctness hygiene matching upstream, not as a fix for
transaction latency.

### Transaction pool

- **`d68528cad`** `legacypool/list.go` — `Add` subtracted the replaced
  transaction's cost from `totalcost` *before* validating the new cost, and the
  addition itself could wrap. A rejected oversized transaction left the accounting
  permanently low, corrupting the `Filter(balance, gasLimit)` drop/keep decisions.
  Now checked with `AddOverflow` and the subtraction moved after.
- **`e25cedf16`** `txpool.go` — the reset goroutine did an unguarded
  `resetDone <- newHead`; if `Close()` won the race it leaked forever holding
  subpool locks. On a period-1 chain resets fire every second, so this is a
  routinely-hit shutdown hang. Added the `p.term` case.
- **`bacc1504b`** `validation.go` — no upper bound on nonce (EIP-2681). A
  `nonce == 2^64-1` transaction can never execute but occupies a slot and is
  re-broadcast forever. On a zero-gas-price chain this pollution is free, so it is
  more attractive here than on mainnet.
- **`6693fe1be`** `validation.go` — `ValidateTransactionWithState` used
  `signer.Sender` instead of `types.Sender`, bypassing the sender cache and
  forcing a full pubkey recovery on every state validation.
- **`e3bdd84e9`** `blobpool/limbo.go` — the limbo store opened without
  `Repair: true` (the main store has it), so an unclean shutdown made
  `blobpool.Init` fail and **the node refuse to start**. We run Cancun, so the
  blobpool is instantiated regardless of blob traffic.
- **`0dd7e82c0`** `blobpool/blobpool.go` — unguarded `txs[0]` in `recheck` panics
  when the slice drains.
- **`00c21128e`** `blobpool/blobpool.go` — a re-announced blob transaction
  returned `ErrReplaceUnderpriced` instead of `ErrAlreadyKnown`, so honest peers
  were penalised for normal re-broadcast. Test expectations updated to match
  upstream's.
- **`484f0f4e8`** `txpool.go` — `ErrTxTypeNotSupported` returned bare; now wrapped
  with the received type so a rejected submission is diagnosable over RPC.

### Core / state / database

- **`1e9bf2a09`** `core/state/statedb.go` — `Copy()` did
  `state.accountsOrigin = copySet(state.accountsOrigin)` and the identical thing
  for `storagesOrigin`, copying from the *empty destination* instead of the
  source. **Both** were silently dropped by every StateDB copy, so anything
  committing from a copy (miner, tracing) wrote a state update with missing origin
  data. Two one-token fixes; latent under the hash scheme, which discards the
  triestate set, but corrupting under `--state.scheme=path`.
- **`1126c6d8a` + `b6115e9a3`** `core/blockchain.go`, `core/blockchain_reader.go` —
  `reorg()` purged `txLookupCache` *before* rewriting canonical markers, so a
  concurrent `GetTransactionLookup` could repopulate it with pre-reorg entries
  mid-reorg, leaving `eth_getTransactionByHash`/`getTransactionReceipt` pointing
  at the pre-reorg block until the 1024-entry LRU evicted that entry or a later
  reorg purged the cache. Added `txLookupLock` held across the
  mutation (as a `defer`, per the follow-up, so an error return cannot wedge every
  RPC lookup) with the purge moved to the end.
- **`25439aac0`** `core/state/snapshot/difflayer.go` — `StorageList()` memory
  accounting used `len(dl.storageList)` (the map of lists) instead of the
  generated `storageList`, massively under-counting, so `aggregatorMemoryLimit`
  never tripped and diff layers grew unbounded.
- **`7cf6a6368` + `34b46a2f7`** `core/state/snapshot/snapshot.go` — `Tree.Release()`
  walked `t.layers` with no lock, racing `Cap`/`Update`; `disklayer()` read
  `diffLayer.origin` without the layer lock, racing `diffToDisk`'s origin swap.
  Added the locks and downgraded `generating()`/`DiskRoot()` to RLock.
- **`c5a8d3485`** `core/rawdb/freezer.go` — `os.Lstat` failing with anything other
  than NotExist (permission, EIO, stale NFS handle) left `info` nil and
  nil-dereferenced at startup.

### Public RPC — correctness

- **`bc0a21a1d`** `eth/filters/api.go` — the three poll-filter goroutines deleted
  themselves from `api.filters` on subscription error but never called
  `Unsubscribe()`, leaking the subscription and able to block the producer side.
- **`de0a452f7`** `eth/filters/api.go` — `NewPendingTransactions` and `NewHeads`
  subscribed *inside* the goroutine, so the RPC handler could return the
  subscription id before the filter was installed; events in that window were
  silently lost. Hoisted the subscribe above the goroutine.
- **`6c10996bf`** `eth/filters/api.go` — `timeoutLoop` blocked on `<-ticker.C`
  forever and never terminated with the event system.
- **`8dfad579e`** `eth/gasprice/gasprice.go` — `NewOracle` discarded the
  subscription returned by `SubscribeChainHeadEvent`, so the cache-purging
  goroutine never terminated. Kept our `ev.Block` accessors (upstream's `ev.Header`
  postdates a v1.14 event refactor).
- **`da71839a2`** `internal/ethapi/api.go` — `debug_getRawHeader`/`getRawBlock`/
  `getRawReceipts` nil-dereferenced when the backend returned `(nil, nil)` for an
  unknown block; reachable by passing any future block number.

### Public RPC — resource exhaustion

- **`1f4ea4d16`** `eth/filters` — no address cap existed at all, so `eth_getLogs`
  and `eth_newFilter` accepted unbounded address lists. Capped at 1000 in
  `GetLogs`, `SubscribeLogs`, and `UnmarshalJSON`.
- **`e4b8058d5`** `eth/gasprice/feehistory.go` — `eth_feeHistory` validated each
  percentile but never capped the array length; each percentile multiplies
  per-block work. Capped at 100.
- **`b135da2ea` + `f4a90d178`** `rpc/handler.go`, `rpc/json.go` — an oversized
  JSON-RPC method name was echoed back verbatim in the "method not found" error
  (response amplification). Capped at 2048, checked in `handleCallMsg` so it
  covers `_subscribe`/`_unsubscribe` too.
- **`2e2fece0b`** `internal/ethapi/api.go` — `decodeHash` hex-decoded the entire
  attacker-supplied string before checking the 32-byte limit, so a 100 MB hex
  string in `eth_getProof`/`eth_getStorageAt` was fully allocated first. Length
  checked before decode.
- **`d4027f3d4`** `node/rpcstack.go` — the vhost allowlist compared the request
  `Host` without case folding while `newVHostHandler` lower-cases the allowlist
  itself, so `Host: LOCALHOST` was **rejected** with a 403 even when `localhost`
  was allowlisted. Hostnames are case-insensitive, so the request host is folded
  too. Note this is a **correctness fix, not a security fix**: folding can only
  turn a false 403 into a 200, never admit a host absent from the allowlist.

---

## Not adopted — with reasons

### Rejected as inapplicable

Verified against `git show v1.13.15:<file>`: the code the commit patches either
does not exist in v1.13.15 or was introduced *after* it. Re-checking these next
review is wasted effort.

| Area | Examples | Reason |
|---|---|---|
| txpool | `47d17acdc`, `2d86a5400`, `87974974a` | patch `LegacyPool.Clear()`, added in v1.14 |
| txpool | `d73bfeb3d`, `e5c5e1897`, TxTracker commits | fix `core/txpool/locals/`, a v1.14+ package |
| txpool | `1eead2ec3` | fixes a uint256 path introduced by #31912 |
| txpool | blobpool 2025 work (gapped queue, cell proofs, `GetBlobs`) | post-1.13 machinery |
| core | `86a1f0c39`, `84b12df09` | already present in v1.13.15 |
| core | `766ce2303`, `125fb1ff5`, `15f52a293` | fix post-1.13 state-reader/parallel-commit code |
| p2p | `af0a3274b` and the discv4 revalidation family | `table_reval.go` does not exist in v1.13.15 |
| p2p | `87377c58b`, `85459e143` | artifacts of the `netip` migration |
| p2p | `01786f329`, `9af1f71e7` | fix code added by #29034 |
| RPC | `53c85da79` | fixes a crasher introduced by `30e3a4918`, which we don't have |
| RPC | `2585776aa`, `bf6da2001` | blob-ratio fixes; our `feehistory.go` has no blob fields |
| RPC | `615d29f7c` | fixes a regression from #31393 |
| node | `d318e8eba` | fixes HTTP/2 code added after v1.13.15 |
| all | `les/` commits | package removed before v1.13.15 |

### Rejected as out of scope

New hard forks (Prague/Pectra, Osaka, Amsterdam, EIP-7702, Verkle), protocol
versions eth/69+, the filtermaps log indexer, history pruning, the consensus
interface refactors (`FinalizeAndAssemble` removal, forkchoicer removal, total
difficulty removal), the pathdb v9 database format, and the miner payload-builder
rewrite. Each either changes consensus, requires a beacon chain, or assumes the
post-merge architecture.

### Deliberately deferred — judgement calls, not oversights

- **`b635e0632`** (tx-fetcher stall threshold) — makes the 200 ms stall sleep
  *much* more likely to fire, on the tx-delivery path. On a period-1 chain where
  transactions must reach sealers fast, this could add latency during normal
  re-broadcast churn. Needs measurement before adoption.
- **`0b1438c3d`** (deterministic tx propagation) — routes each transaction by
  sender hash to a fixed `sqrt(peers)` subset. With 5–10 peers that is 2–3 direct
  sends; interacts with the latency budget. A behaviour change, not a bug fix.
- **`6a7f64e76`** (modexp via `go-bigmodexpfix`) — real gas-mispricing/CPU issue,
  but adds a dependency to consensus-adjacent precompile code. Rate-limiting
  `eth_call` is the cheaper mitigation.
- **`40505a9bc`** (reject duplicate txs in a message) — correct, but it *drops
  peers*; if any local tooling re-sends duplicates in one message it would be
  disconnected. Consider log-only first.
- **`eff0bed91`** (freezer index repair) — highest-value corruption fix remaining,
  but the safe subset is only `repairIndex`/`checkIndexItems`; the accompanying
  `index.Sync()` removal is safe only with the v9 database format, which we don't
  take. Worth doing as its own reviewed change.
- **`bc1967f08`** (snapshot generation shutdown race) — genuine
  DB-after-close/goroutine-leak bug, but a rewrite against v1.13's `generate.go`.
  A minimal slice (add `stopGeneration()`, call it from `Release()`) fixes the
  worst part.
- **`c170fa277`** (chain rewind rewrite) — contains a real nil-parent deref in
  v1.13's rewind loop, but the full PR is +183/−55 on the pre-merge rewind path we
  depend on, with three later commits stacked on it. Cherry-pick just the nil
  guard if we touch this.
- **`3d78da917`** (`--rpc.rangelimit`) — highest-value remaining DoS control for
  the public endpoint: nothing currently caps an `eth_getLogs` from block 0 to
  latest. Needs ~15 lines written by hand, since upstream plumbs it through the
  filtermaps-era `Filter`.
- **`8f4fac7b8`** (`eth_simulateV1`) — realistically 1,500–2,500 lines plus ~15
  follow-up fixes and two refactors we don't have. A project, not a cherry-pick.

---

## Verification performed (2026-07-28)

- `go build ./...` clean; `go vet` clean across every touched package; all edits
  `gofmt`-clean (the repo working copy is CRLF, so a bare `gofmt -l` flags every
  file including untouched ones — normalise line endings before trusting it).
- 52 test packages pass. `crypto` verified under **both** `CGO_ENABLED=0` and
  `=1`, since the curve-wrapper fix only affects the nocgo path.
  `eth/catalyst` is excluded from that count: it fails identically on a clean
  checkout of the base commit because `TestSimulatedBeaconSendWithdrawals`
  hardcodes port 8545 and a local node normally holds it — environmental, not a
  regression. `eth/protocols/snap`'s `TestMultiSyncManyUseless` is load-sensitive
  under a full parallel run and passes in isolation; this diff does not touch
  that package.
- Docker smoke suite (`smoke-test/Dockerfile`, A/B stock vs patched):

  | Scenario | Result |
  |---|---|
  | run(patched), freegas-rpc, metamask-compat | PASS |
  | push0, cancun-opcodes, blob-surface, fee-toggle | PASS |
  | ethers-compat (11 assertions) | PASS |
  | transition, multisig-transition, snap-sync | PASS |
  | transition-prod (production params, period 1) | PASS |
  | upgrade-rigorous (22 assertions) | PASS |
  | rollback (8 assertions) | PASS |

  **14 passed, 0 failed.** Re-run in full on this branch's base (`clique-cancun`,
  which carries 10 commits the earlier run did not, including the withdrawals
  fix).

  `upgrade-rigorous` is the broadest: fork transition, a second node syncing
  across the fork with matching block hashes and contract storage, and the
  negative test that stock geth refuses the post-fork chain
  (`panic: unexpected withdrawal hash value in clique`).

### Upgrade / mixed-version compatibility

The pre-existing suite covered *stock geth → patched* (can a Clique chain adopt
Cancun) but nothing covered *previous release → this release*, which is the
upgrade an operator actually performs. Two scenarios were added to close that:

- **`smoke-test/inplace-upgrade.sh`** — stops the previous build, starts the new
  build **on the same datadir**, and asserts no rewind, unchanged genesis, every
  pre-upgrade block hash byte-identical, the chain still mining, Cancun/Shanghai
  header fields still emitted, and a zero-fee tx still mining. Phase 3 swaps back
  to the previous build to prove the downgrade path. **14 passed, 0 failed.**
- **`smoke-test/mixed-version.sh`** — runs both builds as separate peers in both
  directions (old sealer/new peer and the reverse), asserting they peer, sync,
  and agree on block hashes. **10 passed, 0 failed.**

Both are wired into `run-all.sh` behind an optional third argument, so existing
two-argument invocations are unchanged:

    run-all.sh <geth-original> <geth-patched> [geth-previous]

Detail from the mixed-version run, previous build (`clique-cancun` at
`e3512ec8d`) against this branch, period-1 free-gas chain with Cancun from
genesis:

| Check | old sealer + new peer | new sealer + old peer |
|---|---|---|
| RLPx handshake / peering | PASS | PASS |
| sealer produced blocks | PASS (head 11) | PASS (head 11) |
| peer synced across versions | PASS (head 11) | PASS (head 11) |
| block #4 hash identical | PASS | PASS |
| zero panics | PASS | PASS |

10 passed, 0 failed. Identical block hashes across versions is the load-bearing
result: it rules out a consensus split, so a rolling upgrade (one node at a time)
is safe and does not need to be coordinated.

The 2 KB RLPx handshake cap does not reject the previous build's handshakes — an
auth/ack packet is a few hundred bytes, far under the cap; peering succeeded in
both directions.

Not covered by that test: cross-version *transaction* gossip (the harness skipped
it because the non-sealing node has no unlocked account). Transaction propagation
is covered within a single version by `snap-sync` and `upgrade-rigorous`.

Downgrade note: reverting to the previous build is fine for these changes (no
database format, schema version, or freezer layout change). That is separate from
the `rollback.sh` scenario, which is about reverting to *stock* geth across the
Cancun fork boundary — still blocked, by design.

### Load-sensitive: `smoke-test/rollback.sh`

`rollback` passes cleanly (8/8) when run on its own, but it **hung** when run as
the 13th scenario of a loaded `run-all.sh` container. Not a code problem — but
worth hardening, because the failure mode is an *infinite* hang rather than a
timeout.

`stop()` (`rollback.sh:43`) runs `kill "$1"; wait "$1"` with no bound. TEST 2
deliberately starts **stock** geth on a Cancun datadir expecting it to die; under
load the process became a zombie and bash blocked forever in `do_wait`.
Diagnosed live: `/proc/<bash>/wchan` = `do_wait`, child `geth-original` in state
`Z`. A separate loaded run failed earlier still (FATAL at TEST 1 — RPC did not
come up inside `wait_rpc`'s 20 s budget).

Two fixes worth making:

- Bound the teardown:
  `kill "$1" 2>/dev/null; for _ in $(seq 1 20); do kill -0 "$1" 2>/dev/null || break; sleep 0.5; done; kill -9 "$1" 2>/dev/null; wait "$1" 2>/dev/null || true`
- Raise `wait_rpc`'s retry budget (currently 40 × 0.5 s), which is tight for a
  cold start on a loaded machine.

Until then, run the suite under `timeout`. Once bash wedges this way the
container becomes unkillable — `docker kill` and `docker rm -f` both no-op, and
clearing it requires a Docker Desktop restart.

## Operational notes (config, not code)

Found while reviewing the gas-price oracle against a zero-base-fee chain:

- `DefaultIgnorePrice` is 2 wei and `NewOracle` forces `ignorePrice >= 1`, so on a
  zero-tip chain every transaction is filtered out of sampling and
  `SuggestTipCap` permanently returns `lastPrice` — initialised from
  `config.Miner.GasPrice`, default **1 gwei**. Unless sealers run
  `--miner.gasprice 0`, `eth_gasPrice` advertises 1 gwei on a free-gas chain and
  naive clients will overpay a tip to the signer.
- With `GPO.Blocks = 20` and a 1 s period, each `eth_gasPrice` after a head change
  fans out up to 40 block fetches that all return zero samples. Consider
  `--gpo.blocks 2`.
