import { ethers, network } from "hardhat";

/**
 * MezoLoop end-to-end demo on the in-process Hardhat chain.
 *
 *   npx hardhat run scripts/demo.ts
 *
 * MockMusdCore re-implements the MUSD rules that matter (minNetDebt, MCR,
 * borrow fee, ICR gates) so the vault runs the identical call path it uses
 * against the live protocol. For live testnet reads see
 * `scripts/probe-testnet.ts`; for deployment see `scripts/deploy.ts`.
 *
 * NOTE: `FORK_MEZO=1` hardhat forking cannot execute Mezo's native
 * precompiles (the BTC ERC20 facade at 0x7b7C... and the oracle precompile
 * behind PriceFeed) — EDR only ships standard Ethereum precompiles. The
 * real-chain path is exercised via probe-testnet.ts + deploy.ts.
 */
const fmt = (v: bigint) => Number(ethers.formatEther(v)).toFixed(6);
const fmtUsd = (v: bigint) => `$${Number(ethers.formatEther(v)).toFixed(2)}`;

async function show(vault: any, label: string) {
  const [coll, debt, icr, status] = await vault.trove();
  const eq = await vault.equityBtc();
  const lev = await vault.leverage();
  const nav = await vault.navPerShare();
  console.log(`\n=== ${label} ===`);
  console.log(`  trove status : ${status === 1n ? "active" : status}`);
  console.log(`  collateral   : ${fmt(coll)} BTC`);
  console.log(`  debt         : ${fmtUsd(debt)}`);
  console.log(
    `  ICR          : ${icr > ethers.parseEther("1000") ? "∞" : (Number(icr) / 1e18).toFixed(2) + "x"}`
  );
  console.log(`  equity       : ${fmt(eq)} BTC`);
  console.log(
    `  leverage     : ${lev > ethers.parseEther("1000") ? "∞" : (Number(lev) / 1e18).toFixed(2) + "x"}`
  );
  console.log(`  NAV/share    : ${fmt(nav)} BTC`);
}

async function main() {
  const [alice, bob] = await ethers.getSigners();
  console.log(`Local demo on Hardhat (chain ${network.config.chainId})`);

  // --- Deploy mock MUSD world ----------------------------------------
  const musd = await (await ethers.getContractFactory("MockMusd")).deploy();
  const feed = await (
    await ethers.getContractFactory("MockPriceFeed")
  ).deploy(ethers.parseEther("100000"));
  const core = await (
    await ethers.getContractFactory("MockMusdCore")
  ).deploy(await musd.getAddress(), await feed.getAddress());
  const adapter = await (
    await ethers.getContractFactory("MockSwapAdapter")
  ).deploy(await musd.getAddress(), await feed.getAddress());
  await alice.sendTransaction({
    to: await adapter.getAddress(),
    value: ethers.parseEther("10"),
  });
  await musd.mint(await adapter.getAddress(), ethers.parseEther("1000000"));

  const vault = await (
    await ethers.getContractFactory("MezoLoopVault")
  ).deploy(
    await musd.getAddress(),
    await core.getAddress(), // borrowerOperations
    await core.getAddress(), // troveManager
    await feed.getAddress(),
    await core.getAddress(), // hintHelpers
    await adapter.getAddress()
  );
  await vault.waitForDeployment();
  console.log(`MezoLoopVault: ${await vault.getAddress()}`);

  // --- Act 1: two users deposit ---------------------------------------
  await vault.connect(alice).deposit({ value: ethers.parseEther("0.1") });
  await vault.connect(bob).deposit({ value: ethers.parseEther("0.05") });
  console.log("\nAlice +0.1 BTC, Bob +0.05 BTC");
  await show(vault, "after deposits (unlevered, BTC idle)");

  // --- Act 2: open trove + loop to ~3x ---------------------------------
  await vault.enter(0n, 10); // 0 = auto-size first borrow at 130% ICR
  await show(vault, "after enter(): looped to ~150% ICR = ~3x leverage");

  // --- Act 3: bob exits half his position ------------------------------
  const bobShares = await vault.balanceOf(bob.address);
  const bobBal0 = await ethers.provider.getBalance(bob.address);
  await vault.connect(bob).exit(bobShares / 2n, 0n);
  const bobBal1 = await ethers.provider.getBalance(bob.address);
  console.log(`\nBob exited 50%: received ${fmt(bobBal1 - bobBal0)} BTC (net of fees)`);
  await show(vault, "after bob exit (ICR preserved)");

  // --- Act 4: BTC -20%, vault auto-delevers ----------------------------
  // (ICR 1.50 -> ~1.20, still above the 1.15 unwind floor so collateral
  // can be withdrawn to delever; deeper crashes need external MUSD or
  // a lowered unwindFloorICR — see README "risk regimes".)
  await feed.setPrice(ethers.parseEther("80000"));
  await vault.loopToTarget(12);
  await show(vault, "BTC -20%: loopToTarget delevered back toward 150%");

  // --- Act 5: full unwind ----------------------------------------------
  await vault.closeAll(12);
  await show(vault, "after closeAll(): trove closed, plain BTC in vault");

  const aliceShares = await vault.balanceOf(alice.address);
  const a0 = await ethers.provider.getBalance(alice.address);
  await vault.connect(alice).exit(aliceShares, 0n);
  const a1 = await ethers.provider.getBalance(alice.address);
  console.log(`\nAlice exited fully: received ${fmt(a1 - a0)} BTC`);
  console.log("\nDemo complete.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
