# Clique + Cancun: Implementation Plan (v2 — post-audit)

## Goal
Enable a private Clique (PoA) network to progress through all hard forks up to
and including Cancun, without a beacon chain / PoS Merge.

Target fork sequence for a Clique chain:
```
Homestead → Berlin → London → Shanghai → Cancun
```

> **v2 note:** This revision incorporates a line-by-line codebase audit triggered
> by external security review. The audit **confirmed** most reviewer concerns and
> uncovered **two additional consensus-critical bugs** the first draft missed
> (PREVRANDAO nil-deref panic; Clique `encodeSigHeader` panic). Severity ratings
> and exact `file:line` evidence are inline.

---

## Backward Compatibility & Consensus Safety (read this first)

**Short answer:** The patch is safe for (a) all non-Clique chains and (b) existing
Clique chains that do **not** opt into the new forks — *provided* it is implemented
exactly as specified (especially the Shanghai-gated PREVRANDAO fix). It is **not**
wire-compatible with stock geth once a chain crosses `shanghaiTime`/`cancunTime` —
that is true of *any* hard fork and is unavoidable.

### What is guaranteed NOT to change

1. **Mainnet, PoW, and PoS chains:** every change is guarded on `c.Clique != nil`
   (config/Rules), `header.Difficulty == 0` (PoS RANDAO path, untouched), or
   `chain.Engine()` being Clique. A non-Clique config takes the identical code
   path it does today. Mainnet uses Ethash → zero impact.

2. **Existing Clique chains that never set `shanghaiTime`/`cancunTime`:** all new
   logic is behind `IsShanghai`/`IsCancun`, which are `false` when the timestamps
   are nil (`isTimestampForked(nil, t) == false`). Pre-fork blocks are processed
   **bit-for-bit identically** — including opcode `0x44` staying `DIFFICULTY` (the
   PREVRANDAO fix is Shanghai-gated precisely to preserve this). A patched binary
   re-syncing an old Clique chain produces the same state roots as stock v1.13.15.

3. **Block hashes / RLP of pre-fork blocks:** unchanged. The `encodeSigHeader`
   edit only *appends* fields that are nil (and thus skipped) on pre-fork headers.

### What WILL change (by design — this is a hard fork)

4. **After a chain crosses `shanghaiTime`/`cancunTime`, patched and unpatched nodes
   diverge.** Stock geth v1.13.15 *rejects* such blocks (`"clique does not support
   shanghai fork"`); stock v1.14+ removed Clique entirely. So:
   - **All nodes must upgrade to the patched binary before the fork timestamp.**
   - For an existing London chain, set the fork timestamps to a **future** time,
     coordinate the rollout, then let it activate. A past/immediate timestamp on a
     running chain split it.
   - The produced chain is a **geth fork**; only the patched binary can follow it
     past activation. It is not "stock-geth compatible" after the fork — by nature.

5. **`0x44` semantics post-Shanghai:** becomes `PREVRANDAO` returning a constant
   zero (Clique has no RANDAO), exactly as the protocol intends post-merge. Pre-fork
   it remains `DIFFICULTY`. Contracts that read `block.difficulty`/`block.prevrandao`
   should expect 0 after the fork (same as any post-merge chain with no beacon).

### Consensus safety among patched nodes
No divergence is expected, **conditional on** the single seal-hash field ordering
(§3c) being identical on every node (it will be — same binary) and the integration
tests passing. The 4-signer identical-hash test (Verification step 1) is the
explicit gate for this before any production use.

> **Bottom line for your question:** It will not break previous versions or existing
> chains that don't enable the forks. It does *intentionally* create a fork
> boundary at `shanghaiTime`/`cancunTime` that stock geth cannot cross — so treat
> activation like any mainnet hard fork: upgrade all nodes first, schedule the
> timestamp in the future.

---

## Why Clique Is Stuck at London Today

The root reason Shanghai/Cancun are off on Clique is **not** a single flag — it is
the interaction of the EVM Rules gate with how Clique sets header difficulty:

