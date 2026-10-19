# Run with: python3 -m unittest discover -s test/gcpi
# gcpi/collector (#92): the CDB and ECB parsers on the publishers' bytes, the notary's refusals (the two
# slashable faults first), and the collector's handling of notaries, against a chain held in memory.
# test_collector_e2e.py runs the same code against the contracts on anvil.
import argparse
import decimal
import fractions
import json
import os
import sys
import tempfile
import threading
import unittest
import unittest.mock
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(__file__))
from collector_fixtures import FakeSources, ecb_days, ecb_zip  # noqa: E402
import chain as chainlib  # noqa: E402
import collect  # noqa: E402
import notary as notarylib  # noqa: E402
import sources  # noqa: E402
from fetch import SourceError, Transport  # noqa: E402

engine = sources.engine
PERIOD = "2026-09"
END = engine.period_start(engine.ym_index(PERIOD) + 1)
INR = lambda d, usd: str(((decimal.Decimal("94.5") + d / decimal.Decimal(100)) * decimal.Decimal(usd)).quantize(
    decimal.Decimal("0.0001")))


def fake(value="13456.78", period=PERIOD, **kw):
    y, m = int(period[:4]), int(period[5:])
    return FakeSources({("1", y, m): [value]}, ecb_zip(ecb_days(period, INR), **kw))


class FakeChain:
    verifier, chain_id = "0x00000000000000000000000000000000000000aa", 84532

    def __init__(self, now, k=2):
        self.now, self.k, self.listed, self.sent = now, k, set(), []

    def timestamp(self):
        return self.now

    def address_of(self, signer):
        return signer

    def sign(self, c, signer):
        return f"sig:{signer}:{c}"

    def verify(self, c, address, signature):
        return signature == f"sig:{address}:{c}"

    def counts(self, a):
        return a in self.listed

    def threshold(self):
        return self.k

    def window(self):
        return engine.ym_index(PERIOD) - 12, 90, 2 * 86400  # not the deployed 3 days: it is read, not assumed

    def submit_bond(self):
        return 10 ** 14

    def submitted(self, c):
        return any(engine.commitment(o) == c for o, _, _, dry in self.sent if not dry)

    def submit(self, obs, sigs, value, signer, dry_run=False):
        self.sent.append((obs, sigs, value, dry_run))
        return json.dumps({"status": "0x1", "transactionHash": "0x" + "ab" * 32})


