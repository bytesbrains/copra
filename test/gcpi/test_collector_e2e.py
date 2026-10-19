# Run with: python3 -m unittest discover -s test/gcpi        (needs Foundry's anvil, forge and cast; skipped without)
# gcpi/collector (#92) end to end against the contracts: DeployGCPI on anvil, three bonded notaries serving
# HTTP, and a collector whose observation the verifier accepts. This is what proves the EIP-712 typed data the
# notary signs is the digest ObservationVerifier checks, and that cast encodes the observation it commits to.
import decimal
import http.server
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock

sys.path.insert(0, os.path.dirname(__file__))
from collector_fixtures import ROOT, FakeSources, ecb_days, ecb_zip  # noqa: E402
import chain as chainlib  # noqa: E402
import collect  # noqa: E402
import notary as notarylib  # noqa: E402
import sources  # noqa: E402
from fetch import Transport  # noqa: E402

engine = sources.engine
PERIOD = "2026-09"
GENESIS = engine.period_start(engine.ym_index(PERIOD) + 1) + 14 * 86400  # mid October 2026
# anvil's well-known development keys: 0 deploys, 1-3 are notaries, 4 collects.
KEYS = ["0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
        "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
        "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
        "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
        "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"]
TOOLS = all(shutil.which(t) for t in ("anvil", "forge", "cast"))


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@unittest.skipUnless(TOOLS, "Foundry (anvil, forge, cast) is not installed")
class EndToEnd(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # unittest skips tearDownClass when this raises, so a failure here cleans up after itself.
        try:
            cls._setUp()
        except BaseException:
            cls.tearDownClass()
            raise

    @classmethod
    def _setUp(cls):
        cls.dir = tempfile.TemporaryDirectory()
        port = free_port()
        cls.rpc = f"http://127.0.0.1:{port}"
        cls.anvil = subprocess.Popen(["anvil", "--port", str(port), "--timestamp", str(GENESIS), "--block-time", "1",
                                      "--silent"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                chainlib.cast("chain-id", "--rpc-url", cls.rpc)
                break
            except chainlib.ChainError:
                time.sleep(0.1)
        # The Base Sepolia methodology (#92): India alone, base period 2026-09.
        cls.methodology = os.path.join(ROOT, "gcpi", "engine", "methodology", "gcpi-1-draft.1-in-testnet.json")
        cls.notaries = [chainlib.address_of(["--private-key", k]) for k in KEYS[1:4]]
        env = {**os.environ, "PRIVATE_KEY": KEYS[0], "GCPI_METHODOLOGY": cls.methodology, "GCPI_FIRST": PERIOD,
               "GCPI_NOTARIES": ",".join(cls.notaries), "GCPI_THRESHOLD": "2"}
        out = subprocess.run(["forge", "script", "script/DeployGCPI.s.sol:DeployGCPI", "--rpc-url", cls.rpc,
                              "--broadcast"], cwd=ROOT, env=env, capture_output=True, text=True, timeout=600)
        found = re.search(r"ObservationVerifier: (0x[0-9a-fA-F]{40})", out.stdout)
        if out.returncode != 0 or not found:
            raise RuntimeError(f"DeployGCPI failed:\n{out.stdout[-2000:]}\n{out.stderr[-2000:]}")
        cls.chain = chainlib.Chain(cls.rpc, found.group(1), 31337)
        for k in KEYS[1:4]:
            chainlib.cast("send", cls.chain.verifier, "bond()", "--value", "0.01ether", "--private-key", k,
                          "--rpc-url", cls.rpc)
        cls.servers = []

    @classmethod
    def tearDownClass(cls):
        for s in getattr(cls, "servers", []):
            s.shutdown()
            s.server_close()
        if getattr(cls, "anvil", None):
            cls.anvil.terminate()
            cls.anvil.wait(timeout=10)
        if getattr(cls, "dir", None):
            cls.dir.cleanup()

    def serve(self, key, source):
        """A notary over HTTP, retrieving whatever source() returns at the time it is asked: no reuse, since
        these tests change the source between requests. `key` is a private key or cast's signer arguments."""
        signer = key if isinstance(key, list) else ["--private-key", key]
        n = notarylib.Notary(sources.adapters(), self.chain, signer,
                             os.path.join(self.dir.name, f"notary-{len(self.servers)}.jsonl"),
                             transport=lambda a: source(), clock=self.chain.timestamp, retrieval_ttl=0)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), notarylib.handler(n, quiet=True))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.servers.append(server)
        return f"http://127.0.0.1:{server.server_address[1]}"

    def source(self, value):
        inr = lambda d, usd: str(((decimal.Decimal("94.5") + d / decimal.Decimal(100)) * decimal.Decimal(usd))
                                 .quantize(decimal.Decimal("0.0001")))
        return FakeSources({("1", 2026, 9): [value]}, ecb_zip(ecb_days(PERIOD, inr)))

    def collect(self, src, log=lambda m: None, signer=None):
        return collect.submit(sources.Cdb(), PERIOD, self.urls, self.chain, signer or ["--private-key", KEYS[4]],
                              transport=src, out=self.dir.name, now=self.chain.timestamp(), log=log)

    def keystore(self, prefix, key):
        """The environment that names `key` in a password-protected keystore, as an operator would set it."""
        d = tempfile.mkdtemp(dir=self.dir.name)
        password = os.path.join(d, "password")
        with open(password, "w") as f:
            f.write("e2e")
        chainlib.cast("wallet", "import", "signer", "--private-key", key, "--keystore-dir", d,
                      "--unsafe-password", "e2e")
        return {f"{prefix}_KEYSTORE": os.path.join(d, "signer"), f"{prefix}_PASSWORD_FILE": password}

    def test_ACollectorsObservationIsAcceptedWithTwoOfThreeNotaries(self):
        src = self.source("13456.78")
        self.urls = [self.serve(k, lambda: src) for k in KEYS[1:4]]
        r = self.collect(src)
        # Accepted means the verifier recovered two counting notaries from the typed data they signed.
        self.assertEqual(r["status"], "submitted")
        held = self.chain.call("commitments(uint256,uint256)(bytes32[])", "0", str(engine.ym_index(PERIOD)))
        self.assertIn(r["commitment"], held)
        self.assertTrue(self.chain.submitted(r["commitment"]))
        with open(os.path.join(self.dir.name, r["commitment"] + ".json")) as f:
            kept = json.load(f)
        self.assertEqual(sources.record_hash(kept["record"]), kept["observation"]["record"])

    def test_ARevisedValueGetsNoQuorumFromNotariesThatSignedTheFirst(self):
        now = {"src": self.source("13456.78")}
        self.urls = [self.serve(k, lambda: now["src"]) for k in KEYS[1:4]]
        self.assertEqual(self.collect(now["src"])["status"], "submitted")
        # The publisher revises the value. Every notary reproduces it, and none signs it: that is equivocation.
        now["src"] = self.source("13500.00")
        refusals = []
        with self.assertRaisesRegex(collect.CollectError, "0 usable attestations"):
            self.collect(now["src"], log=refusals.append)
        self.assertEqual(sum("would_equivocate" in m for m in refusals), 3, refusals)

    def test_KeystoreSignersAttestAndSubmit(self):
        # Without its password file a keystore signer would prompt, and an ETH_PASSWORD set to make it stop
        # prompting breaks every cast call instead. Each signer is named the way notary.py and collect.py read it.
        # An ETH_PASSWORD left over from the old instructions must not break them either.
        env = {**self.keystore("NOTARY", KEYS[1]), **self.keystore("COLLECTOR", KEYS[4]),
               "ETH_PASSWORD": os.path.join(self.dir.name, "stale-password")}
        with unittest.mock.patch.dict(os.environ, env):
            notary, collector = chainlib.signer_from_env("NOTARY"), chainlib.signer_from_env("COLLECTOR")
            self.assertEqual(chainlib.address_of(notary), self.notaries[0])
            src = self.source("13456.78")
            self.urls = [self.serve(notary, lambda: src), self.serve(KEYS[2], lambda: src)]
            r = self.collect(src, signer=collector)
        self.assertEqual(r["status"], "submitted")
        self.assertTrue(self.chain.submitted(r["commitment"]))

    @unittest.skipUnless(os.environ.get("GCPI_LIVE"), "set GCPI_LIVE=1 to retrieve from coconutboard.in and the ECB")
    def test_LiveRetrievalsReachQuorum(self):
        # Every retrieval, the collector's and each notary's, is its own session to the publishers.
        live = lambda: Transport(sources.Cdb.hosts)
        self.urls = [self.serve(k, live) for k in KEYS[1:4]]
        r = self.collect(live())
        self.assertEqual(r["status"], "submitted")
        self.assertTrue(self.chain.submitted(r["commitment"]))


if __name__ == "__main__":
    unittest.main()