`core/evm.go:61-63` sets the EVM's `Random` (and thus the `isMerge` argument fed
to `Rules()` at `core/vm/evm.go:146`) only when `header.Difficulty == 0`:
```go
if header.Difficulty.Cmp(common.Big0) == 0 {
    random = &header.MixDigest
}
```
Clique difficulty is always 1 (`diffNoTurn`) or 2 (`diffInTurn`)
(`consensus/clique/clique.go:69-70`), so `random == nil` → `isMerge == false` →
`rules.IsShanghai/IsCancun` are forced false even when `shanghaiTime`/`cancunTime`
are set. This single fact drives several downstream bugs below.

---

## The Complete Change Set (8 edits across 4 files)

Each item is tagged with audit status and severity.

### File 1 — `params/config.go` · `Rules()` (lines 913-932)

**[CONFIRMED — reviewer Issue 1 valid]** Enable Shanghai/Cancun for Clique, but
**scope it narrowly**. The first draft used one `isPostMerge` flag for all four
post-merge forks; the audit confirmed Prague/Verkle are **no-op placeholders** in
v1.13.15 (only referenced in `core/vm/jump_table_export.go:29-32`, which is off
the live execution path and just returns "fork not defined yet"). Auto-enabling
them on Clique would be an untested future foot-gun.

**Final change:**
```go
isMerge = isMerge && c.IsLondon(num)
// Clique (PoA) chains never reach the PoS Merge, but must still be able to
// activate the post-merge *timestamp* forks. Scope this to the forks we have
// actually implemented & audited for non-merge operation (Shanghai, Cancun).
// Prague/Verkle stay gated on isMerge until separately reviewed.
isShanghaiCapable := isMerge || c.Clique != nil
return Rules{
    ...
    IsMerge:    isMerge,
    IsShanghai: isShanghaiCapable && c.IsShanghai(num, timestamp),
    IsCancun:   isShanghaiCapable && c.IsCancun(num, timestamp),
    IsPrague:   isMerge && c.IsPrague(num, timestamp),   // unchanged
    IsVerkle:   isMerge && c.IsVerkle(num, timestamp),   // unchanged
}
```
**Safety:** Guarded on `c.Clique != nil`. Mainnet (Ethash) and PoS chains are
`c.Clique == nil` → zero behavioral change. The opcodes this unlocks (PUSH0,
MCOPY, TLOAD/TSTORE, BLOBHASH, BLOBBASEFEE, KZG precompile `0x0a`) were each
verified to have **no beacon-chain dependency** (`core/vm/eips.go`,
`core/vm/jump_table.go:83-99`). **Severity addressed: Medium-High.**

---

### File 2 — `core/evm.go` · `NewEVMBlockContext` (lines 61-63)

**[NEW — CRITICAL — missed by both the plan and the reviewer]**
PREVRANDAO (opcode `0x44`) nil-pointer panic.

Once `rules.IsShanghai/IsCancun` become true on Clique, the EVM selects the
merge/shanghai/cancun jump table (`core/vm/interpreter.go:59-62`), in which
`0x44` is rebound from `DIFFICULTY` to `opRandom` (`core/vm/jump_table.go:103`).
`opRandom` dereferences `Context.Random` (`core/vm/instructions.go:478-479`):
```go
v := new(uint256.Int).SetBytes(interpreter.evm.Context.Random.Bytes())
```
On Clique `Random == nil` (per the difficulty fact above), and `Hash.Bytes()` is
a value receiver — so **any contract executing PREVRANDAO panics the EVM node.**
Before this change Clique never reached `opRandom` because the merge table was
never selected; enabling Shanghai exposes it.

**⚠ Backward-compat hazard — this fix MUST be gated on Shanghai being active.**
`core/vm/evm.go:146` derives the `isMerge` argument as `blockCtx.Random != nil`:
```go
chainRules: chainConfig.Rules(blockCtx.BlockNumber, blockCtx.Random != nil, blockCtx.Time)
```
So setting `random` non-nil **unconditionally for Clique** would flip `isMerge`
true for *pre-Shanghai* blocks too → the interpreter selects the merge table →
opcode `0x44` changes from **DIFFICULTY** (returns 1/2 on Clique) to **PREVRANDAO**
(returns 0). That changes execution of existing Clique history → **consensus break
with prior versions.** It must only fire once Shanghai is active.

