/**
 * Verified Mezo contract addresses.
 * Sources:
 *  - mezo.org/docs (networks + MUSD core contracts)
 *  - mezo.org/docs/developers/features/mezo-pools (pool/router addresses)
 *  - github.com/mezo-org/musd (ABIs)
 */
export const CHAIN_IDS = {
  mezoTestnet: 31611,
  mezoMainnet: 31612,
} as const;

export const MEZO_TESTNET = {
  chainId: CHAIN_IDS.mezoTestnet,
  rpc: "https://rpc.test.mezo.org",
  wss: "wss://rpc-ws.test.mezo.org",
  explorer: "https://explorer.test.mezo.org",
  faucet: "https://faucet.test.mezo.org",

  // MUSD core protocol (testnet)
  MUSD: "0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503",
  BORROWER_OPERATIONS: "0xCdF7028ceAB81fA0C6971208e83fa7872994beE5",
  TROVE_MANAGER: "0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0",
  SORTED_TROVES: "0x722E4D24FD6Ff8b0AC679450F3D91294607268fA",
  HINT_HELPERS: "0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6",
  PRICE_FEED: "0x86bCF0841622a5dAC14A313a15f96A95421b9366",

  // Mezo Pools (testnet) — Aerodrome-style basic pools
  POOLS_ROUTER: "0x9a1ff7FE3a0F69959A3fBa1F1e5ee18e1A9CD7E9",
  POOLS_FACTORY: "0x4947243CC818b627A5D06d14C4eCe7398A23Ce1A",
  POOL_MUSD_BTC: "0xd16A5Df82120ED8D626a1a15232bFcE2366d6AA9",
  POOL_MUSD_MUSDC: "0x525F049A4494dA0a6c87E3C4df55f9929765Dc3e",
  POOL_MUSD_MUSDT: "0x27414B76CF00E24ed087adb56E26bAeEEe93494e",
  CL_SWAP_ROUTER: "0x3112908bB72ce9c26a321Eeb22EC8e051F3b6E6a",
} as const;

export const MEZO_MAINNET = {
  chainId: CHAIN_IDS.mezoMainnet,
  explorer: "https://explorer.mezo.org",
  MUSD: "0xdD468A1DDc392dcdbEf6db6e34E89AA338F9F186",
  POOLS_ROUTER: "0x16A76d3cd3C1e3CE843C6680d6B37E9116b5C706",
  POOL_MUSD_BTC: "0x52e604c44417233b6CcEDDDc0d640A405Caacefb",
} as const;

export function addressesFor(chainId: number) {
  if (chainId === CHAIN_IDS.mezoTestnet) return MEZO_TESTNET;
  throw new Error(`no address book for chain ${chainId}`);
}
