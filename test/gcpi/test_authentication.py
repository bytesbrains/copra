# Run with: python3 -m unittest discover -s test/gcpi
# The source authentication research (#89): the probe's verdicts and the Base attestor reader's ABI
# decoding, on synthetic inputs and one real response captured from Base mainnet.
import os
import sys
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
sys.path.insert(0, os.path.join(ROOT, "gcpi", "research"))
import base_attestors  # noqa: E402
import tls_probe  # noqa: E402

# Reclaim 0x15d2...D042 fetchEpoch(2) on Base mainnet, 18 October 2026: one witness, one signature.
RECLAIM_EPOCH_2 = "0x000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000066a1030d0000000000000000000000000000000000000000000000000000000066a2548d00000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000244897572368eadf65bfbc5aec98d8e5443a907200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000000"


def word(n):
    return f"{n:064x}"


def epoch(witnesses, minimum):
    """ABI-encodes fetchEpoch's return for a list of witness addresses, each with an empty URL."""
    n = len(witnesses)
    heads = [word(32 * n + 96 * i) for i in range(n)]          # each element: address, offset, empty string
    tails = [word(int(a, 16)) + word(64) + word(0) for a in witnesses]
    struct = word(7) + word(100) + word(200) + word(160) + word(minimum)
    return "0x" + word(32) + struct + word(n) + "".join(heads) + "".join(tails)


class EpochDecoding(unittest.TestCase):
    def test_the_captured_base_epoch(self):
        e = base_attestors.decode_epoch(RECLAIM_EPOCH_2)
        self.assertEqual(e["id"], 2)
        self.assertEqual(e["witnesses"], ["0x244897572368eadf65bfbc5aec98d8e5443a9072"])
        self.assertEqual(e["minimum_signatures"], 1)

    def test_several_witnesses_follow_their_offsets(self):
        ws = ["0x" + "11" * 20, "0x" + "22" * 20, "0x" + "33" * 20]
        e = base_attestors.decode_epoch(epoch(ws, 2))
        self.assertEqual(e["witnesses"], ws)
        self.assertEqual(e["minimum_signatures"], 2)
        self.assertEqual((e["id"], e["from"], e["to"]), (7, 100, 200))

    def test_address_and_argument_encoding(self):
        self.assertEqual(base_attestors.address(int("ab" * 20, 16)), "0x" + "ab" * 20)
        self.assertEqual(base_attestors.arg("0x10"), word(16))
        self.assertEqual(base_attestors.arg(2), word(2))


def probed(**kw):
    p = {"status": 200, "challenged": False, "needs_key": False, "tls12": True, "same_bytes": True,
         "changed_lines": 0, "kind": "json"}
    p.update(kw)
    return p


class ProbeVerdicts(unittest.TestCase):
    def test_tls13_only_rules_out_mpc_tls(self):
        self.assertIn("TLS 1.3 only", tls_probe.verdict(probed(tls12=False)))

    def test_a_challenge_or_key_is_reported_before_the_status(self):
        self.assertIn("bot challenge", tls_probe.verdict(probed(status=403, challenged=True)))
        self.assertIn("API key", tls_probe.verdict(probed(status=400, needs_key=True)))
        self.assertEqual(tls_probe.verdict(probed(status=404)), "HTTP 404: no attestation possible")
        self.assertIn("unreachable", tls_probe.verdict(probed(status=None)))

    def test_changing_bytes_mean_committing_to_the_value_only(self):
        self.assertIn("1 line(s) change", tls_probe.verdict(probed(same_bytes=False, changed_lines=1)))

    def test_formats(self):
        self.assertIn("structured", tls_probe.verdict(probed(kind="xml")))
        self.assertIn("byte range", tls_probe.verdict(probed(kind="html")))
        self.assertIn("pdf must be parsed outside", tls_probe.verdict(probed(kind="pdf")))

    def test_kind_reads_magic_bytes_before_the_header(self):
        self.assertEqual(tls_probe.kind("application/octet-stream", b"%PDF-1.7"), "pdf")
        self.assertEqual(tls_probe.kind(None, b"PK\x03\x04"), "xlsx")
        self.assertEqual(tls_probe.kind("application/json; charset=utf-8", b"{}"), "json")
        self.assertEqual(tls_probe.kind("text/html", b"<html>"), "html")

    def test_challenge_and_key_detection(self):
        self.assertTrue(tls_probe.challenged(403, {"cf-mitigated": "challenge"}, b""))
        self.assertTrue(tls_probe.challenged(403, {"server": "cloudflare"}, b"Just a moment"))
        self.assertFalse(tls_probe.challenged(200, {"server": "cloudflare"}, b"{}"))
        self.assertTrue(tls_probe.needs_key(400, b'{"error": "Authorization field missing"}'))
        self.assertFalse(tls_probe.needs_key(400, b"bad request"))

    def test_changed_lines_counts_replaced_lines_once(self):
        a = b"<html>\ntoken=1\n<p>2,450</p>\n"
        b = b"<html>\ntoken=2\n<p>2,450</p>\n"
        self.assertEqual(tls_probe.changed_lines(a, b), 1)
        self.assertEqual(tls_probe.changed_lines(a, a), 0)


if __name__ == "__main__":
    unittest.main()