`NewEVMBlockContext` (`core/evm.go:41`) takes `chain ChainContext`, which today
exposes only `Engine()`/`GetHeader()` — **no chain config**. `header.Number` and
`header.Time` *are* available (set in `prepareWork` before tx execution, and present
on import), so the only missing piece is `IsShanghai`. Add config access via one of:
- **(preferred)** add `Config() *params.ChainConfig` to the `ChainContext`
  interface (the `*core.BlockChain` already has it) and gate on it; or
- pass `*params.ChainConfig` into `NewEVMBlockContext` (touches callers).

**Final change** — give Clique a deterministic zero PREVRANDAO, *only* post-Shanghai:
```go
if header.Difficulty.Cmp(common.Big0) == 0 {
    random = &header.MixDigest
} else if cfg := chain.Config(); cfg.Clique != nil && cfg.IsShanghai(header.Number, header.Time) {
    // Clique has no RANDAO. Once Shanghai opcodes are active, opcode 0x44 becomes
    // PREVRANDAO; expose a stable zero value so opRandom does not nil-deref.
    // Gated on IsShanghai so PRE-Shanghai blocks keep 0x44 == DIFFICULTY (no
    // behavior change for existing chains / prior history).
    random = &header.MixDigest // MixDigest is zero-enforced for Clique
}
```
Why `header.MixDigest` (not `new(common.Hash)`): Clique forces `MixDigest` to zero
(`clique.go:567` sets it, `:285` rejects non-zero), so it is already the correct
zero value, and using the header field keeps mining and import identical.

**Why this is reliable during mining** (where `header.WithdrawalsHash` is not yet
set when txs execute — it is populated later in `FinalizeAndAssemble`): the gate
uses `IsShanghai(header.Number, header.Time)`, which depends only on
`header.Number`/`header.Time` (both set in `prepareWork`), **not** on any
not-yet-populated header field. So a tx calling PREVRANDAO during mining is safe.

**Severity: Critical (node panic / DoS, AND latent consensus break if gated wrong).**

---

### File 3 — `consensus/clique/clique.go` (four edits)

#### 3a. `verifyHeader` — replace fork rejection with field-presence validation (lines 302-320)
**[CONFIRMED — reviewer Issues 3 & 4]**

Replace the outright Shanghai/Cancun rejections with per-fork field checks. For
withdrawals the audit established the load-bearing rule precisely:

```go
// Shanghai: header must carry an EMPTY withdrawals commitment (PoA has no
// withdrawals). Requiring exactly EmptyWithdrawalsHash — not merely non-nil — is
// what blocks a malicious signer from committing to a real withdrawals list.
if chain.Config().IsShanghai(header.Number, header.Time) {
    if header.WithdrawalsHash == nil {
        return errors.New("missing withdrawalsHash")
    }
    if *header.WithdrawalsHash != types.EmptyWithdrawalsHash {
        return fmt.Errorf("invalid withdrawalsHash: have %x, want %x",
            *header.WithdrawalsHash, types.EmptyWithdrawalsHash)
    }
} else if header.WithdrawalsHash != nil {
    return fmt.Errorf("invalid withdrawalsHash: have %x, expected nil", header.WithdrawalsHash)
}

// Cancun: blob-gas fields + parentBeaconRoot must be present (non-nil).
// Their *values* are validated in verifyCascadingFields (blob gas) / accepted as
// zero (beacon root — no code anywhere requires beaconRoot != zero, only != nil).
if chain.Config().IsCancun(header.Number, header.Time) {
    if header.ExcessBlobGas == nil {
        return errors.New("missing excessBlobGas")
    }
    if header.BlobGasUsed == nil {
        return errors.New("missing blobGasUsed")
    }
    if header.ParentBeaconRoot == nil {
        return errors.New("missing parentBeaconRoot")
    }
} else {
    switch {
    case header.ExcessBlobGas != nil:
        return fmt.Errorf("invalid excessBlobGas: have %d, expected nil", header.ExcessBlobGas)
    case header.BlobGasUsed != nil:
        return fmt.Errorf("invalid blobGasUsed: have %d, expected nil", header.BlobGasUsed)
    case header.ParentBeaconRoot != nil:
        return fmt.Errorf("invalid parentBeaconRoot, have %#x, expected nil", header.ParentBeaconRoot)
    }
}
```
`types.EmptyWithdrawalsHash` is defined at `core/types/hashes.go:42`.

