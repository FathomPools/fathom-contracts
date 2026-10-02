#!/usr/bin/env python3
"""Compare the runtime bytecode built from this repository with the code deployed on Robinhood Chain.

Immutable values (constructor-set addresses and parameters) are written into the runtime code at
deploy time, so their byte ranges are masked on both sides before comparing.

    forge build
    FOUNDRY_PROFILE=deploy forge build          # vaults, zap, BuybackV2, limit orders (200 runs)
    python3 script/check_bytecode.py            # uses the public RPC
    ROBINHOOD_RPC_URL=<your rpc> python3 script/check_bytecode.py

Needs Foundry's `cast` on PATH.
"""

import json
import os
import subprocess
import sys

RPC = os.environ.get("ROBINHOOD_RPC_URL", "https://rpc.mainnet.chain.robinhood.com")

DEPLOYED = {
    "ProtocolConfig": "0xf5c7A7F883d64fa0041FBEB4459E756670bf50a7",
    "AssetRegistry": "0xA2cCfA083823A24D10987dD985f72978da614ea9",
    "DammHook": "0x13dEa09a13fDF2C32E6CFe0b5A50C4C47AA1a8cC",
    "StockHook": "0xa8122E55fbcb3F81cdC5418aeBd77351C0e568cC",
    "DlmmFactory": "0x4B104E75B478B28492873e5Fb2BB0190166d296F",
    "DlmmPair": "0xFded0De76C38B1d94dc1910A4BD4e221c98e4923",  # WETH/USDG, bin step 10
    "DlmmPositionNFT": "0x916617697B1D782Ac59EE76378E86f7c2Ed3970D",
    "Router": "0x2303cC5a9CCdDBA50daf04aeece372Fd99813F8B",
    "FeeCollector": "0x51F34Ca37DD144a7709ee81c21AC7e850BC3A453",
    "Buyback": "0x8b3d718843fd9167a52BDed64554131e39b4042F",
}

# Built with FOUNDRY_PROFILE=deploy (optimizer_runs = 200) into out-deploy/.
DEPLOYED_200_RUNS = {
    "DlmmVaultFactory": "0x6FeBd590AB58EcfcB227047bACa183Fd948eAb18",
    "DlmmVault": "0x9DACCa4aAE3BC2f785e5D3F6302855c6042F7B66",  # WETH/USDG, 41 bins, Spot
    "DlmmVaultZap": "0x50855565aB1a3f860FCdBAaF87552357fF2d6f8A",
    "BuybackV2": "0xCe83cbF571efdFFbF0e67Cb9dA529679E05986Fa",
    "DlmmLimitOrders": "0xDA1eB9B0810bbE361Fd692513D12B644d55B7C28",
}


def masked(code: bytearray, refs: dict) -> bytearray:
    code = bytearray(code)
    for ranges in refs.values():
        for r in ranges:
            code[r["start"] : r["start"] + r["length"]] = b"\0" * r["length"]
    return code


def main() -> int:
    ok = True
    contracts = [("out", n, a) for n, a in DEPLOYED.items()] + [("out-deploy", n, a) for n, a in DEPLOYED_200_RUNS.items()]
    for out, name, address in contracts:
        with open(f"{out}/{name}.sol/{name}.json") as f:
            artifact = json.load(f)["deployedBytecode"]
        local = bytearray.fromhex(artifact["object"][2:])
        chain_hex = subprocess.check_output(["cast", "code", address, "--rpc-url", RPC]).decode().strip()
        chain = bytearray.fromhex(chain_hex[2:])
        refs = artifact.get("immutableReferences", {})
        match = len(local) == len(chain) and masked(local, refs) == masked(chain, refs)
        ok &= match
        print(f"{'MATCH   ' if match else 'MISMATCH'} {name:<16} {address}  ({len(chain)} bytes)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