class Parsing(unittest.TestCase):
    def test_DecimalsAreTakenExactlyAndOnlyWhenPlain(self):
        self.assertEqual(sources.decimal_parts("3525.00"), ("352500", "2"))
        self.assertEqual(sources.decimal_parts("13456.78"), ("1345678", "2"))
        self.assertEqual(sources.decimal_parts("900"), ("900", "0"))
        for bad in ("1,234.5", "", "1e3", "0", "0.00", "-5", " 12", "12.", "N/A", "01.5"):
            with self.assertRaises(SourceError, msg=bad):
                sources.decimal_parts(bad)

    def test_TheEcbMeanIsExactAndRoundsHalfUp(self):
        days = ecb_days(PERIOD, INR)
        fx, fx_exp, used = sources.ecb_monthly_mean(fake(), "INR", PERIOD)
        mean = sum(fractions.Fraction(i) / fractions.Fraction(u) for _, u, i in days) / len(days)
        want = (mean * 10 ** 4 * 2 + 1) // 2  # half up, on a positive value
        self.assertEqual((fx, fx_exp), (str(want), "4"))
        self.assertEqual(used, sorted([d, i, u] for d, u, i in days))

    def test_AnEcbMonthWithFewDaysOrMissingRatesIsRefused(self):
        na = {f"{PERIOD}-{d:02d}" for d in range(1, 13)}
        with self.assertRaises(SourceError):
            sources.ecb_monthly_mean(fake(na=na), "INR", PERIOD)
        _, _, used = sources.ecb_monthly_mean(fake(na={f"{PERIOD}-03"}), "INR", PERIOD)
        self.assertEqual(len(used), 20, "an N/A day is left out, not read as zero")
        with self.assertRaises(SourceError):
            sources.ecb_monthly_mean(fake(), "LKR", PERIOD)

    def test_OnlyTheMonthsOwnDatesCountAndEachOnce(self):
        days = ecb_days(PERIOD, INR)
        for extra in ((f"{PERIOD}-extra",) + days[0][1:], (f"{PERIOD}-1",) + days[0][1:]):
            _, _, used = sources.ecb_monthly_mean(FakeSources({}, ecb_zip(days + [extra])), "INR", PERIOD)
            self.assertEqual(len(used), len(days), extra[0])
        with self.assertRaisesRegex(SourceError, "twice"):
            sources.ecb_monthly_mean(FakeSources({}, ecb_zip(days + [days[0]])), "INR", PERIOD)

    def test_CdbGivesAValidEngineObservationAndAStableRecord(self):
        src = fake()
        obs, record = sources.Cdb().observe(src, PERIOD)
        engine.check_observation({**obs, "published": str(END)})
        self.assertEqual((obs["market"], obs["source"], obs["currency"], obs["unit"], obs["basis"]),
                         ("IN", "cdb-market-price", "INR", "quintal", "kochi"))
        self.assertEqual((obs["price"], obs["price_exp"]), ("1345678", "2"))
        self.assertEqual(record["source"]["bytes"], "13456.78")
        self.assertEqual(obs["record"], sources.record_hash(record))
        # Another retrieval sees new view state, and commits to the same record.
        again, _ = sources.Cdb().observe(fake(), PERIOD)
        self.assertEqual(again, obs)
        p, reason = engine.normalize({**obs, "published": str(END)}, 90)
        self.assertIsNone(reason)
        fx = decimal.Decimal(obs["fx"]) / 10 ** 4
        self.assertAlmostEqual(p / 1e18, float(decimal.Decimal("13456.78") / 100 / fx), places=9)
        posted = [r[2] for r in src.requests if r[0] == "POST"]
        self.assertEqual(posted[-1]["ctl00$contentBody$lstMonth"], "9")
        self.assertEqual(posted[-1]["ctl00$contentBody$ddlMarket"], "1")

    def test_CdbRefusesWhatItDoesNotRecognise(self):
        for values in ([], ["13456.78", "13456.78"], ["N/A"], ["13,456.78"]):
            src = FakeSources({("1", 2026, 9): values}, ecb_zip(ecb_days(PERIOD, INR)))
            with self.assertRaises(SourceError, msg=values):
                sources.Cdb().observe(src, PERIOD)

    def test_TheTransportReachesOnlyDeclaredHttpsHosts(self):
        t = Transport(sources.Cdb.hosts)
        for url in ("http://coconutboard.in/priceweb/Reports.aspx", "https://example.org/",
                    "https://coconutboard.in.example.org/"):
            with self.assertRaises(SourceError, msg=url):
                t.get(url)

    def test_OnlyAnEndedMonthIsCollected(self):
        self.assertFalse(sources.ended(PERIOD, END - 1))
        self.assertTrue(sources.ended(PERIOD, END))
        with self.assertRaises(collect.CollectError):
            collect.propose(sources.Cdb(), fake(), PERIOD, END - 1)


