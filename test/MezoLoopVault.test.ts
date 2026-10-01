import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import {
  MezoLoopVault,
  MockMusd,
  MockMusdCore,
  MockPriceFeed,
  MockSwapAdapter,
} from "../typechain-types";

const E18 = ethers.parseEther("1");
const BTC_PRICE = ethers.parseEther("100000"); // $100k/BTC

describe("MezoLoopVault", function () {
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;

  let musd: MockMusd;
  let core: MockMusdCore;
  let feed: MockPriceFeed;
  let adapter: MockSwapAdapter;
  let vault: MezoLoopVault;

  async function deploy() {
    [owner, alice, bob] = await ethers.getSigners();

    musd = await (await ethers.getContractFactory("MockMusd")).deploy();
    feed = await (
      await ethers.getContractFactory("MockPriceFeed")
    ).deploy(BTC_PRICE);
    core = await (
      await ethers.getContractFactory("MockMusdCore")
    ).deploy(await musd.getAddress(), await feed.getAddress());
    adapter = await (
      await ethers.getContractFactory("MockSwapAdapter")
    ).deploy(await musd.getAddress(), await feed.getAddress());
    vault = await (
      await ethers.getContractFactory("MezoLoopVault")
    ).deploy(
      await musd.getAddress(),
      await core.getAddress(), // borrowerOperations
      await core.getAddress(), // troveManager
      await feed.getAddress(),
      await core.getAddress(), // hintHelpers
      await adapter.getAddress()
    );

    // Swap floats: adapter needs BTC (to buy MUSD with) and MUSD (to buy BTC with)
    await owner.sendTransaction({
      to: await adapter.getAddress(),
      value: ethers.parseEther("10"),
    });
    await musd.mint(await adapter.getAddress(), ethers.parseEther("1000000"));
  }

  beforeEach(deploy);

  // ---------------------------------------------------------------
  it("mints 1:1 shares on first deposit", async function () {
    await vault.connect(alice).deposit({ value: ethers.parseEther("0.1") });
    expect(await vault.balanceOf(alice.address)).to.equal(
      ethers.parseEther("0.1")
    );
    expect(await vault.equityBtc()).to.equal(ethers.parseEther("0.1"));
  });

  it("opens a trove and converges to target ICR ~150%", async function () {
    await vault.connect(alice).deposit({ value: ethers.parseEther("0.1") }); // $10k
    // borrow enough to satisfy minNetDebt=1800 and land near 150%
    await vault.enter(ethers.parseEther("5000"), 12);

    const [coll, debt, icr, status] = await vault.trove();
    expect(status).to.equal(1);
    expect(debt).to.be.gte(ethers.parseEther("1800"));
    expect(coll).to.be.gt(ethers.parseEther("0.1")); // more than deposited
    // 150% +- 3% band
    expect(icr).to.be.within(
      ethers.parseEther("1.45"),
      ethers.parseEther("1.56")
    );
    // leverage ~= r/(r-1) = 3x
    const lev = await vault.leverage();
    expect(lev).to.be.within(ethers.parseEther("2.7"), ethers.parseEther("3.3"));
  });

  it("prices deposits at NAV after looping (no free leverage)", async function () {
    await vault.connect(alice).deposit({ value: ethers.parseEther("0.1") });
    await vault.enter(ethers.parseEther("5000"), 12);

    const eqBefore = await vault.equityBtc();
    const sharesBefore = await vault.totalSupply();

    await vault.connect(bob).deposit({ value: ethers.parseEther("0.05") });
    const bobShares = await vault.balanceOf(bob.address);
    const expected = (ethers.parseEther("0.05") * sharesBefore) / eqBefore;
    expect(bobShares).to.be.closeTo(expected, expected / 100n + 1n);
  });

  it("exit repays pro-rata debt and returns net BTC, keeping ICR", async function () {
    await vault.connect(alice).deposit({ value: ethers.parseEther("0.1") });
    await vault.connect(bob).deposit({ value: ethers.parseEther("0.1") });
    await vault.enter(ethers.parseEther("5000"), 12);

    const [, , icrBefore] = await vault.trove();
    const aliceShares = await vault.balanceOf(alice.address);
    const half = aliceShares / 2n; // exit ~25% of the pool

    const balBefore = await ethers.provider.getBalance(alice.address);
    const tx = await vault.connect(alice).exit(half, 0n);
    const receipt = await tx.wait();
    const gas = receipt!.gasUsed * receipt!.gasPrice;

    const balAfter = await ethers.provider.getBalance(alice.address);
    const received = balAfter - balBefore + gas;
    expect(received).to.be.gt(0n);

    // Alice should net roughly her pro-rata equity (minus fees)
    const eq = await vault.equityBtc();
    const approxEquityShare = (eq * half) / (await vault.totalSupply());
    expect(received).to.be.closeTo(
      approxEquityShare,
      approxEquityShare / 10n // within 10% (fees + dust tolerance)
    );

    const [, , icrAfter] = await vault.trove();
    // ICR should be in the same neighborhood (repay+withdraw keeps it flat)
    expect(icrAfter).to.be.gt(ethers.parseEther("1.1")); // above MCR
    expect(icrAfter).to.be.within(
      (icrBefore * 85n) / 100n,
      (icrBefore * 130n) / 100n
    );
  });

  it("delevers toward target when price crashes", async function () {
    await vault.connect(alice).deposit({ value: ethers.parseEther("0.1") });
    await vault.enter(ethers.parseEther("5000"), 12);
    const [, debtBefore] = await vault.trove();

    // BTC -20%
    await feed.setPrice(ethers.parseEther("80000"));
    await vault.loopToTarget(12);

    const [, debtAfter, icrAfter] = await vault.trove();
    expect(debtAfter).to.be.lt(debtBefore);
    expect(icrAfter).to.be.gte(ethers.parseEther("1.35")); // moving up to 150%
  });

  it("closeAll unwinds the trove and lets users exit pro-rata", async function () {
    await vault.connect(alice).deposit({ value: ethers.parseEther("0.1") });
    await vault.enter(ethers.parseEther("5000"), 12);

    await vault.closeAll(12);
    const [, debt, , status] = await vault.trove();
    expect(status).to.not.equal(1); // closed
    expect(debt).to.equal(0n);

    const shares = await vault.balanceOf(alice.address);
    const balBefore = await ethers.provider.getBalance(alice.address);
    const tx = await vault.connect(alice).exit(shares, 0n);
    const receipt = await tx.wait();
    const gas = receipt!.gasUsed * receipt!.gasPrice;
    const received =
      (await ethers.provider.getBalance(alice.address)) - balBefore + gas;

    // Alice started with 0.1 BTC; fees mean she gets back somewhat less
    expect(received).to.be.gt(ethers.parseEther("0.09"));
    expect(received).to.be.lt(ethers.parseEther("0.101"));
  });

  it("rejects leverage when deposits can't satisfy MUSD minNetDebt", async function () {
    await vault.connect(alice).deposit({ value: ethers.parseEther("0.001") }); // $100
    await expect(
      vault.enter(ethers.parseEther("500"), 12)
    ).to.be.revertedWithCustomError(vault, "DebtTooSmall");
  });

  it("owner can retarget leverage and swap adapter", async function () {
    await vault.setTargetICR(ethers.parseEther("2"));
    expect(await vault.targetICR()).to.equal(ethers.parseEther("2"));
    await expect(vault.setTargetICR(ethers.parseEther("1.1"))).to.be
      .revertedWithCustomError(vault, "BadTarget");
  });

  it("pause blocks deposits", async function () {
    await vault.setPaused(true);
    await expect(
      vault.connect(alice).deposit({ value: 1n })
    ).to.be.revertedWithCustomError(vault, "Paused");
  });
});