**This `verifyHeader` is the single consensus chokepoint** — the audit confirmed
it runs on mined, imported, *and* synced blocks via
`blockchain.go:1576 → engine.VerifyHeaders → verifyHeader`. Combined with
`ValidateBody`'s existing `DeriveSha(withdrawals) == header.WithdrawalsHash` check
(`core/block_validator.go:78-79`), a non-empty withdrawals body is provably
impossible. **This closes reviewer Issue 4 (the import-path divergence) — which
the audit confirmed was a real gap: `FinalizeAndAssemble` rejects withdrawals but
the import path `Process → Clique.Finalize` silently *ignores* them.**

#### 3b. `verifyCascadingFields` — add EIP-4844 blob-gas validation (after line ~363)
**[CONFIRMED — reviewer Issue 3]**
After the EIP-1559 base-fee check and once `parent` is resolved:
```go
if chain.Config().IsCancun(header.Number, header.Time) {
    if err := eip4844.VerifyEIP4844Header(parent, header); err != nil {
        return err
    }
}
```
`eip4844.VerifyEIP4844Header` (`consensus/misc/eip4844/eip4844.go:36`) validates
`BlobGasUsed` within range and `ExcessBlobGas` correctly derived from parent.
Add import `"github.com/ethereum/go-ethereum/consensus/misc/eip4844"`.

#### 3c. `encodeSigHeader` / `SealHash` — stop panicking on Shanghai/Cancun fields (lines 766-777)
**[NEW — CRITICAL — missed by the first draft]**

`encodeSigHeader` (the RLP fed to `SealHash`, which is what each signer signs and
what derives block identity) currently **panics** on any Shanghai/Cancun field:
```go
if header.WithdrawalsHash != nil { panic("unexpected withdrawal hash value in clique") }
if header.ExcessBlobGas != nil   { panic("unexpected excess blob gas value in clique") }
if header.BlobGasUsed != nil     { panic("unexpected blob gas used value in clique") }
if header.ParentBeaconRoot != nil{ panic("unexpected parent beacon root value in clique") }
```
With Shanghai/Cancun enabled these fields are non-nil on **every** block, so a
signer **panics the instant it tries to seal**, and an importer panics computing
the seal hash → total chain halt. The fields must instead be **appended to the
RLP** (the same pattern as `BaseFee` at lines 763-765) so they are covered by the
signature. **Field order is consensus-defining and MUST match the canonical
`types.Header` RLP field order** (verified at `core/types/block.go:82-95`):
`BaseFee → WithdrawalsHash → BlobGasUsed → ExcessBlobGas → ParentBeaconRoot`.
Note `BlobGasUsed` precedes `ExcessBlobGas` — this matches the struct, and is the
reverse of the order the *existing panic checks* are written in (lines 769-773),
so do NOT copy the panic order:
```go
// immediately after the existing `if header.BaseFee != nil { ... }` block:
if header.WithdrawalsHash != nil {
    enc = append(enc, header.WithdrawalsHash)
}
if header.BlobGasUsed != nil {
    enc = append(enc, header.BlobGasUsed)
}
if header.ExcessBlobGas != nil {
    enc = append(enc, header.ExcessBlobGas)
}
if header.ParentBeaconRoot != nil {
    enc = append(enc, header.ParentBeaconRoot)
}
```
**Severity: Critical — without this, mining and import both crash.**

> **Reviewer ordering question — resolved.** The seal hash is a self-contained
> Clique format, so any *consistent* order keeps a same-binary network in
> agreement. But matching the canonical `types.Header` order above (a) avoids a
> Clique-specific header-hash encoding that diverges from how every other tool
> serializes a header, and (b) is what a maintainer reading the code expects.
> v1 of this section had `ExcessBlobGas`/`BlobGasUsed` swapped — corrected here
> against `core/types/block.go:82-95`. The 4-signer identical-hash integration
> test (below) is the backstop for any residual mistake.

