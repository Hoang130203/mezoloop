import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv";

dotenv.config();

// Never commit real keys. Copy .env.example -> .env and fill in.
const MEZO_PRIVATE_KEY = process.env.MEZO_PRIVATE_KEY ?? "";
const MEZO_RPC_URL = process.env.MEZO_RPC_URL ?? "https://rpc.test.mezo.org";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      evmVersion: "london", // per Mezo's official hardhat example
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    // NOTE: `hardhat --fork` of Mezo is NOT supported: EDR lacks Mezo's
    // native precompiles (BTC ERC20 facade 0x7b7C..., oracle feed behind
    // PriceFeed), so live contracts revert on a fork. Use probe-testnet.ts
    // for read-only live verification and deploy.ts for real deployment.
    hardhat: { chainId: 31337 },
    mezoTestnet: {
      url: MEZO_RPC_URL,
      chainId: 31611,
      accounts: MEZO_PRIVATE_KEY ? [MEZO_PRIVATE_KEY] : [],
      // Mezo native currency is BTC (18 decimals) - gas paid in BTC.
    },
  },
};

export default config;
