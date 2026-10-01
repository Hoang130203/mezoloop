# MezoLoop — Pitch Deck (speaker notes / slide copy)

Paste each `## Slide` into one slide. ~8 slides, target 3–4 min talk track.

## Slide 1 — Title
**MezoLoop** — one-click leveraged BTC exposure, powered by MUSD.
AKINDO Mezo Buildathon · Wave 1 · Track 1 (DeFi).

## Slide 2 — The problem
Bitcoin holders on Mezo who want leveraged exposure today must hand-run a
CDP loop: open a trove, borrow MUSD, swap to BTC on a DEX, re-deposit,
repeat — tracking ICR and liquidation risk manually on every step.
Most users won't do it. Most who try misjudge slippage or MCR.

## Slide 3 — The product
Deposit BTC → MezoLoop does the rest in one transaction flow:
- opens/manages a real MUSD **trove** (BorrowerOperations/TroveManager),
- borrows MUSD sized by closed-form math to a target ICR (~150% ≈ 3x),
- swaps MUSD→BTC on **Mezo Pools** (Aerodrome-style router),
- re-deposits BTC as collateral — repeat until converged.

`mlBTC` shares track net equity. Exits unwind pro-rata debt and return BTC.

## Slide 4 — Why it's the deepest possible MUSD integration
The vault is simultaneously: a **borrower** (drives MUSD mint volume), a
**collateral locker** (BTC TVL), a **trader** (Mezo Pools flow), and a
**risk manager** (ICR targeting, MCR floors, deleveraging on price drops).
Every loop = mint volume + TVL + DEX volume — the exact metrics Mezo wants.

## Slide 5 — Engineering
- `MezoLoopVault.sol` (588 lines): trove management, iterative convergence,
  MCR-bounded step decomposition for exits, on-chain HintHelpers usage.
- `MezoPoolsAdapter.sol`: real Aerodrome `Route[]{from,to,stable,factory}`
  swap leg — verified against live router on chain 31611.
- All addresses canonical & verified: MUSD `0x1189…Ac503`,
  BorrowerOperations `0xCdF7…beE5`, pool `0xd16A…6AA9`.
- Solidity 0.8.28 / london, OpenZeppelin Ownable + ReentrancyGuard.

## Slide 6 — QA & demo
- 9 hardhat tests: share minting, loop→ICR 150%/3x, NAV-priced late
  deposits, ICR-preserving exit, −20% crash delever, full unwind,
  minNetDebt guard, pause.
- `npm run probe` — keyless read-only checks against live testnet
  (oracle price, minNetDebt, borrow rate, trove count, pool reserves,
  live `getAmountsOut` quotes).
- Deployed on Mezo testnet — explorer links in README.

## Slide 7 — Roadmap (Wave 2, Nov 2–15)
Per-user trove wrappers (risk isolation) · concentrated-liquidity pool
adapter + best-execution routing · permissionless keeper network with
x402-metered keeper calls · user-selectable leverage tiers (2x/3x/4x) ·
yield overlay on the MUSD leg (LP / `refinance()` rate optimization).

## Slide 8 — Try it
```bash
npm install && npx hardhat test && npm run probe
```
Repo: github.com/<org>/mezoloop · MIT.