#### 3d. `FinalizeAndAssemble` — support empty-withdrawals Shanghai blocks (lines 589-601)
**[CONFIRMED]**
Keep the `len(withdrawals) > 0 → error` guard (defense-in-depth), but use the
withdrawals-aware constructor so the header gets a correct `WithdrawalsHash`:
```go
func (c *Clique) FinalizeAndAssemble(...) (*types.Block, error) {
    if len(withdrawals) > 0 {
        return nil, errors.New("clique does not support withdrawals")
    }
    c.Finalize(chain, header, state, txs, uncles, nil)
    header.Root = state.IntermediateRoot(chain.Config().IsEIP158(header.Number))

    if chain.Config().IsShanghai(header.Number, header.Time) {
        // Present-but-empty withdrawals → header.WithdrawalsHash = EmptyWithdrawalsHash.
        return types.NewBlockWithWithdrawals(header, txs, nil, receipts,
            []*types.Withdrawal{}, trie.NewStackTrie(nil)), nil
    }
    return types.NewBlock(header, txs, nil, receipts, trie.NewStackTrie(nil)), nil
}
```
Audit-confirmed: `NewBlockWithWithdrawals` with an **empty (non-nil) slice** sets
`WithdrawalsHash = &EmptyWithdrawalsHash` (`core/types/block.go:265-266`); a `nil`
slice would leave it nil. We must pass the empty slice.

---

### File 4 — `miner/worker.go` · Cancun header prep
**[CONFIRMED]**
`genParams.beaconRoot` is nil for Clique (no engine API). Provide the zero hash so
the header field is present and consistent with import:
```go
header.BlobGasUsed = new(uint64)
header.ExcessBlobGas = &excessBlobGas
if genParams.beaconRoot != nil {
    header.ParentBeaconRoot = genParams.beaconRoot
} else {
    header.ParentBeaconRoot = new(common.Hash) // zero hash for non-beacon (Clique)
}
```

> **Ordering invariant (critical for Clique):** this whole `if IsCancun(header.Number,
> header.Time) { … }` block MUST run **after** `w.engine.Prepare(...)`, not before.
> Clique's `Prepare` rewrites `header.Time` to `max(parent.Time+period, now)`, so
> gating on the pre-`Prepare` timestamp mis-decides the block that crosses `cancunTime`
> on a `period ≥ 2` chain — it gets sealed without blob fields, is accepted locally
> (the miner does not re-verify its own block), and the next block nil-derefs
> `*parent.ExcessBlobGas`. Evaluate `IsCancun` against the **final** timestamp. PoS is
> unaffected (fixed timestamp). See Security Considerations row 11.

---

## EIP-4788 Decision — keep the system call, do NOT special-case it
**[Reviewer Issue 2 — partially refuted by audit; recommendation changed]**

The reviewer proposed a `DisableBeaconRootContract` flag or skipping
`ProcessBeaconBlockRoot` for Clique. **The audit shows that is the wrong call:**

- `ProcessBeaconBlockRoot` (`core/state_processor.go:173-191`) with a **zero root
  and no deployed contract** is a *provable no-op*: the EVM `Call` to an empty
  account returns `nil, gas, nil` (`core/vm/evm.go:192-204`), all return values
  are discarded (`_, _, _ =` at line 189), and no state changes. It cannot error
  and moves no funds.
- The call is guarded identically on both paths by `header.ParentBeaconRoot != nil`
  (import: `state_processor.go:79`; mining: `miner/worker.go:1013`) — already
  symmetric.
- A `DisableBeaconRootContract` flag is the **most** dangerous option: it is a
  consensus-affecting parameter every operator must set identically; one
  mismatched node → silent state-root divergence.
- An asymmetric "skip for Clique" is a latent bug: the moment a genesis deploys
  the 4788 bytecode (which we recommend for mainnet parity), the call stops being
  a no-op and a node that skips on one path diverges.

**Decision: leave `ProcessBeaconBlockRoot` running unchanged on both paths.** It is
free and harmless when the contract is absent, and correct if a genesis deploys it.

