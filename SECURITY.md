# Security

## Status

The Fathom contracts are live on Robinhood Chain mainnet (chain id 4663). They are immutable: there
are no proxies and no upgrade path.

What the owner key can and cannot do is listed in the README under
[Admin powers](README.md#admin-powers). In short: it can pause swaps and new liquidity, tune fee
and oracle parameters within hard-coded caps, and manage the fee-to-buyback pipeline. It cannot
move, freeze or withdraw anyone's liquidity, and removing liquidity is never paused.

## Reporting a vulnerability

Please **do not open a public issue** for anything that could put user funds at risk.

Report it privately through GitHub's
[private vulnerability reporting](https://github.com/FathomPools/fathom-contracts/security/advisories/new)
for this repository, or send a direct message to [@FathomPools](https://x.com/FathomPools) asking
for a private channel. Include:

- the affected contract(s) and function(s),
- a description of the issue and its impact,
- a proof of concept (a Foundry test against a mainnet fork is ideal).

We will acknowledge the report, keep you updated while it is investigated, and credit you when the
fix or mitigation is public, unless you prefer to stay anonymous.

## Scope

Everything under `src/` at the addresses listed in the README. Out of scope: third-party contracts
the protocol integrates with (Uniswap v4 PoolManager and PositionManager, Chainlink feeds, Pons
curves and pools, WETH, USDG), the web app and the indexer.
