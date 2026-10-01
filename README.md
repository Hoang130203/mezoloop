# MezoLoop

**One-click leveraged BTC exposure — powered entirely by MUSD and Mezo Pools.**

Deposit BTC. MezoLoop opens a trove on the MUSD protocol, borrows MUSD,
swaps it back to BTC on Mezo Pools, re-deposits the collateral, and repeats
until the position sits at a target collateral ratio. Your mlBTC shares
track the vault's net equity; the trove's risk is managed for you.

> Track 1 (DeFi). Built for the AKINDO Mezo Buildathon — Wave 1.

```
user BTC ─▶ MezoLoopVault ──openTrove/addColl (native BTC)──▶ BorrowerOperations
                │                        ▲  ▲
                │  withdrawMUSD (mint)   │  │ collateral top-up
                ▼                        │  │
           MUSD ──▶ ISwapAdapter ──▶ Mezo Pools router ──▶ MUSD/BTC pool
                                                     (swap MUSD → BTC)
```

## Why this is deep MUSD integration, not a wrapper

The vault is a first-class MUSD protocol participant:

| MUSD contract | Used for |
|---|---|
| `BorrowerOperations` | `openTrove`, `addColl`, `withdrawColl`, `withdrawMUSD`, `repayMUSD`, `closeTrove`, `claimCollateral`, `minNetDebt`, `borrowingRate` |
| `TroveManager` | `getTroveColl/Debt/Status`, `getCurrentICR`, `getNominalICR` |
| `PriceFeed` | `fetchPrice()` — BTC/USD driving all leverage math |
| `HintHelpers` | `getApproxHint` — sorted-list insertion hints computed **on-chain** |
| Mezo Pools router | Aerodrome-style `swapExactTokensForTokens(Route[])` on the live `MUSD/BTC` pool |
| BTC precompile `0x7b7C…` | ERC20 facade over native BTC — the pool's `token1` |

Verified live on testnet (see `npm run probe`): BTC price $84k, minNetDebt
1800 MUSD, borrow fee 0.1%, 238 troves, MUSD/BTC pool reserves
~102.6M MUSD / ~1303 BTC.

Every loop iteration *mints fresh MUSD* and *locks more BTC* — directly
growing the two metrics Mezo cares about.

## The mechanics

- **Leverage math.** To converge on target ICR `r`, the ideal borrow solves
  `collUsd + d = r·(debt + d)` ⇒ `d = (collUsd − r·debt)/(r−1)`. Because MUSD
  enforces ICR ≥ MCR *at borrow time* (the swapped collateral hasn't landed
  yet), each step is capped by a floor headroom — the loop converges
  geometrically. Target 150% ⇒ ~3x gross exposure.
- **ICR-preserving exits.** Burning shares repays pro-rata debt and pulls
  pro-rata collateral — but collateral can't leave below MCR, so `exit`
  runs a bounded withdraw→swap→repay loop inside one transaction.
- **Risk regimes.** `unwindFloorICR` (default 115%) bounds how far the vault
  will push ICR during exits/delevering. If price crashes past it
  (ICR < floor), collateral withdrawal is protocol-blocked — the honest
  answer is external MUSD repayment or `setUnwindFloorICR` closer to MCR.
  This is documented, not hidden.
- **Hints on-chain.** `getApproxHint(nicr, trials, seed)` is called inside
  the vault; the result is passed as both prev/next id per the canonical
  Liquity insertion pattern. No off-chain hint service.
- **Native BTC everywhere.** On Mezo, BTC is a precompile at
  `0x7b7C000000000000000000000000000000000000` — an ERC20 facade whose
  `balanceOf` mirrors the native balance. Mezo Pools swaps therefore settle
  in real native BTC: `openTrove`/`addColl` are payable, no wrapping step.

## Repo layout

```
contracts/
  MezoLoopVault.sol        — share vault + trove management + loop engine
  interfaces/              — MUSD BorrowerOperations/TroveManager/PriceFeed/
                             HintHelpers (verified vs mezo-org/musd), ISwapAdapter,
                             IMezoPools router/pool
  adapters/MezoPoolsAdapter.sol — MUSD<->BTC leg via Mezo Pools basic router
                             (Aerodrome Route[]); BTC leg = native precompile
  test/                    — MockMusd, MockMusdCore (faithful MUSD rules:
                             minNetDebt, MCR, borrow fee), MockPriceFeed,
                             MockSwapAdapter (oracle-priced float)
scripts/
  constants.ts             — verified testnet/mainnet addresses by chain id
  deploy.ts                — testnet deployment
  demo.ts                  — end-to-end lifecycle scenario (local mocks)
  probe-testnet.ts         — keyless read-only checks against live testnet
test/MezoLoopVault.test.ts — 9 tests: entry, looping, exits, crash, unwind
app/                       — zero-build static UI (viem via CDN)
```

## Run it

```bash
npm install
npx hardhat compile
npx hardhat test          # 9 tests against MockMusdCore
npm run demo              # full lifecycle on local mocks
npm run probe             # read-only live verification of every integration point
```

> **Why no fork tests:** Hardhat/EDR cannot execute Mezo's native
> precompiles — the BTC ERC20 facade (`0x7b7C…`) and the oracle precompile
> behind `PriceFeed` revert inside a fork. Instead: `probe-testnet.ts`
> verifies all live reads against chain 31611 (no key needed), the local
> mocks reimplement MUSD's rules faithfully, and the real deployment path
> is `deploy.ts`.

### Live Mezo testnet

```bash
cp .env.example .env     # fill MEZO_PRIVATE_KEY (never commit)
# get testnet BTC: https://faucet.test.mezo.org
npm run deploy:testnet   # writes deployments.json
```

Then either drive `enter(0, 8)` from a script/console, or serve `app/`
(`npx serve app`) and click through the UI.

**Live-demo requirements:** enough testnet BTC for collateral such that the
first borrow clears `minNetDebt` (~1800 MUSD ⇒ ≳0.03 BTC at ~$84k oracle),
plus gas. The testnet MUSD/BTC pool is deep (~$100M MUSD side) but prices
BTC ~6% under the oracle — size loops accordingly or bump
`setMaxSlippageBps` and `minBtcOut` slippage margins.

## Deployed / wired addresses (testnet, chain 31611)

See `scripts/constants.ts` — all pulled from mezo.org/docs: MUSD
`0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503`, BorrowerOperations
`0xCdF7028ceAB81fA0C6971208e83fa7872994beE5`, TroveManager
`0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0`, HintHelpers
`0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6`, PriceFeed
`0x86bCF0841622a5dAC14A313a15f96A95421b9366`, Pools router
`0x9a1ff7FE3a0F69959A3fBa1F1e5ee18e1A9CD7E9`, MUSD/BTC pool
`0xd16A5Df82120ED8D626a1a15232bFcE2366d6AA9`.

## Wave 1 scope & honest limits

- Single pooled trove owned by the vault (shares = pro-rata equity).
- Leverage management is `onlyOwner` (keeper automation is Wave 2).
- `enter` needs deposits ≥ ~minNetDebt worth of BTC.
- Exits revert with `InsufficientExitLiquidity` when the 12-step unwind
  can't release 99.5% of pro-rata collateral (huge exits at low ICR) —
  retry smaller or after a rebalance.
- No audit. Testnet-first by design.
