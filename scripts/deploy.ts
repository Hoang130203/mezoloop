import { ethers, network } from "hardhat";
import { writeFileSync } from "fs";
import { MEZO_TESTNET, CHAIN_IDS } from "./constants";

/**
 * Deploys MezoPoolsAdapter + MezoLoopVault against the LIVE MUSD protocol on
 * Mezo testnet (chain 31611). Requires MEZO_PRIVATE_KEY in .env with testnet
 * BTC from https://faucet.test.mezo.org.
 *
 *   npm run deploy:testnet
 */
async function main() {
  const chainId = network.config.chainId;
  if (chainId !== CHAIN_IDS.mezoTestnet) {
    throw new Error(
      `deploy.ts targets Mezo testnet (chain 31611). Got ${chainId}. ` +
        `Run: npx hardhat run scripts/deploy.ts --network mezoTestnet`
    );
  }

  const [deployer] = await ethers.getSigners();
  const bal = await ethers.provider.getBalance(deployer.address);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Balance : ${ethers.formatEther(bal)} BTC`);

  // 1) Swap adapter over the live MUSD/BTC basic pool.
  const adapter = await (
    await ethers.getContractFactory("MezoPoolsAdapter")
  ).deploy(MEZO_TESTNET.POOLS_ROUTER, MEZO_TESTNET.POOL_MUSD_BTC, MEZO_TESTNET.MUSD);
  await adapter.waitForDeployment();
  const adapterAddr = await adapter.getAddress();
  console.log(`MezoPoolsAdapter: ${adapterAddr}`);

  // 2) Vault wired to canonical MUSD contracts.
  const vault = await (
    await ethers.getContractFactory("MezoLoopVault")
  ).deploy(
    MEZO_TESTNET.MUSD,
    MEZO_TESTNET.BORROWER_OPERATIONS,
    MEZO_TESTNET.TROVE_MANAGER,
    MEZO_TESTNET.PRICE_FEED,
    MEZO_TESTNET.HINT_HELPERS,
    adapterAddr
  );
  await vault.waitForDeployment();
  const vaultAddr = await vault.getAddress();
  console.log(`MezoLoopVault   : ${vaultAddr}`);

  const out = {
    network: "mezoTestnet",
    chainId,
    vault: vaultAddr,
    swapAdapter: adapterAddr,
    deployedAt: new Date().toISOString(),
    deployer: deployer.address,
  };
  writeFileSync("deployments.json", JSON.stringify(out, null, 2));
  console.log("Wrote deployments.json");
  console.log(
    `\nNext: deposit >= ~0.03 BTC (>= ~$2k at minNetDebt 1800), then run scripts/live.ts (keeper-step chunked loop).\n` +
      `Explorer: ${MEZO_TESTNET.explorer}/address/${vaultAddr}`
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
