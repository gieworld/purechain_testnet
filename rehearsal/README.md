# PureChain upgrade rehearsal

A dress rehearsal for a PureChain node binary upgrade, run entirely in local
Docker. This directory is both the harness and the campaign spec.

## Why this exists

The smoke-test suite (`smoke-test/`) proves the binaries are correct on
ephemeral networks it invents. This rehearsal proves the **upgrade procedure**
is safe on a network shaped like one that is actually operating — because a
running deployment has three properties no smoke test modeled:

1. **On-demand sealing ("smart auto-mining").** Validators run WITHOUT
   `--mine`; four automine sidecars attach over IPC and start/stop the miner
   based on activity (`scripts/autoMine-v2.js`). No empty
   blocks when idle — and a whole class of upgrade risk (does the novelty
   survive the new binary?) that must be tested.
2. **The relay-arming trap.** After a restart, a geth node accepts RPC
   transactions but does NOT gossip them until a downloader sync re-arms it —
   a deployment's bring-up script needs an explicit arming step because of
   this, and a binary upgrade IS a restart. Every node swap here is followed
   by a STRICT relay check (validator's miner frozen so it cannot fake a pass
   by mining its own tx).
3. **Fork-sensitive bring-up.** Starting every validator simultaneously can
   split a Clique network before the peer mesh exists, and an in-place rewind
   (`debug.setHead`) can fork it. Bring-up here is sequential with a
   consistency gate before any sealing, and `debug.setHead` is never used.

Prod-fidelity details: chainId 424242, period-1 clique, zeroBaseFee +
gasprice 0 everywhere, `syncmode=full`, `gcmode=archive`, `snapshot=false`,
`cache=256`, 1g mem limit, SIGINT + 2m grace, `restart: unless-stopped`,
`--nodiscover` + static addpeers, public RPC nodes expose `eth,net,web3` only.
Genesis mirrors the real fork history in shape: berlin/london activate
mid-chain (block 120), shanghai+cancun by timestamp (~6 min after start), so
the chain the upgrade runs on contains pre-fork history like the real one.

Deliberate deviations: throwaway test keys only (well-known hardhat accounts —
never reuse them, and never point this harness at a real network), no
`--nat`/ethstats (the monitor sidecar records what ethstats would show), and a
genesis gasLimit of 30M, the effective limit in practice.

## Layout

    drive.sh          campaign driver — phases with gates (see below)
    docker-compose.yml  6 nodes + 4 automine sidecars + monitor + loadgen
    Dockerfile.node   node image recipe, parameterized old/new binary
    genesis.tpl.json  deployment-shaped genesis (fork time stamped at prep)
    scripts/          entrypoint.sh, autoMine-v2.js (SAM), poa2.js (PoA²),
                      addpeers.js (generated, deterministic nodekeys)
    loadgen/          ethers.js client: load, latency probes, ramp,
                      contract/event checks, relay checks
    quick-poa2.sh     90-second PoA² smoke test (detect -> promote -> remove)
    poa2-edge.sh      PoA² during a rolling upgrade / dead sidecar / repeat fault
    poa2-test-b.sh          healthy node whose miner stopped
    poa2-test-phantom.sh    standby with no node behind it
    poa2-test-reachability.sh  down vs not-sealing
    poa2-test-exhaustion.sh    standby pool empty
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
| p6 | two-signer halt drill: stop node1+node2 | chain HALTS (drift <= 2 — Clique limit=3/4 confirmed); resumes promptly when a third signer returns |
| p7 | rollback: node3 alone back to OLD (mixed soak) then forward; FULL network rollback to OLD (abort path), soak, then forward to final all-NEW state | OLD reads NEW's writes both times; relays re-arm every restart; all agree at every step |
| p8 | report | `artifacts/REPORT.md` with gates, latency table, ceiling, alerts |
| p9 | PoA² validator replacement: no false positives, genuine fault, repeat fault, dead sidecar, phantom standby | run separately (`all` stops at p8) |

`./drive.sh recover` re-arms transaction relay after a whole-network restart —
without it a restarted network accepts transactions, gossips none, and mines
nothing while looking healthy.

## Reading the results

`artifacts/gates.log` is the authoritative pass/fail trail. `summaries.jsonl`
carries every latency probe (median/mean/p95): compare `base-*` vs `post-*`
(upgrade must not regress) and vs `rc750-*` (what the recommit change buys;
expect busy-probe median ~2.0s -> ~1.0s, cold probes unchanged — cold latency
is governed by the automine poll interval, not recommit). `monitor.csv` +
`alerts.log` are the referee's record; `tripwires.log` must stay empty.
