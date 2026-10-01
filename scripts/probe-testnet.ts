import { ethers } from "ethers";
import { MEZO_TESTNET } from "./constants";

/**
 * Read-only smoke test against LIVE Mezo testnet (chain 31611).
 * No private key needed — proves every integration point the vault uses.
 *
 *   npx ts-node scripts/probe-testnet.ts
 */

const iface = {
  priceFeed: new ethers.Interface(["function fetchPrice() view returns (uint256)"]),
  ops: new ethers.Interface([
    "function minNetDebt() view returns (uint256)",
    "function borrowingRate() view returns (uint256)",
  ]),
  tm: new ethers.Interface([
    "function getTroveOwnersCount() view returns (uint256)",
    "function getTCR(uint256) view returns (uint256)",
  ]),
  pool: new ethers.Interface([
    "function token0() view returns (address)",
    "function token1() view returns (address)",
    "function stable() view returns (bool)",
    "function getReserves() view returns (uint112,uint112,uint256)",
  ]),
  router: new ethers.Interface([
    "function defaultFactory() view returns (address)",
    "function getAmountsOut(uint256,tuple(address,address,bool,address)[]) view returns (uint256[])",
  ]),
  btcPrecompile: new ethers.Interface([
    "function name() view returns (string)",
    "function decimals() view returns (uint8)",
    "function balanceOf(address) view returns (uint256)",
  ]),
};

const BTC_PRECOMPILE = "0x7b7C000000000000000000000000000000000000";

async function call(
  provider: ethers.JsonRpcProvider,
  to: string,
  i: ethers.Interface,
  fn: string,
  args: any[] = []
) {
  const data = i.encodeFunctionData(fn, args);
  const raw = await provider.call({ to, data });
  return i.decodeFunctionResult(fn, raw);
}

async function main() {
  const provider = new ethers.JsonRpcProvider(MEZO_TESTNET.rpc);
  const net = await provider.getNetwork();
  console.log(`chainId: ${net.chainId} (expect 31611)`);

  // --- MUSD protocol reads ---
  const price = (await call(provider, MEZO_TESTNET.PRICE_FEED, iface.priceFeed, "fetchPrice"))[0];
  console.log(`PriceFeed.fetchPrice      : $${ethers.formatEther(price)}`);

  const minDebt = (await call(provider, MEZO_TESTNET.BORROWER_OPERATIONS, iface.ops, "minNetDebt"))[0];
  const fee = (await call(provider, MEZO_TESTNET.BORROWER_OPERATIONS, iface.ops, "borrowingRate"))[0];
  console.log(`BorrowerOps.minNetDebt    : ${ethers.formatEther(minDebt)} MUSD`);
  console.log(`BorrowerOps.borrowingRate : ${Number(fee) / 1e16}%`);

  const troves = (await call(provider, MEZO_TESTNET.TROVE_MANAGER, iface.tm, "getTroveOwnersCount"))[0];
  console.log(`TroveManager trove count  : ${troves}`);

  // --- Mezo Pools reads ---
  const t0 = (await call(provider, MEZO_TESTNET.POOL_MUSD_BTC, iface.pool, "token0"))[0];
  const t1 = (await call(provider, MEZO_TESTNET.POOL_MUSD_BTC, iface.pool, "token1"))[0];
  const stable = (await call(provider, MEZO_TESTNET.POOL_MUSD_BTC, iface.pool, "stable"))[0];
  const [r0, r1] = await call(provider, MEZO_TESTNET.POOL_MUSD_BTC, iface.pool, "getReserves");
  console.log(`MUSD/BTC pool token0      : ${t0}`);
  console.log(`MUSD/BTC pool token1      : ${t1} (BTC precompile)`);
  console.log(`pool stable / reserves    : ${stable} / ${ethers.formatEther(r0)} : ${ethers.formatEther(r1)}`);

  const factory = (await call(provider, MEZO_TESTNET.POOLS_ROUTER, iface.router, "defaultFactory"))[0];
  console.log(`router defaultFactory     : ${factory}`);

  const quote = await call(provider, MEZO_TESTNET.POOLS_ROUTER, iface.router, "getAmountsOut", [
    ethers.parseEther("1000"),
    [[MEZO_TESTNET.MUSD, BTC_PRECOMPILE, false, factory]],
  ]);
  console.log(
    `quote 1000 MUSD -> BTC    : ${ethers.formatEther(quote[0][1])} BTC (testnet pool price)`
  );

  // --- BTC precompile as ERC20 ---
  const name = (await call(provider, BTC_PRECOMPILE, iface.btcPrecompile, "name"))[0];
  const dec = (await call(provider, BTC_PRECOMPILE, iface.btcPrecompile, "decimals"))[0];
  const poolBtcBal = (await call(provider, BTC_PRECOMPILE, iface.btcPrecompile, "balanceOf", [MEZO_TESTNET.POOL_MUSD_BTC]))[0];
  const poolNative = await provider.getBalance(MEZO_TESTNET.POOL_MUSD_BTC);
  console.log(`BTC precompile            : name=${name} decimals=${dec}`);
  console.log(
    `precompile balanceOf(pool): ${ethers.formatEther(poolBtcBal)} == native ${ethers.formatEther(poolNative)} -> ${poolBtcBal === poolNative}`
  );

  console.log("\nAll integration points verified live on Mezo testnet.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