**Residual (application-level, not consensus):** Clique's beacon root is always
zero, whereas mainnet's changes each slot. A contract doing
`require(beaconRoots.get(...) != 0)` would always fail on this chain. This is an
inherent property of "PoA without a beacon chain," not a bug — documented as a
known semantic difference, not mitigated in code.

---

## Security Considerations (re-audited)

| # | Concern | Verdict | Control |
|---|---------|---------|---------|
| 1 | **Withdrawal injection on imported blocks** (reviewer Issue 4) | **Real gap, now closed** | `verifyHeader` requires `WithdrawalsHash == EmptyWithdrawalsHash` (chokepoint on all paths); `ValidateBody` binds body→hash. Clique `Finalize` ignores withdrawals, so the rejection MUST be at verify time, not finalize. |
| 2 | **PREVRANDAO nil-deref** (new) | **Critical, fixed** | `core/evm.go` sets zero `Random` for Clique. |
| 3 | **encodeSigHeader panic** (new) | **Critical, fixed** | Append fields to seal-hash RLP instead of panicking; fixed field order. |
| 4 | **EIP-4788 beacon semantics** (reviewer Issue 2) | Not a consensus risk | Keep system call symmetric; zero root is a provable no-op. App-level `!=0` assumptions documented. |
| 5 | **Blob networking assumes PoS** (reviewer Issue 5) | **Refuted** | All blob paths gate on `IsCancun(time)`, not TTD/beacon. `isTTDReached` is inert when `ttd==nil` (`worker.go:1231`). Blobpool always instantiated. Minor: limbo never prunes by finality (harmless disk retention). |
| 6 | **Hidden `IsMerge` assumptions** (reviewer Issue 1 meta) | Bounded | Only 2 consumers of `rules.IsMerge` (`interpreter.go:63`, `jump_table_export.go:37`), both EVM-internal jump-table selection. `IsMerge` itself stays gated on TTD — unchanged. |
| 7 | **Prague/Verkle accidental activation** (reviewer Issue 1) | Avoided | Scoped change to Shanghai+Cancun only; Prague/Verkle stay on `isMerge`. |
| 8 | **Mainnet / PoW safety** | Safe | All changes guarded on `c.Clique != nil`; mainnet uses Ethash. |
| 9 | **Config validation rejects Clique+Cancun-without-TTD** | No such rejection exists | `CheckConfigForkOrder` / `checkCompatible` (`config.go:606-743`) check only fork ordering, never TTD. Genesis builds Shanghai/Cancun headers fine. |
| 10 | **`createAccessList` precompile set** (`internal/ethapi/api.go:1501`) | Minor, non-consensus | Computes post-merge from difficulty, so Cancun KZG precompile omitted from access-list warmup on Clique. Tracing/estimation discrepancy only. Optional follow-up. |
| 11 | **Miner sets Cancun fields against pre-`Prepare` timestamp** (fork-boundary timing) | **Fixed** | `prepareWork` gated the Cancun header fields on `header.Time` *before* `clique.Prepare` rewrote it to `max(parent.Time+period, now)`. On a **timed** activation with `period ≥ 2`, the block crossing `cancunTime` was sealed without blob fields → accepted locally (miner does not re-verify) → next block nil-derefs `*parent.ExcessBlobGas` → panic. Field population moved to **after** `Prepare`. Impossible at `period 1` (timestamps identical) and for genesis-activated Cancun. Regression-tested by `smoke-test/transition.sh` at `period 5`. |

---

## Genesis File (new chains or migration)

```json
{
  "config": {
    "chainId": 12345,
    "homesteadBlock": 0, "eip150Block": 0, "eip155Block": 0, "eip158Block": 0,
    "byzantiumBlock": 0, "constantinopleBlock": 0, "petersburgBlock": 0,
    "istanbulBlock": 0, "berlinBlock": 0, "londonBlock": 0,
    "shanghaiTime": 0,
    "cancunTime": 0,
    "clique": { "period": 5, "epoch": 30000 }
  }
}
```
- **New chain:** `shanghaiTime`/`cancunTime` = 0 is fine.
- **Existing chain upgrading from London:** set both to a **future** Unix timestamp
  so all nodes upgrade binaries before activation (a timestamp fork at a past time
  would split the chain).
