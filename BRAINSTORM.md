# BRAINSTORM — Mezo Buildathon Wave 1

Evaluation criteria (weighted for Mezo core-team judges):
1. **MUSD/MEZO integration depth** — protocol-level (calling into MUSD core
   contracts, driving mint volume/TVL) >> superficial (MUSD as an ERC20
   payment rail).
2. **Feasibility in ~10 days** (Wave 1: Oct 15/16–26).
3. **Demo-ability** — must visibly work, ideally on Mezo testnet.
4. **Wave-2 extensibility** — credible roadmap for Nov 2–15.
5. **Judge appeal** — working product, senior Solidity, long-term signal.

## Candidates

### (a) Leveraged-loop vault on MUSD troves — "MezoLoop"  ✅ WINNER
Deposit BTC → vault opens a trove → borrows MUSD → swaps MUSD→BTC on Mezo
Pools → redeposits as collateral → repeats to a target ICR.

- **Integration depth: ★★★★★.** Touches BorrowerOperations, TroveManager,
  PriceFeed, HintHelpers, SortedTroves AND Mezo Pools (router + MUSD/BTC
  pool). Directly mints MUSD and locks BTC TVL — the two metrics the Mezo
  team wants. Everything verified on testnet: pool `0xd16A…6AA9`, router
  `0x9a1f…D7E9` exist and the swap signature is documented.
- **Feasibility: ★★★★.** The hard part (iterative convergence math,
  MCR-bounded exits) is done in Wave 1 scaffolding. Risks: testnet pool
  liquidity depth, hint gas on deep trove lists.
- **Demo: ★★★★★.** "Deposit 0.1 BTC → 3x exposure" prints beautifully;
  equity/ICR/leverage are live-readable; a keyless probe script verifies
  every integration point against the live testnet.
- **Wave 2: ★★★★★.** Per-user trove wrappers, yield overlay (stake borrowed
  proceeds / LP the MUSD leg), keeper marketplace with x402-paid triggers,
  refinance() rate management, MEZO-incentivized gauge LP loops.
- **Judges: ★★★★★.** This is the canonical DeFi primitive every CDP chain
  needs; it proves MUSD is programmable money, not just a borrow UI.

### (b) MUSD subscription/recurring payments + merchant SDK
- Depth: ★★ (MUSD as ERC20; pull-payments via allowance/pre-approvals).
- Feasibility: ★★★★★, demo ★★★★ (dashboard is easy to show), Wave 2 ★★★
  (x402 tie-in is nice but incremental).
- Judges: ★★★ — crowded idea space; shallow MUSD coupling. Any chain can
  do recurring ERC20 pulls; nothing Bitcoin-native about it.

### (c) ROSCA / savings circles in MUSD
- Depth: ★★ (MUSD-denominated contributions/payouts only).
- Feasibility: ★★★★, demo ★★★, Wave 2 ★★★ (credit scoring, undercollateral-
  ized trust via Mezo Passport could be interesting).
- Judges: ★★★ — novel-ish socially, but MUSD is incidental; no protocol
  surface used, drives negligible mint/TVL.

### (d) MUSD payment splitter / payroll streaming
- Depth: ★★. Feasibility ★★★★★ (Sablier-lite), demo ★★★, Wave 2 ★★.
- Judges: ★★ — commodity primitive; weakest differentiation.

### (e) MUSD peg-arb helper / redemption bot UI
- Depth: ★★★★ (redeemCollateral path, redemption hints — real protocol
  surface). Feasibility ★★★ (bots need capital + edge timing; arb
  opportunities on testnet ~zero), demo ★★ (a red "no arb" banner is a
  boring demo), Wave 2 ★★.
- Judges: ★★★ — useful infra, but not a "product".

## Decision

**MezoLoop — one-click leveraged BTC vault powered by MUSD.**

> Deposit BTC. Loop it through an MUSD trove and Mezo Pools. Keep ~3x the
> Bitcoin upside while your mlBTC shares track net equity — no manual CDP
> management, no UI babysitting.

Why it wins Wave 1:
- It is the deepest possible MUSD integration short of forking the
  protocol: the vault IS a borrower, a minter, a trader and a risk-manager.
- Fully runnable demo today: local mocks enforce MUSD's real rules
  (minNetDebt, MCR, borrow fee); `npm run probe` hits the live testnet
  read-only; live deploy needs only faucet BTC.
- The math is the impressive part judges will read: closed-form target
  borrow sizing, MCR-bounded step decomposition for exits, on-chain
  HintHelpers resolution — senior-level Solidity, not tutorial code.
- Honest scoping: owner-operated leverage in Wave 1, permissionless
  keeper network + yield overlays in Wave 2 — a credible commitment arc.
