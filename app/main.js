// MezoLoop minimal UI — zero build step. viem via CDN.
// Serve statically (e.g. `npx serve app`) and open on Mezo testnet.
import {
  createPublicClient, createWalletClient, custom, http,
  formatEther, parseEther, defineChain,
} from "https://esm.sh/viem@2.21.44";

const mezoTestnet = defineChain({
  id: 31611,
  name: "Mezo Testnet",
  nativeCurrency: { name: "Bitcoin", symbol: "BTC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.test.mezo.org"] } },
  blockExplorers: {
    default: { name: "Mezo Explorer", url: "https://explorer.test.mezo.org" },
  },
});

const VAULT_ABI = [
  { type: "function", name: "deposit", stateMutability: "payable", inputs: [], outputs: [] },
  { type: "function", name: "exit", stateMutability: "nonpayable",
    inputs: [{ name: "shares", type: "uint256" }, { name: "minBtcOut", type: "uint256" }],
    outputs: [{ type: "uint256" }] },
  { type: "function", name: "enter", stateMutability: "nonpayable",
    inputs: [{ name: "initialDebt", type: "uint256" }, { name: "maxIters", type: "uint8" }], outputs: [] },
  { type: "function", name: "loopToTarget", stateMutability: "nonpayable",
    inputs: [{ name: "maxIters", type: "uint8" }], outputs: [] },
  { type: "function", name: "closeAll", stateMutability: "nonpayable",
    inputs: [{ name: "maxIters", type: "uint8" }], outputs: [] },
  { type: "function", name: "sweepIdle", stateMutability: "nonpayable",
    inputs: [{ name: "maxIters", type: "uint8" }], outputs: [] },
  { type: "function", name: "trove", stateMutability: "view", inputs: [],
    outputs: [{ name: "coll", type: "uint256" }, { name: "debt", type: "uint256" },
              { name: "icr", type: "uint256" }, { name: "status", type: "uint8" }] },
  { type: "function", name: "equityBtc", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "leverage", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "navPerShare", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "balanceOf", stateMutability: "view",
    inputs: [{ name: "a", type: "address" }], outputs: [{ type: "uint256" }] },
];

const $ = (id) => document.getElementById(id);
const logEl = $("log");
const log = (m) => { logEl.textContent += `${new Date().toLocaleTimeString()}  ${m}\n`; logEl.scrollTop = 1e9; };

const publicClient = createPublicClient({ chain: mezoTestnet, transport: http() });
let wallet, account;

$("connectBtn").onclick = async () => {
  if (!window.ethereum) return log("no wallet detected");
  wallet = createWalletClient({ chain: mezoTestnet, transport: custom(window.ethereum) });
  [account] = await wallet.requestAddresses();
  try {
    await wallet.switchChain({ id: 31611 });
  } catch {
    await wallet.addChain({ chain: mezoTestnet });
  }
  $("account").textContent = `connected: ${account}`;
  log(`connected ${account}`);
  refresh();
};

function vault() {
  const a = $("vaultAddr").value.trim();
  if (!a) throw new Error("set vault address");
  return { address: a, abi: VAULT_ABI };
}

async function refresh() {
  try {
    const v = vault();
    const [t, eq, lev, nav] = await Promise.all([
      publicClient.readContract({ ...v, functionName: "trove" }),
      publicClient.readContract({ ...v, functionName: "equityBtc" }),
      publicClient.readContract({ ...v, functionName: "leverage" }),
      publicClient.readContract({ ...v, functionName: "navPerShare" }),
    ]);
    const [coll, debt, icr, status] = t;
    $("sColl").textContent = `${Number(formatEther(coll)).toFixed(4)} BTC`;
    $("sDebt").textContent = Number(formatEther(debt)).toFixed(0);
    $("sIcr").textContent = icr > 10n ** 21n ? "∞" : `${(Number(icr) / 1e18).toFixed(2)}x`;
    $("sEq").textContent = `${Number(formatEther(eq)).toFixed(4)} BTC`;
    $("sLev").textContent = lev > 10n ** 21n ? "∞" : `${(Number(lev) / 1e18).toFixed(2)}x`;
    $("sNav").textContent = `${Number(formatEther(nav)).toFixed(4)} BTC`;
    const pct = Math.min(100, (Number(icr) / 2e18) * 100);
    $("icrBar").style.width = `${status === 1 ? pct : 0}%`;
    if (account) {
      const bal = await publicClient.readContract({ ...v, functionName: "balanceOf", args: [account] });
      $("myShares").textContent = `your mlBTC: ${formatEther(bal)}`;
    }
  } catch (e) { log(`refresh: ${e.shortMessage ?? e.message}`); }
}
$("refreshBtn").onclick = refresh;

async function send(fnName, args, value) {
  const v = vault();
  const hash = await wallet.writeContract({
    ...v, functionName: fnName, args, value, account,
  });
  log(`${fnName} tx: ${hash}`);
  await publicClient.waitForTransactionReceipt({ hash });
  log(`${fnName} confirmed`);
  refresh();
}

$("depositBtn").onclick = async () => {
  try { await send("deposit", [], parseEther($("depAmt").value)); }
  catch (e) { log(e.shortMessage ?? e.message); }
};
$("exitBtn").onclick = async () => {
  try { await send("exit", [parseEther($("exitShares").value), 0n]); }
  catch (e) { log(e.shortMessage ?? e.message); }
};
$("enterBtn").onclick = async () => {
  try { await send("enter", [0n, 8]); } catch (e) { log(e.shortMessage ?? e.message); }
};
$("loopBtn").onclick = async () => {
  try { await send("loopToTarget", [8]); } catch (e) { log(e.shortMessage ?? e.message); }
};
$("closeBtn").onclick = async () => {
  try { await send("closeAll", [12]); } catch (e) { log(e.shortMessage ?? e.message); }
};
