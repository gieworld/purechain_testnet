# PureChain upgrade rehearsal

A dress rehearsal for a PureChain node binary upgrade, run
entirely in local Docker. This directory is both the harness and the campaign
spec.

## Why this exists

The smoke-test suite (`smoke-test/`) proves the binaries are correct on
ephemeral networks it invents. This rehearsal proves the **upgrade procedure**
is safe on a network shaped like one that is actually operating — because a
running deployment has three properties no smoke test modeled:

1. **On-demand sealing ("smart auto-mining").** Validators run WITHOUT
   `--mine`; automine sidecars attach over IPC and start/stop the miner based
   on activity (`scripts/autoMine-v2.js`). No empty blocks when idle — and a
   whole class of upgrade risk (does that behavior survive the new binary?)
   that must be tested.
2. **The relay-arming trap.** After a restart, a geth node accepts RPC
   transactions but does NOT gossip them until a downloader sync re-arms it.
   A binary upgrade IS a restart, so every node swap here is followed by a
   STRICT relay check (the validator's miner is frozen first, so it cannot
   fake a pass by mining its own transaction).
3. **Fork-sensitive bring-up.** Starting every validator simultaneously can
   split a Clique network before the peer mesh exists, and in-place rewinds
   (`debug.setHead`) can fork it. Bring-up here is sequential with a
   consistency gate before any sealing, and `debug.setHead` is never used.

Fidelity details: period-1 clique, zeroBaseFee + gasprice 0 everywhere,
`syncmode=full`, `gcmode=archive`, `snapshot=false`, `cache=256`, 1g memory
limit, SIGINT + 2m grace, `restart: unless-stopped`, `--nodiscover` + static
peering, and RPC nodes exposing `eth,net,web3` only. Genesis reproduces a
realistic fork history: Berlin/London activate mid-chain (block 120),
Shanghai+Cancun by timestamp (~8 min after start), so the chain being upgraded
contains genuine pre-fork history.

Keys are throwaway test keys (well-known hardhat accounts) — never reuse them,
and never point this harness at a real network.

## Layout

    drive.sh          campaign driver — phases with gates (see below)
    docker-compose.yml  6 nodes + 4 automine sidecars + monitor + loadgen
    Dockerfile.node   node image recipe, parameterized old/new binary
    genesis.tpl.json  deployment-shaped genesis (fork time stamped at prep)
    scripts/          entrypoint.sh + autoMine-v2.js (the real ones),
                      addpeers.js (generated, deterministic nodekeys)
    loadgen/          ethers.js client: load, latency probes, ramp,
                      contract/event checks, relay checks
    monitor/          referee: heads, settled-hash agreement, alerts
    artifacts/        all evidence: CSVs, gates.log, tripwires, REPORT.md

## Running

    ./drive.sh all          # complete campaign (~3h), stops at first failed gate
    ./drive.sh prep         # or phase by phase: prep, p1, p2, ... p8
    ./drive.sh down         # tear down (artifacts/ kept)

## Phases and what each gate proves

| Phase | What happens | Gate |
|---|---|---|
| prep | build old/new images, genesis, keys | builds succeed |
| p1 | sequential bring-up, relay arming, cross berlin/london by height then shanghai+cancun by time under load, baseline load + latency probes (busy and cold) on OLD | all agree pre-sealing; cancun live; automine stops when idle; zero tripwires |
| p2 | rolling upgrade to NEW under load: node5,6 (RPC) then 2,3,4,1 (validators), one at a time | each node: caught up, reports NEW commit, **relays txs**, chain advanced during swap, all agree |
| p3 | post-upgrade battery: same probes as baseline, automine behavior identical, contract deploy/event/getLogs/call via public API, HTTP polling continuity, fresh node7 full-syncs from genesis | metrics same-or-better; novelty preserved; whole history re-executable |
| p4 | recommit 750ms: flip validators one at a time, re-probe latency, then 5-min signer outage under load at 750ms | relay + agreement after each flip; chain keeps real progress through outage (wiggle deadline fix in target config) |
| p5 | stress: ramp to the ceiling, hold 80%, stop node3 5 min + `kill -9` node4 mid-hold | ceiling reported; chain advances through both; node4 auto-revives + re-syncs (no DB corruption); relays re-arm |
| p6 | signer-quorum halt drill: stop node1+node2 | chain HALTS (drift <= 2 — Clique limit=3/4 confirmed); resumes within seconds once quorum is restored AND the returning signers' miners are started (one signer alone is usually pinned by the frozen recent-signers window) |
| p7 | rollback: node3 alone back to OLD (mixed soak) then forward; FULL network rollback to OLD (abort path), soak, then forward to final all-NEW state | OLD reads NEW's writes both times; relays re-arm every restart; all agree at every step |
| p8 | report | `artifacts/REPORT.md` with gates, latency table, ceiling, alerts |

## Reading the results

`artifacts/gates.log` is the authoritative pass/fail trail. `summaries.jsonl`
carries every latency probe (median/mean/p95): compare `base-*` vs `post-*`
(upgrade must not regress) and vs `rc750-*` (what the recommit change buys;
expect busy-probe median ~2.0s -> ~1.0s, cold probes unchanged — cold latency
is governed by the automine poll interval, not recommit). `monitor.csv` +
`alerts.log` are the referee's record; `tripwires.log` must stay empty.
