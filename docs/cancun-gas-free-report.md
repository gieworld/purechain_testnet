# PureChain Cancun Upgrade — Why It's Safe and Stays Gas-Free

**Audience:** management / non-implementers
**Status:** implemented, tested, gas-free confirmed
**Date:** 2026-06-30

---

## One-line summary

The Cancun upgrade does **not** introduce a gas fee. The network stays gas-free,
the change to the client is minimal and reversible, and all of this has been
tested end-to-end.

---

## The whole story

### 1. The original assessment (and why it was right *at the time*)

Our first plan looked at upgrading the network **without modifying the client** —
just running standard go-ethereum and turning on newer protocol milestones.

On that "no modification" path, two hard limits apply:

1. **You can't reach the modern forks at all.** Standard geth blocks Shanghai and
   Cancun on a PoA (Clique) network — it assumes those only run on Ethereum's
   post-Merge proof-of-stake chain, so the node refuses to run. The furthest you
   can realistically go is **London**.

2. **Reaching London turns on a mandatory gas fee.** London is the milestone that
   introduces the EIP-1559 **base fee** — a fee charged on every transaction. On
   standard geth that base fee can't be set to zero, and the client even silently
   rewrites a "zero fee" setting back up to a positive value.

So the original conclusion was correct **for the no-modification path**:

> Go modern (no client change) → you must land on London → London forces a base
> fee → **a gas fee becomes unavoidable.**

That's why the earlier, safest plan assumed we'd have to enable a gas fee.

> *Side note:* the last milestone that's naturally gas-free is **Berlin** — but
> Berlin alone doesn't include the modern features we want (PUSH0, transient
> storage, blob support, etc.). So without modification we were stuck choosing
> between *free gas but old features* (Berlin) or *modern but paid* (London).
> Shanghai/Cancun weren't reachable at all.

### 2. What we learned

The earlier assessment didn't account for one option: a **small client-side
modification**. Importantly, the Cancun protocol itself is **already fully built
into go-ethereum** — we did not write or change the protocol. We only adjusted the
client so our PoA network is *allowed* to use the Cancun code that already exists,
and so the base fee is held at zero.

This breaks the old trade-off: we can now reach **Cancun** (full modern feature
set) **and** keep gas at **zero** — something the no-modification path could never
do.

### 3. What actually changed (kept to the minimum)

Three small adjustments, no new protocol rules:

1. **Removed a "proof-of-stake only" gate** — standard geth assumed Cancun only
   runs on the post-Merge chain; we let our PoA chain use it.
2. **Filled in the new block fields** (blob-gas fields) that PoA left empty, so
   blocks validate instead of the node crashing.
3. **Added a genesis switch (`zeroBaseFee`) that holds the base fee at 0** — this
   is what keeps gas free.

No chain reset, no change to existing balances or history, and the change is
reversible.

### 4. Why gas stays free

With the base-fee switch on, every transaction's fee computes to **zero**, and our
nodes accept zero-fee transactions. A user transaction costs **0**. Confirmed
end-to-end in testing:

- Zero-fee transactions (both legacy and modern EIP-1559 style) are accepted and
  mined.
- The resulting blocks/receipts show `baseFeePerGas = 0` and
  `effectiveGasPrice = 0`.
- No node crashes.

### 5. Tested

A full smoke-test suite passes against the new client, covering:

- gas-free transactions (the core promise),
- the in-place upgrade from our current network (genesis hash preserved, no reorg,
  no crash),
- wallet and library compatibility (MetaMask, ethers.js),
- a safe-rollback check.

All green.

---

## Optional, and currently OFF: charging a fee later

Staying free now does **not** lock us out of charging later. If we ever decide to,
it can be done through a small per-node setting (a minimum tip) — **no protocol
fork and no chain reset**, fully reversible. It exists as insurance only and is
**not enabled today**.

---

## Bottom line for management

- Our original "it'll need a gas fee" assessment assumed **no client change** —
  that path tops out at London, and London forces the fee.
- With a **minimal, reversible client modification**, we reach **Cancun** (modern
  features) **and keep gas at zero**.
- It's implemented, tested, and gas-free is confirmed.
