#!/usr/bin/env python3
"""
GCPI source authentication (#89): who controls the attestation services already deployed on Base.

Reads, from Base mainnet, what decides whether each mechanism is a "privileged oracle committee"
(GCPI-001 §19 Q7): UMA's Optimistic Oracle V3 parameters (liveness, bond, burn, owner), and for the
zkTLS verifiers on Base, the owner and whether it is a contract or a single key, the upgrade slot, and
for Reclaim the current witness set and how many signatures a proof needs.

Usage: base_attestors.py [rpc url] [out.json]   (default rpc: https://mainnet.base.org)
Stdlib only. Function selectors are precomputed (`cast sig`): the stdlib has no keccak-256.
"""

import json
import sys
import urllib.request

RPC = "https://mainnet.base.org"
UA = {"User-Agent": "GCPI-research (https://github.com/bytesbrains/copra)", "Content-Type": "application/json"}

USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
# UMA's Base deployment: github.com/UMAprotocol/protocol, packages/core/networks/8453.json.
UMA_OOV3 = "0x2aBf1Bd76655de80eDB3086114315Eec75AF500c"
UMA_STORE = "0xa799650614f84e0B7E7E99e12d5DFc241907cd85"
UMA_GOVERNOR_SPOKE = "0xd0Ce2F132d606A19B01C03f6c327F324aDD8FCd3"
# Reclaim: github.com/reclaimprotocol/reclaim-solidity-sdk, .openzeppelin/base.json (UUPS proxies).
RECLAIM = ["0xACE04E6DeB9567C1B8F37D113F2Da9E690Fc128d", "0x15d267946ae3134429fC7b5895B91FE17935D042"]
# Primus: docs.primuslabs.xyz, attestor node guide, Base mainnet task and node contracts.
PRIMUS = ["0x151cb5eD5D10A42B607bB172B27BDF6F884b9707", "0x9C1bb8197720d08dA6B9dab5704a406a24C97642"]

SEL = {"owner()": "8da5cb5b", "defaultLiveness()": "fe4e1983", "burnedBondPercentage()": "08e7c3e6",
       "getMinimumBond(address)": "4360af3d", "computeFinalFee(address)": "5b97aadd",
       "currentEpoch()": "76671808", "fetchEpoch(uint32)": "3d3c3e07"}
# ERC-1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1.
IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    with urllib.request.urlopen(urllib.request.Request(url, data=body, headers=UA), timeout=60) as r:
        res = json.load(r)
    if "error" in res:
        raise RuntimeError(f"{method}: {res['error']}")
    return res["result"]


def words(hexdata):
    h = hexdata[2:]
    return [int(h[i:i + 64], 16) for i in range(0, len(h), 64)]


def address(word):
    return "0x" + f"{word:064x}"[-40:]


def arg(value):
    return f"{int(value, 16) if isinstance(value, str) else value:064x}"


def call(url, to, sig, *args):
    return rpc(url, "eth_call", [{"to": to, "data": "0x" + SEL[sig] + "".join(arg(a) for a in args)}, "latest"])


def is_contract(url, a):
    return rpc(url, "eth_getCode", [a, "latest"]) not in ("0x", "0x0")


def decode_epoch(hexdata):
    """fetchEpoch's return, (uint32 id, uint32 from, uint32 to, (address, string)[] witnesses, uint8 min):
    the witness addresses and the minimum number of witness signatures per claim.
    Raises ValueError if the response does not have exactly that layout: a different ABI must not
    decode into plausible-looking witnesses."""
    w = words(hexdata)

    def check(ok, what):
        if not ok:
            raise ValueError(f"fetchEpoch response is not the expected ABI layout: {what}")

    check(len(w) >= 7 and w[0] == 32, "struct offset")   # the returned struct is dynamic: word 0 is its offset
    epoch_id, start, end, arr, minimum = w[1:6]
    check(max(epoch_id, start, end) < 2 ** 32 and minimum < 2 ** 8, "uint32 / uint8 fields")
    check(arr == 160, "witness array offset")            # right after the struct's five head words
    a = 1 + arr // 32
    n = w[a]
    check(a + 1 + 3 * n <= len(w), "witness count")      # each element: offset, address, string offset
    witnesses = []
    for i in range(n):
        check(w[a + 1 + i] % 32 == 0, f"witness {i} offset")
        e = a + 1 + w[a + 1 + i] // 32
        check(e + 1 < len(w) and w[e] < 2 ** 160 and w[e + 1] == 64, f"witness {i} (address, string)")
        witnesses.append(address(w[e]))
    return {"id": epoch_id, "from": start, "to": end, "witnesses": witnesses, "minimum_signatures": minimum}


def controller(url, a):
    owner = address(words(call(url, a, "owner()"))[0])
    impl = address(int(rpc(url, "eth_getStorageAt", [a, IMPL_SLOT, "latest"]), 16))
    return {"address": a, "owner": owner, "owner_is_contract": is_contract(url, owner),
            "upgradeable_proxy": impl != address(0), "implementation": impl}


def main(argv):
    url = argv[1] if len(argv) > 1 else RPC
    out = {"block": int(rpc(url, "eth_blockNumber", []), 16)}
    uma_owner = address(words(call(url, UMA_OOV3, "owner()"))[0])
    out["uma_oov3"] = {
        "address": UMA_OOV3,
        "default_liveness_s": words(call(url, UMA_OOV3, "defaultLiveness()"))[0],
        "burned_bond_share": words(call(url, UMA_OOV3, "burnedBondPercentage()"))[0] / 1e18,
        "usdc_final_fee": words(call(url, UMA_STORE, "computeFinalFee(address)", USDC))[0] / 1e6,
        "usdc_minimum_bond": words(call(url, UMA_OOV3, "getMinimumBond(address)", USDC))[0] / 1e6,
        "owner": uma_owner, "owner_is_governor_spoke": uma_owner.lower() == UMA_GOVERNOR_SPOKE.lower(),
    }
    out["reclaim"] = []
    for a in RECLAIM:
        c = controller(url, a)
        current = words(call(url, a, "currentEpoch()"))[0]
        c["epoch"] = decode_epoch(call(url, a, "fetchEpoch(uint32)", current))
        if c["epoch"]["id"] != current:
            raise ValueError(f"{a}: fetchEpoch({current}) returned epoch {c['epoch']['id']}")
        out["reclaim"].append(c)
    out["primus"] = [controller(url, a) for a in PRIMUS]

    u = out["uma_oov3"]
    print(f"Base block {out['block']}")
    print(f"UMA OOv3: liveness {u['default_liveness_s']} s, USDC bond >= {u['usdc_minimum_bond']:.0f} "
          f"(final fee {u['usdc_final_fee']:.0f}), {u['burned_bond_share']:.0%} of a losing bond burned, "
          f"owner {'UMA GovernorSpoke' if u['owner_is_governor_spoke'] else u['owner']}")
    for name in ("reclaim", "primus"):
        for c in out[name]:
            e = c.get("epoch")
            extra = f", {len(e['witnesses'])} witness(es), {e['minimum_signatures']} signature(s) required" if e else ""
            print(f"{name} {c['address']}: owner {c['owner']} ({'contract' if c['owner_is_contract'] else 'single key'}), "
                  f"{'upgradeable' if c['upgradeable_proxy'] else 'not a proxy'}{extra}")
    if len(argv) > 2:
        with open(argv[2], "w") as f:
            json.dump(out, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