- **Optional mainnet parity:** add the EIP-4788 beacon-roots contract bytecode at
  `0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02` in `alloc` if you want `get(...)`
  to return real (zero) values instead of empty reverts.

---

## Implementation Order

1. `params/config.go` — `Rules()` scoped change (unblocks opcodes).
2. `core/evm.go` — zero `Random` for Clique (prevents PREVRANDAO panic).
3. `consensus/clique/clique.go` — 3a verifyHeader, 3b cascading EIP-4844, 3c
   encodeSigHeader RLP, 3d FinalizeAndAssemble. (Do 3c before any sealing test.)
4. `miner/worker.go` — zero beacon-root fallback.
5. `go build ./...` and run targeted unit tests (`consensus/clique`, `core`,
   `params`, `core/vm`).

---

## Verification / Testing Plan (per reviewer Issue 6 — engineering risk)

The reviewer's strongest meta-point: the rejections were deliberate, so removing
them exposes untested paths. Mitigate with integration tests, not just unit tests:

1. **4-signer Clique testnet, Cancun active at genesis.** Confirm all nodes
   produce **identical block hashes** for the same height (catches any seal-hash
   field-ordering or beacon-root asymmetry).
2. **Opcode smoke contract:** deploy and execute PUSH0, MCOPY, TLOAD/TSTORE,
   **PREVRANDAO (0x44)** — the last specifically regresses the nil-deref fix.
3. **Blob tx round-trip:** submit a type-3 tx; confirm pool acceptance, p2p
   propagation, inclusion in a sealed block, and clean re-import on a second node.
4. **Adversarial import fuzz:** feed crafted blocks with (a) non-empty
   withdrawals matching a forged `WithdrawalsHash`, (b) `WithdrawalsHash != Empty`,
   (c) wrong `ExcessBlobGas`, (d) missing Cancun fields — all must be rejected by
   `verifyHeader`/`verifyCascadingFields`, none should panic.
5. **Restart/replay:** stop a node mid-chain and re-sync from a peer to exercise
   the header-only and full-block import paths through the new validation.
6. **Access-list / estimation regression** (reviewer follow-up): assert
   `eth_createAccessList` / `eth_estimateGas` warm the Cancun KZG precompile
   (`0x0a`) on a Clique Cancun chain. This is non-consensus, but `createAccessList`
   computes "post-merge" from block difficulty (`internal/ethapi/api.go:1499-1501`),
   so on Clique it currently omits Cancun precompiles from the warm set → tooling
   gas estimates can differ. A regression test pins the expected behavior even if
   we defer the fix.

---

## Appendix — Why Besu QBFT Runs Cancun and geth Clique Cannot

> **Important correction (verified against Besu source):** It is **QBFT/IBFT2**,
> not Besu's Clique, that runs Cancun. **Besu's Clique cannot mine Shanghai/Cancun
> either** — a Besu Clique node with `shanghaiTime` set fails at block production
> with `withdrawals must not be null when Withdrawals are activated` →
> `Illegal block mined` (Besu issue #8532, closed "not planned"). Besu then
> **deprecated Clique (25.12.0) and removed it (26.4.0)**. So *neither* geth Clique
> *nor* Besu Clique runs Cancun out of the box — only Besu's BFT engines do. Our
> patch would make geth Clique do something **no shipped PoA-Clique can currently
> do**. The two failure modes differ instructively:
> - **geth Clique** fails *loudly and by design*: `verifyHeader` returns
>   `"clique does not support … fork"` and `encodeSigHeader` panics on the new fields.
> - **Besu Clique** fails *quietly and by omission*: its decorator architecture lets
>   Clique *import* withdrawals-bearing blocks fine, but its block **creator** passes
>   *absent* withdrawals (`Optional.empty()`) instead of an empty list, so the
>   inherited mainnet `AllowedWithdrawals` validator rejects Clique's own mined block.
>   Besu never added the `NotApplicableWithdrawals` no-op validator to Clique (it did
>   for QBFT/IBFT2).
>
> **This directly cross-validates our plan §3d:** Besu Clique broke precisely
> because it supplied `Optional.empty()` (nil) rather than an empty list. Our
> `FinalizeAndAssemble` passes `[]*types.Withdrawal{}` (empty, non-nil) →
> `WithdrawalsHash = EmptyWithdrawalsHash` — the exact distinction Besu Clique got
> wrong. Passing `nil` would reproduce the Besu bug in geth.

The architecture comparison below is about Besu's **QBFT/IBFT2** engines (which do
run Cancun). The answer is **architectural, not incidental**, and it shows our
patch is fighting geth's design rather than a simple bug.

