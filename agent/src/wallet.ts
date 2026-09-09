import { createPublicClient, createWalletClient, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arcTestnet } from "./chains.js";

const RPC_URL = process.env.ARC_TESTNET_RPC_URL || "https://rpc.testnet.arc.io";
const PRIVATE_KEY = process.env.PRIVATE_KEY || "";

export function getAccount() {
  if (!PRIVATE_KEY) throw new Error("PRIVATE_KEY not set in .env");
  return privateKeyToAccount(PRIVATE_KEY as `0x${string}`);
}

export function getPublicClient() {
  return createPublicClient({
    chain: arcTestnet,
    transport: http(RPC_URL),
  });
}

export function getWalletClient() {
  const account = getAccount();
  return createWalletClient({
    account,
    chain: arcTestnet,
    transport: http(RPC_URL),
  });
}

export async function getBalance(): Promise<bigint> {
  const client = getPublicClient();
  const account = getAccount();
  return client.getBalance({ address: account.address });
}

export async function sendTransaction(tx: {
  to: `0x${string}`;
  data: `0x${string}`;
  value?: bigint;
}): Promise<`0x${string}`> {
  const wallet = getWalletClient();
  const hash = await wallet.sendTransaction(tx);
  return hash;
}

export async function waitForReceipt(hash: `0x${string}`) {
  const client = getPublicClient();
  return client.waitForTransactionReceipt({ hash });
}