class Notary(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.log = os.path.join(self.dir.name, "notary.jsonl")
        self.now = END + 3600
        self.chain = FakeChain(self.now)
        self.src = fake()

    def tearDown(self):
        self.dir.cleanup()

    def notary(self, src=None, who="0x0000000000000000000000000000000000000001"):
        return notarylib.Notary(sources.adapters(), self.chain, who, self.log,
                                transport=lambda a: src or self.src, clock=lambda: self.now)

    def proposed(self, src=None, at=None):
        obs, _ = collect.propose(sources.Cdb(), src or fake(), PERIOD, at or END + 60)
        return obs

    def refused(self, n, obs, code):
        with self.assertRaises(notarylib.Refused) as e:
            n.attest(obs)
        self.assertEqual(e.exception.code, code)

    def test_SignsWhatItReproducesAndLogsItFirst(self):
        obs = self.proposed()
        r = self.notary().attest(obs)
        self.assertEqual(r["commitment"], engine.commitment(obs))
        self.assertTrue(self.chain.verify(r["commitment"], r["signer"], r["signature"]))
        with open(self.log) as f:
            self.assertEqual([json.loads(line)["commitment"] for line in f], [r["commitment"]])

    def test_AValueItCannotReproduceIsNotSigned(self):
        obs = self.proposed()
        self.refused(self.notary(), {**obs, "price": "1345679"}, "mismatch")
        self.refused(self.notary(), {**obs, "basis": "kozhikode"}, "mismatch")
        self.refused(self.notary(fake("13500.00")), obs, "mismatch")
        self.refused(self.notary(FakeSources({}, ecb_zip(ecb_days(PERIOD, INR)))), obs, "source")

    def test_NeverEquivocatesEvenAfterARestart(self):
        self.notary().attest(self.proposed())
        # The publisher revises the value: the new one is reproducible, but signing it is equivocation.
        revised = fake("13500.00")
        obs = self.proposed(revised)
        self.refused(self.notary(revised), obs, "would_equivocate")
        # The same value again, retrieved later, is not a conflict.
        self.now += 7200
        self.chain.now = self.now
        self.notary().attest(self.proposed(at=self.now - 60))

    def test_NothingPrematureIsSigned(self):
        obs = self.proposed()
        self.chain.now = int(obs["published"]) - 1
        self.refused(self.notary(), obs, "chain_clock_behind")
        self.chain.now = self.now
        self.refused(self.notary(), {**obs, "published": str(self.now + 1)}, "published_in_future")
        self.now = END - 10
        self.refused(self.notary(), {**obs, "published": str(END - 20)}, "period_not_ended")

    def test_PublicationMustBeTheRecentRetrievalItClaims(self):
        obs = self.proposed()
        self.now = int(obs["published"]) + notarylib.ATTEST_WINDOW + 1
        self.refused(self.notary(), obs, "published_too_old")

    def test_ItSignsOutsideTheLockAndOnlyOnceTheValueIsLogged(self):
        n = self.notary()
        def sign(c, signer):
            self.assertFalse(n._lock.locked(), "a slow signer must not hold up other requests")
            with open(self.log) as f:
                self.assertIn(c, f.read())
            return f"sig:{signer}:{c}"
        self.chain.sign = sign
        n.attest(self.proposed())

    def test_ItAnswersOverHttpAndRefusesWhatIsNotAnObservation(self):
        server = notarylib.Server(("127.0.0.1", 0), notarylib.handler(self.notary(), quiet=True))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        url = f"http://127.0.0.1:{server.server_address[1]}"
        for body, code in (("[" * 60000, "not_json"), ("[1]", "malformed"), ('{"market": 7}', "malformed")):
            req = urllib.request.Request(url + "/attest", body.encode(), {"Content-Type": "application/json"})
            with self.assertRaises(urllib.error.HTTPError, msg=body[:10]) as e:
                urllib.request.urlopen(req, timeout=10)
            with e.exception:
                self.assertEqual(json.loads(e.exception.read())["refused"], code)
        obs = self.proposed()
        self.assertEqual(collect.ask(url, obs)["commitment"], engine.commitment(obs))

    def test_OnlyPeriodsTheVerifierStillAcceptsAreAttested(self):
        old = collect.propose(sources.Cdb(), fake(period="2025-08"), "2025-08", self.now)[0]
        self.refused(self.notary(fake(period="2025-08")), old, "out_of_range")
        obs = self.proposed()
        closes = engine.period_start(engine.ym_index(PERIOD) + 1) + (90 + 2) * 86400
        self.chain.now = closes
        self.refused(self.notary(), obs, "window_closed")
        self.chain.now = closes - 1
        self.notary().attest(obs)

    def test_ItRetrievesOncePerPeriodHoweverOftenItIsAsked(self):
        retrievals = []
        src = lambda a: retrievals.append(1) or fake()
        n = notarylib.Notary(sources.adapters(), self.chain, "0x" + "0" * 39 + "1", self.log, transport=src,
                             clock=lambda: self.now)
        obs = self.proposed()
        threads = [threading.Thread(target=n.attest, args=(obs,)) for _ in range(8)]
        for th in threads:
            th.start()
        for th in threads:
            th.join()
        n.attest(obs)
        self.assertEqual(len(retrievals), 1, "concurrent and repeated requests share one retrieval")
        self.now += notarylib.RETRIEVAL_TTL
        n.attest(obs)
        self.assertEqual(len(retrievals), 2, "and it is made again once it is RETRIEVAL_TTL old")

    def test_AFailedRetrievalIsNotRetriedOnEveryRequest(self):
        retrievals = []
        src = lambda a: retrievals.append(1) or FakeSources({}, ecb_zip(ecb_days(PERIOD, INR)))
        n = notarylib.Notary(sources.adapters(), self.chain, "0x" + "0" * 39 + "1", self.log, transport=src,
                             clock=lambda: self.now)
        obs = self.proposed()
        for _ in range(3):
            self.refused(n, obs, "source")
        self.assertEqual(len(retrievals), 1)

    def test_ListenTakesHostAndPortOnly(self):
        self.assertEqual(notarylib.listen_address("127.0.0.1:8645"), ("127.0.0.1", 8645))
        self.assertEqual(notarylib.listen_address("[::1]:8645"), ("::1", 8645))
        for bad in ("8645", "127.0.0.1", "127.0.0.1:", "host:port", "127.0.0.1:99999", "a:1/x"):
            with self.assertRaises(argparse.ArgumentTypeError, msg=bad):
                notarylib.listen_address(bad)

    def test_UnservedAndMalformedObservationsAreRefused(self):
        obs = self.proposed()
        self.refused(self.notary(), {**obs, "market": "LK"}, "not_served")
        self.refused(self.notary(), {**obs, "record": "XYZ"}, "malformed")
        self.refused(self.notary(), {k: v for k, v in obs.items() if k != "basis"}, "malformed")


class Collector(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.now = END + 3600
        self.chain = FakeChain(self.now)
        self.who = [f"0x{i:040x}" for i in (3, 1, 2)]
        self.chain.listed = set(self.who)
        self.notaries = {w: notarylib.Notary(sources.adapters(), self.chain, w,
                                             os.path.join(self.dir.name, f"{w}.jsonl"),
                                             transport=lambda a: fake(), clock=lambda: self.now) for w in self.who}

    def tearDown(self):
        self.dir.cleanup()

    def asker(self, overrides=None):
        def ask(url, obs):
            if overrides and url in overrides:
                return overrides[url](obs)
            try:
                return self.notaries[url].attest(obs)
            except notarylib.Refused as e:
                raise collect.CollectError(f"{url}: {e}")
        return ask

    def test_SubmitsKSignaturesInAscendingSignerOrder(self):
        r = collect.submit(sources.Cdb(), PERIOD, self.who, self.chain, "collector", transport=fake(),
                           out=self.dir.name, now=self.now, asker=self.asker())
        self.assertEqual(r["status"], "submitted")
        (_, _, _, dry), (obs, sigs, value, _) = self.chain.sent
        self.assertTrue(dry, "every submission is simulated first")
        self.assertEqual(sigs, [f"sig:{w}:{r['commitment']}" for w in sorted(self.who)[:2]])
        self.assertEqual(value, 10 ** 14)
        with open(os.path.join(self.dir.name, r["commitment"] + ".json")) as f:
            kept = json.load(f)
        self.assertEqual(sources.record_hash(kept["record"]), obs["record"])
        again = collect.submit(sources.Cdb(), PERIOD, self.who, self.chain, "collector", transport=fake(),
                               now=self.now, asker=self.asker())
        self.assertEqual(again["status"], "already_submitted")

    def test_BadOrNonCountingAttestationsAreSkippedNotSent(self):
        forged = lambda obs: {"signer": self.who[0], "signature": "sig:forged", "commitment": engine.commitment(obs)}
        self.chain.listed.discard(self.who[1])
        with self.assertRaises(collect.CollectError):
            collect.submit(sources.Cdb(), PERIOD, self.who, self.chain, "collector", transport=fake(),
                           now=self.now, asker=self.asker({self.who[0]: forged}))
        self.assertEqual(self.chain.sent, [], "nothing is sent without k usable attestations")

    def test_AnAnswerThatIsNotAnAttestationIsSkipped(self):
        odd = {self.who[0]: lambda obs: [1], self.who[1]: lambda obs: {"signer": 1, "signature": None}}
        obs, _ = collect.propose(sources.Cdb(), fake(), PERIOD, self.now)
        c = engine.commitment(obs)
        self.assertEqual(collect.gather(obs, self.who, self.chain, 1, self.asker(odd)), [f"sig:{self.who[2]}:{c}"])
        with self.assertRaisesRegex(collect.CollectError, "1 usable attestations, 2 needed"):
            collect.gather(obs, self.who, self.chain, 2, self.asker(odd))

    def test_ARefusingNotaryIsSkipped(self):
        refuse = lambda obs: (_ for _ in ()).throw(collect.CollectError("refused"))
        r = collect.submit(sources.Cdb(), PERIOD, self.who, self.chain, "collector", transport=fake(),
                           now=self.now, asker=self.asker({self.who[0]: refuse}))
        self.assertEqual(self.chain.sent[-1][1], [f"sig:{w}:{r['commitment']}" for w in sorted(self.who[1:])])


class ChainAnswers(unittest.TestCase):
    def submitted(self, submitter, basis="kochi"):
        c = chainlib.Chain("http://127.0.0.1:1", "0x" + "aa" * 20, 1)
        c.call = lambda *a: (f'(("IN", "2026-09", "cdb-market-price", 1345678 [1.345e6], 2, "INR", "quintal", true, '
                             f'885123 [8.851e5], 4, "ecb-monthly-mean", 1790000000 [1.79e9], 0x{"ab" * 32}, '
                             f'"{basis}"), 0, 680, {submitter}, false)')
        return c.submitted("ab" * 32)

    def test_AKeystoreSignerNeedsItsPasswordFile(self):
        env = {"NOTARY_KEYSTORE": "/keys/notary"}
        with unittest.mock.patch.dict(os.environ, env, clear=True):
            with self.assertRaisesRegex(chainlib.ChainError, "NOTARY_PASSWORD_FILE"):
                chainlib.signer_from_env("NOTARY")
        with unittest.mock.patch.dict(os.environ, {**env, "NOTARY_PASSWORD_FILE": "/keys/password"}, clear=True):
            self.assertEqual(chainlib.signer_from_env("NOTARY"),
                             ["--keystore", "/keys/notary", "--password-file", "/keys/password"])

    def test_SubmittedReadsTheSubmitterAndNothingElse(self):
        zero, someone = "0x" + "0" * 40, "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
        self.assertTrue(self.submitted(someone))
        self.assertFalse(self.submitted(zero))
        self.assertTrue(self.submitted(someone, basis=zero), "an identifier may spell the zero address")
        with self.assertRaises(chainlib.ChainError):
            self.submitted("garbage")


if __name__ == "__main__":
    unittest.main()