**Besu layers consensus as a decorator over a consensus-agnostic fork schedule.**
Besu's `ProtocolScheduleBuilder` builds the full mainnet schedule first — Shanghai
and Cancun are registered as ordinary **timestamp milestones**
(`getShanghaiTime()`/`getCancunTime()`), with all withdrawals / blob-gas / EIP-4788
machinery already wired. BFT then injects itself through `ProtocolSpecAdapters`, a
`block → Function<ProtocolSpecBuilder, ProtocolSpecBuilder>` map. `applyBftChanges`
**overrides only** the consensus-specific pieces — header validation, `difficulty=1`,
the seal/header-hash functions, and a no-op `WithdrawalsValidator.NotApplicableWithdrawals`
— and **inherits** the EVM, block importer, body validator, fee market, and fork
gating from mainnet untouched. Enabling Cancun on QBFT is therefore a genesis flip.

**geth fuses the fork gate into the Clique engine, and gates it behind the Merge.**
Three structural differences map exactly onto the bugs we had to patch:

| Dimension | Besu BFT | geth Clique (this repo) |
|---|---|---|
| Fork gating | Timestamp milestone in a shared schedule; no merge concept | `IsShanghai/IsCancun` gated behind `isMerge`/TTD (`params/config.go`), and Clique is wrapped by the beacon engine (`eth/ethconfig/config.go`) which only routes to the fork-aware verifier *after TTD* |
| Header rejection | BFT overrides only header rules; mainnet fork rules inherited | `clique.verifyHeader` hard-returns `"clique does not support shanghai/cancun fork"` |
| Seal/header hashing | Reuses the **generic** `BlockHeader.writeTo` (writes optional fields if present) → never panics on new fields | `clique.encodeSigHeader` hand-lists fields and **panics** on each new one |
| PREVRANDAO (0x44) | BFT sets a fixed non-zero `mixHash` constant ("…byzantine fault tolerance"); 0x44 returns it | `Random==nil` on Clique → `opRandom` nil-derefs (our `core/evm.go` fix) |
| Withdrawals | `NotApplicableWithdrawals` no-op validator | We enforce `WithdrawalsHash == EmptyWithdrawalsHash` in `verifyHeader` |
| EIP-4788 | Zero root passed; system call still fires; 4788 contract must be in genesis `alloc` | Same approach in our plan (zero root, keep the call) |

**Bottom line:** Besu kept BFT a **first-class, permanently maintained** consensus
option behind a clean schedule/consensus separation, so post-Merge forks were a
near-zero-cost fit. geth made Clique an **intentional pre-Merge dead-end** —
deprecated in v1.14, with maintainers explicitly steering private networks to PoS.
Our patch essentially re-creates, by hand, the decoupling Besu has by design:
unbind the forks from the Merge (File 1), and stop the Clique engine from rejecting
or panicking on the new header fields (Files 2-3). It is sound for a private network,
but it is swimming against geth's deprecation current — every future geth upgrade
may re-introduce assumptions we have to re-patch (the engineering risk in Issue 6).

Sources: Besu PR #6353 (QBFT+Shanghai), PR #9830 (`NotApplicableWithdrawals` restore),
Consensys `besu-qbft-docker` genesis (`cancunTime: 0` + `qbft`), Besu issue #9379
(4788 contract in alloc); geth Clique deprecation (issues #29877, #29319) — full
list captured in the audit notes.

---

## Out of Scope
- Prague / Verkle (deliberately left gated on `isMerge`).
- Engine API / Beacon Chain integration (by design — not needed for PoA).
- `createAccessList` precompile-set fix (`api.go:1501`) — optional, non-consensus
  (regression test added above to pin behavior).
