import { ethers, network } from "hardhat";
import { readFileSync } from "fs";

/**
 * Live Mezo testnet run against the deployed MezoLoopVault.
 *
 *   npx hardhat run scripts/live.ts --network mezoTestnet
 *
 * deposit → openTroveStep → swapTopUpStep → (refiStep / borrowStep +
 * swapTopUpStep) chunks → print real trove state.
 *
 * Keeper pattern: SortedTroves needs (prevId, nextId) insertion hints for
 * every BorrowerOperations call. Resolving them on-chain means an O(n)
 * walk that can exceed Mezo testnet's 10M block gas limit, so this script
 * resolves hints OFF-CHAIN via view calls (free) — approxHint then
 * findInsertPosition — and submits one step per transaction.
 */
const fmt = (v: bigint) => Number(ethers.formatEther(v)).toFixed(6);
const GAS = 9_000_000n; // stay under the ~10M block limit
const NICR_PRECISION = 10n ** 20n;
const GAS_COMP = ethers.parseEther("200"); // MUSD_GAS_COMPENSATION
const TARGET_DONE = ethers.parseEther("1.55");

async function show(vault: any, label: string) {
  const [coll, debt, icr, status] = await vault.trove();
  const eq = await vault.equityBtc();
  const lev = await vault.leverage();
  const nav = await vault.navPerShare();
  console.log(`\n=== ${label} ===`);
  console.log(`  trove status : ${status === 1n ? "active" : status}`);
  console.log(`  collateral   : ${fmt(coll)} BTC`);
  console.log(`  debt         : ${fmt(debt)} MUSD`);
  console.log(
    `  ICR          : ${icr > ethers.parseEther("1000") ? "∞" : (Number(icr) / 1e18).toFixed(2) + "x"}`,
  );
  console.log(`  equity       : ${fmt(eq)} BTC`);
  console.log(
    `  leverage     : ${lev > ethers.parseEther("1000") ? "∞" : (Number(lev) / 1e18).toFixed(2) + "x"}`,
  );
  console.log(`  NAV/share    : ${fmt(nav)} BTC`);
  return { coll, debt, icr, status };
}

async function main() {
  if (network.config.chainId !== 31611) {
    throw new Error("run with --network mezoTestnet");
  }
  const { vault: vaultAddr } = JSON.parse(readFileSync("deployments.json", "utf8"));
  const [deployer] = await ethers.getSigners();
  const vault = await ethers.getContractAt("MezoLoopVault", vaultAddr, deployer);
  const hh = await ethers.getContractAt("IHintHelpers", await vault.hintHelpers());
  const st = await ethers.getContractAt("ISortedTroves", "0x722E4D24FD6Ff8b0AC679450F3D91294607268fA");
  const bo = await ethers.getContractAt("IBorrowerOperations", await vault.borrowerOperations());
  const adapter = await ethers.getContractAt("ISwapAdapter", await vault.swapAdapter());

  const nicr = (coll: bigint, debt: bigint) =>
    debt === 0n ? ethers.MaxUint256 : (coll * NICR_PRECISION) / debt;

  /** Resolve exact (prevId, nextId) off-chain — approxHint then the free walk. */
  async function hintsFor(nicrVal: bigint): Promise<[string, string]> {
    const size = await st.getSize();
    const trials = size === 0n ? 10n : 20n * BigInt(Math.ceil(Math.sqrt(Number(size))));
    const seed = BigInt(deployer.address) ^ BigInt(Date.now());
    const [hint] = await hh.getApproxHint(nicrVal, trials, seed);
    const [prev, next] = await st.findInsertPosition(nicrVal, hint, hint);
    return [prev, next];
  }

  const bal0 = await ethers.provider.getBalance(deployer.address);
  console.log(`Deployer balance: ${fmt(bal0)} BTC`);

  let [, , , status] = await vault.trove();
  const depositAmt = ethers.parseEther("0.042");
  const feeRate = await bo.borrowingRate();

  if (status !== 1n) {
    console.log(`\n> deposit(${fmt(depositAmt)} BTC)`);
    await (await vault.deposit({ value: depositAmt })).wait();

    const free = await ethers.provider.getBalance(vaultAddr);
    const price = await (await ethers.getContractAt("IPriceFeed", await vault.priceFeed())).fetchPrice();
    const initialDebt = (free * price) / ethers.parseEther("1.3");
    const composite = (initialDebt * (10n ** 18n + feeRate)) / 10n ** 18n + GAS_COMP;
    const [up, lo] = await hintsFor(nicr(free, composite));

    console.log(`> openTroveStep(0) — debt ~${fmt(initialDebt)} MUSD`);
    const tx = await vault.openTroveStep(0n, up, lo, { gasLimit: GAS });
    console.log(`  tx: ${tx.hash}`);
    await tx.wait();

    // Recycle the freshly minted MUSD into collateral.
    const musd = await ethers.getContractAt("IERC20", await vault.musd());
    const [coll1, debt1] = await vault.trove();
    const musdBal = await musd.balanceOf(vaultAddr);
    const quote = await adapter.quoteMusdToBtc(musdBal);
    const [up2, lo2] = await hintsFor(nicr(coll1 + quote, debt1));
    console.log(`> swapTopUpStep(${fmt(musdBal)} MUSD -> BTC -> addColl)`);
    const tx2 = await vault.swapTopUpStep(musdBal, up2, lo2, { gasLimit: GAS });
    console.log(`  tx: ${tx2.hash}`);
    await tx2.wait();
  } else {
    console.log(`trove already active — resuming leverage loop`);
  }

  // Chunked leverage: plan -> refi if cap-bound -> borrow -> top-up.
  let refis = 0;
  for (let step = 0; step < 10; step++) {
    const { coll, debt, icr } = await show(vault, `state before step ${step}`);
    if (icr <= TARGET_DONE) break;
    const [d, maxNow, done] = await vault.planLeverageStep();
    if (done || d === 0n) { console.log("  converged / below dust"); break; }

    if (d > maxNow) {
      if (refis >= 6) {
        const dFloor = maxNow;
        if (dFloor < ethers.parseEther("1")) { console.log("  cap headroom exhausted"); break; }
      } else {
        refis++;
        const [up, lo] = await hintsFor(nicr(coll, debt));
        console.log(`> refiStep() — refresh borrowing capacity`);
        const tx = await vault.refiStep(up, lo, { gasLimit: GAS });
        console.log(`  tx: ${tx.hash}`);
        await tx.wait();
        continue;
      }
    }

    const borrow = d > maxNow ? maxNow : d;
    const postDebt = debt + (borrow * (10n ** 18n + feeRate)) / 10n ** 18n;
    const [up, lo] = await hintsFor(nicr(coll, postDebt));
    console.log(`> borrowStep(${fmt(borrow)} MUSD)`);
    const tx = await vault.borrowStep(borrow, up, lo, { gasLimit: GAS });
    console.log(`  tx: ${tx.hash}`);
    await tx.wait();

    const [coll2, debt2] = await vault.trove();
    const quote2 = await adapter.quoteMusdToBtc(borrow);
    const [up2, lo2] = await hintsFor(nicr(coll2 + quote2, debt2));
    console.log(`> swapTopUpStep(${fmt(borrow)} MUSD -> BTC -> addColl)`);
    const tx2 = await vault.swapTopUpStep(borrow, up2, lo2, { gasLimit: GAS });
    console.log(`  tx: ${tx2.hash}`);
    await tx2.wait();
  }

  await show(vault, "final — live on Mezo testnet");
  console.log(`\nExplorer: https://explorer.test.mezo.org/address/${vaultAddr}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
