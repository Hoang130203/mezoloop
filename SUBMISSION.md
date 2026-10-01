# SUBMISSION — AKINDO Mezo Buildathon

**Project:** MezoLoop — one-click leveraged BTC vault on MUSD + Mezo Pools
**Track:** 1 (DeFi)
**Wave 1 window:** Oct 15/16 – Oct 26, 2026 · **Wave 2:** Nov 2–15 · **Demo day:** Nov 23

## Submission checklist

- [x] Public repo with working contracts (`contracts/`), tests (9 passing),
      deploy + demo scripts, verified Mezo testnet addresses.
- [x] MUSD integration is protocol-level: the vault opens and manages a real
      trove (BorrowerOperations/TroveManager/PriceFeed/HintHelpers) and swaps
      through the live MUSD/BTC Mezo Pool.
- [x] Runnable demo: `npm run demo` (full lifecycle locally) and
      `npm run probe` (keyless read-only verification against live testnet:
      oracle price, minNetDebt, borrow rate, trove count, pool reserves,
      router quotes, BTC precompile semantics).
- [ ] Deployed to Mezo testnet + contract verified on explorer.test.mezo.org
      (needs faucet BTC — see README).
- [ ] Demo video (script below).
- [ ] AKINDO project page: pitch, repo link, deployment address, video.

## Video demo script (~3 min)

1. **Hook (0:00–0:20)** — "Bitcoin holders want more BTC exposure without
   selling or babysitting a CDP. MezoLoop: deposit BTC, get ~3x levered
   exposure, managed by MUSD."
2. **The loop on screen (0:20–0:50)** — architecture diagram: trove →
   withdrawMUSD → Mezo Pools swap → addColl → repeat to 150% ICR.
3. **Live testnet walk-through (0:50–2:10)** — explorer tabs open:
   - `deposit(0.1 BTC)` → mlBTC minted
   - `enter(0, 8)` → show trove on explorer: collateral ↑, MUSD minted,
     ICR converging to 150%, leverage = 3x
   - `exit(25%)` → BTC back in wallet, trove ICR visibly preserved
   - `closeAll` → full unwind, collateral returned
4. **Why it matters (2:10–2:40)** — every loop mints MUSD and locks BTC;
   this is TVL + mint volume for Mezo, packaged as a product users want.
5. **Roadmap (2:40–3:00)** — Wave 2 teaser (below).

## Wave 1 → Wave 2 plan

| Wave 1 (shipped) | Wave 2 (deepen) |
|---|---|
| Pooled trove vault, owner-operated leverage | Per-user trove wrappers (isolate risk/exit without pool drag) |
| Mezo Pools basic-pool adapter | CL-pool adapter + best-execution routing (basic vs Slipstream) |
| Manual `loopToTarget`/`closeAll` | Permissionless keeper network; x402-metered keeper calls |
| 150% fixed target | User-selectable leverage tiers (2x/3x/4x vaults) |
| Plain MUSD borrow loop | Yield overlay: LP the MUSD leg, refinance() rate optimization, redemption-risk hedging |
| Tests + demo script + static UI | Full React dApp, position health alerts, analytics |

Progress-based judging rewards showing the delta: land Wave 1 exactly as
scoped, then ship the per-user trove + keeper path first in Wave 2.

## Timeline

- **Oct 13** — online kickoff workshop (confirm track guidance, MUSD
  mechanics questions: borrow capacity vs interest rate, redemption edge
  cases).
- **Oct 15/16–20** — contracts + tests + demo (this scaffold).
- **Oct 21–23** — testnet deploy, live verification, UI polish, record video.
- **Oct 24–26** — buffer: slippage tuning against real pool liquidity,
  submission write-up, submit before Oct 26 deadline.
- **Nov 2–15** — Wave 2 items above; keep commits public and incremental.
- **Nov 23** — demo day.

## Open questions to resolve on testnet / at kickoff

- ~~Router ABI shape~~ — **verified**: Aerodrome-style `Route[]{from,to,
  stable,factory}`; `defaultFactory()` and `getAmountsOut` return live
  quotes (1000 MUSD → 0.0127 BTC).
- ~~repayMUSD pull pattern~~ — **verified**: MUSD exposes `burn(address,
  uint256)` (borrowerOps burns caller balance directly).
- ~~BTC wrapper~~ — **verified**: BTC leg of the pool is the native-BTC
  ERC20 precompile `0x7b7C…`; no wBTC wrap step.
- MUSD `maxBorrowingCapacity` interaction with interest rates — does a
  trove's rate tier cap how much we can loop? Read
  `getTroveMaxBorrowingCapacity` during live deploy.
- Testnet pool prices BTC ~6% below oracle ($78.7k vs $84k) — is that
  peg-intentional drift on testnet? Affects effective entry cost slightly.
- Whether judges want Track 2 payments surface too (x402 keeper payments
  in Wave 2 could cover it).
