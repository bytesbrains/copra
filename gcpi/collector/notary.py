#!/usr/bin/env python3
"""
GCPI collectors (#92): a notary (GCPI-001 §5.3.1). It signs an observation only after retrieving the source
itself and getting exactly the same observation, so its signature says "I fetched this from the listed
source over TLS and it served this value". Being the TLS client, it knows the value first hand; its trust
is proxy mode's (§5.3.6 #2): no network attacker between it and the publisher. The contracts check only the
signature, so a TLSNotary backend can replace the retrieval later without changing them.

A notary's bond is slashed for two provable faults (§5.4), and this refuses both before signing:
  - premature: it signs only once the chain's own clock has passed the period's start and the publication
    time (gcpi/CONTRACTS.md), and only for a month that has ended;
  - equivocation: it keeps a log of what it signed, and never signs a different normalized price or basis
    for a market, source and period it already signed. The log is written before the signature leaves.
    Losing the log loses that protection, so it belongs on durable storage.

Usage: notary.py --rpc-url URL --verifier 0x.. --chain-id N --log notary.jsonl [--listen 127.0.0.1:8545]
                 [--serve cdb-market-price:IN ...]      signer from NOTARY_KEY or NOTARY_KEYSTORE
"""

import argparse
import http.server
import json
import os
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import chain as chainlib  # noqa: E402
import sources  # noqa: E402
from fetch import SourceError, Transport  # noqa: E402

engine = sources.engine

# `published` is the collector's first retrieval (§5.2), so the notary's own retrieval must follow it closely.
ATTEST_WINDOW = 24 * 3600
MAX_BODY = 64 * 1024


class Refused(Exception):
    def __init__(self, code, detail=""):
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code, self.detail = code, detail


class Notary:
    def __init__(self, adapters, chain, signer, log_path, transport=None, clock=time.time):
        self.adapters, self.chain, self.signer, self.log_path = adapters, chain, signer, log_path
        self.transport = transport or (lambda adapter: Transport(adapter.hosts))
        self.clock = clock
        self.address = chain.address_of(signer)
        self._lock = threading.Lock()
        self._signed = {}
        if os.path.exists(log_path):
            with open(log_path) as f:
                for line in f:
                    e = json.loads(line)
                    self._signed.setdefault(tuple(e["key"]), set()).add((e["price"], e["basis"]))

    def attest(self, obs):
        """{signer, signature, commitment} for an observation this notary reproduced, or Refused."""
        try:
            engine.check_observation(obs)
        except engine.EngineError as e:
            raise Refused("malformed", str(e))
        adapter = self.adapters.get((obs["source"], obs["market"]))
        if adapter is None:
            raise Refused("not_served", f"{obs['source']}:{obs['market']}")
        now, published = int(self.clock()), int(obs["published"])
        start = engine.period_start(engine.ym_index(obs["period"]))
        if published > now:
            raise Refused("published_in_future")
        if now - published > ATTEST_WINDOW:
            raise Refused("published_too_old", f"{now - published} s before this retrieval")
        if not sources.ended(obs["period"], now):
            raise Refused("period_not_ended")
        if self.chain.timestamp() < max(start, published):
            raise Refused("chain_clock_behind", "signing now could be slashed as premature")
        try:
            mine, _ = adapter.observe(self.transport(adapter), obs["period"])
        except SourceError as e:
            raise Refused("source", str(e))
        differ = sorted(f for f in mine if mine[f] != obs[f])
        if differ:
            raise Refused("mismatch", ", ".join(differ))
        price, reason = engine.normalize(obs, 36500)
        if price is None:
            raise Refused("unusable", reason)
        c = engine.commitment(obs)
        key = (obs["market"], obs["source"], obs["period"])
        with self._lock:
            if self._signed.get(key, set()) - {(str(price), obs["basis"])}:
                raise Refused("would_equivocate", "already signed another value for this market, source and period")
            if (str(price), obs["basis"]) not in self._signed.get(key, set()):
                with open(self.log_path, "a") as f:
                    f.write(json.dumps({"key": list(key), "price": str(price), "basis": obs["basis"],
                                        "commitment": c, "at": now}) + "\n")
                    f.flush()
                    os.fsync(f.fileno())
                self._signed.setdefault(key, set()).add((str(price), obs["basis"]))
            signature = self.chain.sign(c, self.signer)
        return {"signer": self.address, "signature": signature, "commitment": c}


def handler(notary, quiet=False):
    class Handler(http.server.BaseHTTPRequestHandler):
        def _reply(self, code, body):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path != "/health":
                return self._reply(404, {"error": "not_found"})
            self._reply(200, {"signer": notary.address, "verifier": notary.chain.verifier,
                              "chain_id": notary.chain.chain_id, "serves": [":".join(k) for k in notary.adapters]})

        def do_POST(self):
            if self.path != "/attest":
                return self._reply(404, {"error": "not_found"})
            n = int(self.headers.get("Content-Length") or 0)
            if not 0 < n <= MAX_BODY:
                return self._reply(413, {"refused": "body_size"})
            try:
                obs = json.loads(self.rfile.read(n))
            except ValueError:
                return self._reply(400, {"refused": "not_json"})
            try:
                self._reply(200, notary.attest(obs))
            except Refused as e:
                self._reply(422, {"refused": e.code, "detail": e.detail})
            except chainlib.ChainError as e:
                self._reply(503, {"refused": "chain", "detail": str(e)})

        def log_message(self, fmt, *args):
            if not quiet:
                sys.stderr.write("notary: " + fmt % args + "\n")

    return Handler


def main(argv):
    p = argparse.ArgumentParser(description="GCPI notary (#92)")
    p.add_argument("--rpc-url", required=True)
    p.add_argument("--verifier", required=True)
    p.add_argument("--chain-id", required=True, type=int)
    p.add_argument("--log", required=True)
    p.add_argument("--listen", default="127.0.0.1:8645")
    p.add_argument("--serve", nargs="+", default=["cdb-market-price:IN"])
    a = p.parse_args(argv)
    try:
        chain = chainlib.Chain(a.rpc_url, a.verifier, a.chain_id)
        chain.check()
        notary = Notary(sources.adapters(a.serve), chain, chainlib.signer_from_env("NOTARY"), a.log)
    except (chainlib.ChainError, ValueError) as e:
        print(f"notary: {e}", file=sys.stderr)
        return 1
    host, _, port = a.listen.rpartition(":")
    server = http.server.ThreadingHTTPServer((host, int(port)), handler(notary))
    print(f"notary {notary.address} on {a.listen} for {a.verifier} (chain {a.chain_id})", file=sys.stderr)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
