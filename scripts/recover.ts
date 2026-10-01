import { ethers, network } from "hardhat";

/**
 * Recovers BTC from the OLD MezoLoopVault deployment (pre-capacity-fix).
 * The vault never opened a trove, so exit() pays out plain pro-rata BTC.
 *
 *   npx hardhat run scripts/recover.ts --network mezoTestnet
 */
const OLD_VAULT = "0x2E5A78060Db7Ad89A80fc3e2E5A62Ccde7347a4e";

async function main() {
  if (network.config.chainId !== 31611) {
    throw new Error("run with --network mezoTestnet");
  }
  const [deployer] = await ethers.getSigners();
  const vault = await ethers.getContractAt("MezoLoopVault", OLD_VAULT, deployer);

  const shares = await vault.balanceOf(deployer.address);
  const bal0 = await ethers.provider.getBalance(deployer.address);
  console.log(`deployer shares: ${ethers.formatEther(shares)}`);
  console.log(`deployer BTC   : ${ethers.formatEther(bal0)}`);

  if (shares === 0n) {
    console.log("nothing to recover");
    return;
  }
  const tx = await vault.exit(shares, 0n);
  const rc = await tx.wait();
  console.log(`exit tx: ${rc.hash}`);

  const bal1 = await ethers.provider.getBalance(deployer.address);
  console.log(`deployer BTC now: ${ethers.formatEther(bal1)}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
