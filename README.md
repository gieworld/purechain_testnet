# PureChain Testnet — execution client

**[📖 Documentation](https://gieworld.github.io/purechain-docs/)** ·
**[⬇️ Download](https://github.com/gieworld/purechain_testnet/releases/latest)** ·
**[🚀 Run your own network](https://gieworld.github.io/purechain-docs/02-run-your-own/)**

The execution client for the **PureChain testnet**: a permissioned, **free-gas**
EVM network. Transactions cost zero — no base fee, no tip — and blocks are
produced by a known set of validators rather than by open mining or staking.

It is a fork of **go-ethereum v1.13.15**, kept deliberately close to upstream so
the client behaves like the geth operators already know: same CLI, same
JSON-RPC, same tooling (MetaMask, ethers, Hardhat, block explorers). The fork
exists because PureChain needs a combination stock geth no longer supports — a
**Clique (Proof-of-Authority)** validator set running the **current EVM**
(Shanghai and Cancun: PUSH0, transient storage, EIP-4788) with zero-cost
transactions. Upstream ties post-Shanghai forks to the PoS Merge and removed
Clique in v1.14, so this fork keeps that path alive.

Every change is gated on `Clique != nil` / `zeroBaseFee` / `IsShanghai`, so the
same binary still runs an ordinary Ethereum chain unchanged.

> **Network parameters** (chain ID, validators, activation times) are
> provisioned per deployment and are **not** hard-coded here — examples in this
> repository use the placeholder chain ID `424242`. See [`network/`](network/)
> to generate a genesis for your own validator set.

## Quick start

Download a static binary from the [latest release](https://github.com/gieworld/purechain_testnet/releases/latest)
(linux amd64/arm64, no libc dependency), verify it, and run it:

```bash
sha256sum -c SHA256SUMS.txt
./purechain-geth-v1.0.0-linux-amd64 version    # Git Commit must match the release
```

- **Connect to the public network** — RPC endpoint, chain ID and wallet setup
  are in the [documentation](https://gieworld.github.io/purechain-docs/).
- **Run your own network** — [step-by-step guide](https://gieworld.github.io/purechain-docs/02-run-your-own/):
  generate a genesis, start validators, add RPC nodes.

> **Every node on a free-gas network needs `--txpool.pricelimit 0`** — mining or
> not. Without it a node silently drops and refuses to relay zero-fee
> transactions. It is the most common misconfiguration.

## What changed from upstream go-ethereum

Roughly **220 lines across 14 files** for the fork itself. The
consensus-affecting changes are what make this a real fork rather than
configuration:

| Area | Key files | Summary |
|---|---|---|
| Clique → Cancun | `consensus/clique/`, `params/config.go`, `core/evm.go`, `miner/worker.go` | Accept and seal Shanghai/Cancun headers without panicking, enable the EVM forks for Clique, zero PREVRANDAO and `parentBeaconRoot` |
| Free gas | `consensus/misc/eip1559`, `core/genesis.go`, `eth/backend.go`, `internal/ethapi` | `zeroBaseFee` genesis flag pins the base fee to 0; allow `--miner.gasprice 0`; accept zero-fee transactions over RPC |
| Non-merge fixes | `eth/fetcher/`, `internal/era`, `core/txpool/blobpool` | Preserve block withdrawals on gossip and history paths that upstream assumes die at the Merge |
| Clique sealing | `consensus/clique/wiggle.go` | Out-of-turn delay drawn once per block and anchored to an absolute deadline, making sub-period `--miner.recommit` safe on multi-signer chains |
| Upstream backports | across `core/`, `crypto/`, `eth/`, `p2p/`, `rpc/` | 31 security and stability fixes from v1.13.15 → v1.17.5 |

Full per-file ledger in [`CHANGELOG.md`](CHANGELOG.md); the backport adoption
matrix, including what was rejected and why, in
[`docs/upstream-backports.md`](docs/upstream-backports.md).

## Repository layout

| Path | What it is |
|---|---|
| [`docs/`](docs/) | Design rationale, operator guide, upgrade runbook, backport matrix |
| [`network/`](network/) | Example genesis and `gen-genesis.sh` generator |
| [`smoke-test/`](smoke-test/) | Dockerised regression and compatibility suite (`run-all.sh`) |
| [`rehearsal/`](rehearsal/) | Six-node harness for rehearsing a node upgrade end to end — rolling upgrade under load, stress, outage and crash drills, rollback — plus the PoA² validator-replacement controller and its tests |

## Building from source

Requires Go 1.19 or later (and a C compiler only for cgo builds).

```bash
git clone https://github.com/gieworld/purechain_testnet.git
cd purechain_testnet
make geth                     # or: make all, for the full tool suite
```

For the portable artifact that ships in releases — statically linked, runs on
Alpine and glibc images alike:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o geth ./cmd/geth
./geth version
```

Build from a normal checkout, **not** a `git worktree`: on Go 1.21 a worktree
build silently omits the VCS stamp, leaving `Git Commit` empty and the artifact
impossible to trace back to source.

More detail, including the verification suite, in
[building from source](https://gieworld.github.io/purechain-docs/04-client/building-from-source/).

## Executables

Inherited from go-ethereum and shipped unchanged:

| Command | Description |
|---|---|
| **`geth`** | The main client, and the one you want. Entry point into the network, runnable as a full or archive node, exposing JSON-RPC over HTTP, WebSocket and IPC. `geth --help` for options. |
| `clef` | Stand-alone signing tool, usable as a backend signer for `geth`. |
| `abigen` | Generates type-safe Go bindings from contract ABIs or Solidity sources. |
| `evm` | Developer EVM for running bytecode snippets in a configurable environment. |
| `rlpdump` | Converts binary RLP dumps into a readable form. |
| `devp2p` | Utilities for interacting with nodes at the networking layer. |
| `bootnode` | Discovery-only node, useful as a lightweight bootstrap peer. |

## Contributing

Contributions to the fork-specific changes are welcome. Fork, fix, commit and
open a pull request — keeping changes gated on `Clique != nil` / `zeroBaseFee`
so stock behaviour stays intact, and adding or updating a
[`smoke-test/`](smoke-test/) case when you change consensus or free-gas
behaviour.

Code should follow the standard Go [formatting](https://golang.org/doc/effective_go.html#formatting)
and [commentary](https://golang.org/doc/effective_go.html#commentary) guidelines,
with commit messages prefixed by the package they modify — e.g.
`eth, rpc: make trace configs optional`.

For changes to the underlying client that are **not** Clique, Cancun or
free-gas specific, consider contributing them upstream to
[go-ethereum](https://github.com/ethereum/go-ethereum) instead.

Report security issues privately — see [`SECURITY.md`](SECURITY.md).

## Attribution and licence

This is a **fork of [ethereum/go-ethereum](https://github.com/ethereum/go-ethereum)**,
pinned to the `v1.13.15` release — the last version that shipped Clique. It is
**not affiliated with or endorsed by** the go-ethereum project.

The go-ethereum library (i.e. all code outside of the `cmd` directory) is
licensed under the
[GNU Lesser General Public License v3.0](https://www.gnu.org/licenses/lgpl-3.0.en.html),
also included in this repository in the [`COPYING.LESSER`](COPYING.LESSER) file.

The go-ethereum binaries (i.e. all code inside of the `cmd` directory) are
licensed under the
[GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.en.html),
also included in this repository in the [`COPYING`](COPYING) file.

See [`AUTHORS`](AUTHORS) for the upstream authors this work builds on.

**PureChain-original works** — the Smart Auto-Mining (SAM) and PoA² controllers
in [`rehearsal/scripts/`](rehearsal/scripts/) — are **Apache-2.0**, copyright
PureChain, per [`LICENSE-purechain`](LICENSE-purechain). They are JavaScript run
*by* geth's console rather than code linked into it, so they are separate works
and not derivatives of go-ethereum.
