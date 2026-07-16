# Security Policy

## Scope

This repository is a **fork of [go-ethereum](https://github.com/ethereum/go-ethereum)**
pinned to `v1.13.15`, adding Clique + Shanghai/Cancun (no beacon chain) and an
optional free-gas mode. Security reports fall into two buckets:

- **Fork-specific code** — the Clique/Cancun/free-gas changes (see
  [`CHANGELOG.md`](CHANGELOG.md) for the exact surface): report **here**, privately,
  as described below.
- **Upstream go-ethereum** — anything in unmodified base code: please report to the
  Ethereum Foundation via [bounty.ethereum.org](https://bounty.ethereum.org) /
  `bounty@ethereum.org`. Those reports are out of scope for this fork, though we'll
  pick up any fix once it's released upstream.

## Supported Versions

This fork tracks a single line: **`v1.13.15` + the `clique-cancun` patch set**.
Only the latest commit on the default branch is supported. There is no separate
release cadence — fixes land on the branch and are rebuilt.

## Reporting a Vulnerability

**Please do not open a public issue for security vulnerabilities.**

Use GitHub's **private vulnerability reporting** for this repository:
*Security → Report a vulnerability* (Security Advisories). This keeps the report
private until a fix is available.

Please include: affected commit/binary, the network conditions (Clique period,
fork activation, free-gas on/off), reproduction steps, and impact (safety vs.
liveness). We aim to acknowledge within a few business days.

> Note: because this is a permissioned/free-gas fork, the usual economic
> anti-spam barrier (gas fees) does not apply. The security model relies on the
> **permissioned signer set**, a **restricted RPC surface**, and **block/gas
> limits** — reports that weaken any of those are in scope.

## Audit reports

The PDF audit reports under [`docs/audits/`](docs/audits/) are inherited from
upstream go-ethereum and cover the base client, not the fork-specific changes.
The fork's own design and safety analysis lives in
[`docs/implementation-plan.md`](docs/implementation-plan.md) and
[`docs/cancun-gas-free-report.md`](docs/cancun-gas-free-report.md).
