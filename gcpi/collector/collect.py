#!/usr/bin/env python3
"""
GCPI collectors (#92): a collector (GCPI-001 §5.2). It retrieves a market's value for a period, writes the
source record where anyone can fetch it, asks notaries to attest, and submits the observation with k
signatures and the submit bond. Anyone may run one: nothing it does needs permission, and it cannot make
a value count without k notaries reproducing it. It never invents a value: a source, notary or chain
failure exits non-zero and nothing is sent.

Usage:
  collect.py observe --period 2026-09 [--source cdb-market-price --market IN] [--out DIR]
  collect.py submit  --period 2026-09 --notary URL [URL ...] --rpc-url URL --verifier 0x.. --chain-id N
                     [--out DIR] [--dry-run]                      signer from COLLECTOR_KEY or COLLECTOR_KEYSTORE
  collect.py refund  --commitment HEX --rpc-url URL --verifier 0x.. --chain-id N
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import chain as chainlib  # noqa: E402
import sources  # noqa: E402
from fetch import SourceError, Transport  # noqa: E402

engine = sources.engine

CLOCK_WAIT = 60  # seconds to wait for the chain's clock to pass `published`


class CollectError(Exception):
    pass


def propose(adapter, transport, period, now):
    """The observation, stamped with this retrieval's time as its publication time (§5.2: the first attested
    retrieval, never an HTTP header), and its source record."""
    if not sources.ended(period, now):
        raise CollectError(f"{period} has not ended: its monthly value is not final")
    obs, record = adapter.observe(transport, period)
    return {**obs, "published": str(int(now))}, record


def keep(out, obs, record):
    """§5.2 step 8: the supporting record, retrievable by the commitment it backs."""
    if not out:
        return None
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, engine.commitment(obs) + ".json")
    with open(path, "w") as f:
        f.write(engine.canonical({"observation": obs, "record": record}) + "\n")
    return path


def ask(url, obs, timeout=180):
    req = urllib.request.Request(url.rstrip("/") + "/attest", json.dumps(obs).encode(),
                                 {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        with e:
            try:
                body = json.loads(e.read())
            except ValueError:
                body = {}
        raise CollectError(f"{url}: {body.get('refused', e.code)} {body.get('detail', '')}".rstrip())
    except (OSError, ValueError) as e:
        raise CollectError(f"{url}: {e}")


def gather(obs, notaries, chain, k, asker=ask, log=lambda m: None):
    """k signatures, in the ascending signer order submit() requires, each checked to recover its signer
    and to count on-chain now. A notary that refuses or answers wrongly is skipped, not trusted."""
    c = engine.commitment(obs)
    good = {}
    for url in notaries:
        try:
            r = asker(url, obs)
        except CollectError as e:
            log(f"refused: {e}")
            continue
        signer = r.get("signer", "")
        if r.get("commitment") != c or not chain.verify(c, signer, r.get("signature", "")):
            log(f"{url}: signature does not recover {signer} for {c}")
        elif not chain.counts(signer):
            log(f"{url}: {signer} does not count (unlisted, unbonded, unbonding or slashed)")
        else:
            good[int(signer, 16)] = r["signature"]
    if len(good) < k:
        raise CollectError(f"{len(good)} usable attestations, {k} needed")
    return [good[a] for a in sorted(good)[:k]]


def wait_for_clock(chain, at, wait=CLOCK_WAIT, sleep=time.sleep):
    for _ in range(wait):
        if chain.timestamp() >= at:
            return
        sleep(1)
    raise CollectError(f"the chain's clock has not reached {at}")


def submit(adapter, period, notaries, chain, signer, transport=None, out=None, dry_run=False, now=None,
           asker=ask, log=lambda m: None):
    transport = transport or Transport(adapter.hosts)
    obs, record = propose(adapter, transport, period, int(now if now is not None else time.time()))
    c = engine.commitment(obs)
    path = keep(out, obs, record)
    if path:
        log(f"record: {path}")
    if chain.submitted(c):
        return {"commitment": c, "status": "already_submitted"}
    wait_for_clock(chain, max(int(obs["published"]), engine.period_start(engine.ym_index(period))))
    sigs = gather(obs, notaries, chain, chain.threshold(), asker, log)
    bond = chain.submit_bond()
    chain.submit(obs, sigs, bond, signer, dry_run=True)
    if dry_run:
        return {"commitment": c, "status": "dry_run", "observation": obs}
    tx = json.loads(chain.submit(obs, sigs, bond, signer))
    if tx.get("status") not in ("0x1", 1, "1"):
        raise CollectError(f"submit reverted: {tx.get('transactionHash')}")
    return {"commitment": c, "status": "submitted", "tx": tx.get("transactionHash")}


def main(argv):
    p = argparse.ArgumentParser(description="GCPI collector (#92)")
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("observe", "submit", "refund"):
        s = sub.add_parser(name)
        if name != "refund":
            s.add_argument("--period", required=True)
            s.add_argument("--source", default="cdb-market-price")
            s.add_argument("--market", default="IN")
            s.add_argument("--out")
        if name != "observe":
            s.add_argument("--rpc-url", required=True)
            s.add_argument("--verifier", required=True)
            s.add_argument("--chain-id", required=True, type=int)
        if name == "submit":
            s.add_argument("--notary", nargs="+", required=True)
            s.add_argument("--dry-run", action="store_true")
        if name == "refund":
            s.add_argument("--commitment", required=True)
    a = p.parse_args(argv)
    log = lambda m: print(f"collector: {m}", file=sys.stderr)
    try:
        if a.cmd != "refund":
            adapter = sources.adapters([f"{a.source}:{a.market}"])[(a.source, a.market)]
            if not engine.PERIOD.match(a.period):
                raise CollectError(f"{a.period!r} is not YYYY-MM")
        if a.cmd == "observe":
            obs, record = propose(adapter, Transport(adapter.hosts), a.period, int(time.time()))
            keep(a.out, obs, record)
            result = {"commitment": engine.commitment(obs), "observation": obs, "record": record}
        else:
            chain = chainlib.Chain(a.rpc_url, a.verifier, a.chain_id)
            chain.check()
            signer = chainlib.signer_from_env("COLLECTOR")
            if a.cmd == "submit":
                result = submit(adapter, a.period, a.notary, chain, signer, out=a.out, dry_run=a.dry_run, log=log)
            else:
                c = a.commitment.removeprefix("0x")
                result = {"commitment": c, "tx": json.loads(chain.refund(c, signer)).get("transactionHash")}
    except (CollectError, SourceError, chainlib.ChainError, ValueError) as e:
        log(str(e))
        return 1
    print(json.dumps(result, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
