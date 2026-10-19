"""
GCPI collectors (#92): the chain, through Foundry's `cast`. What a notary signs is built here, from the chain
id and verifier address it was configured with, never from an RPC answer: a node that lied about the
attestation digest could otherwise have the notary sign an observation it never checked.
"""

import json
import os
import re
import subprocess

DOMAIN = {"name": "GCPI ObservationVerifier", "version": "1"}
OBSERVATION = ("(string,string,string,uint256,uint256,string,string,bool,uint256,uint256,string,uint256,"
               "bytes32,string)")
SUBMIT = f"submit({OBSERVATION},bytes[])"


class ChainError(Exception):
    pass


def signer_from_env(prefix):
    """cast's signer arguments from <prefix>_KEY or <prefix>_KEYSTORE (password in ETH_PASSWORD), never both."""
    key, keystore = os.environ.get(f"{prefix}_KEY"), os.environ.get(f"{prefix}_KEYSTORE")
    if key and keystore:
        raise ChainError(f"{prefix}_KEY and {prefix}_KEYSTORE are both set; set only one signer")
    if key:
        return ["--private-key", key]
    if keystore:
        return ["--keystore", keystore]
    raise ChainError(f"{prefix}_KEY or {prefix}_KEYSTORE must be set")


def cast(*args, timeout=120):
    try:
        r = subprocess.run(["cast", *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise ChainError(f"cast {args[0]}: {e}") from e
    if r.returncode != 0:
        lines = (r.stderr or r.stdout).strip().splitlines()
        raise ChainError(f"cast {args[0]}: {lines[-1] if lines else 'failed'}")
    return r.stdout.strip()


def typed_data(chain_id, verifier, commitment):
    """EIP-712 typed data for an attestation, as ObservationVerifier.attestationDigest hashes it."""
    return {
        "types": {
            "EIP712Domain": [{"name": "name", "type": "string"}, {"name": "version", "type": "string"},
                             {"name": "chainId", "type": "uint256"}, {"name": "verifyingContract", "type": "address"}],
            "Attestation": [{"name": "commitment", "type": "bytes32"}],
        },
        "primaryType": "Attestation",
        "domain": {**DOMAIN, "chainId": chain_id, "verifyingContract": verifier},
        "message": {"commitment": "0x" + commitment},
    }


def observation_tuple(o):
    """An engine observation (gcpi/ENGINE.md §1, all strings) as cast's argument for the Solidity struct.
    Strings are quoted: cast cannot parse an empty unquoted field. Identifiers never contain quotes."""
    q = lambda s: '"' + s + '"'
    has_fx = o["fx"] != ""
    parts = [q(o["market"]), q(o["period"]), q(o["source"]), o["price"], o["price_exp"], q(o["currency"]),
             q(o["unit"]), "true" if has_fx else "false", o["fx"] if has_fx else "0",
             o["fx_exp"] if has_fx else "0", q(o["fx_source"]), o["published"], "0x" + o["record"], q(o["basis"])]
    return "(" + ",".join(parts) + ")"


class Chain:
    def __init__(self, rpc_url, verifier, chain_id):
        self.rpc_url, self.verifier, self.chain_id = rpc_url, verifier, int(chain_id)
        self._window = None

    def _rpc(self, *args):
        return cast(*args, "--rpc-url", self.rpc_url)

    def check(self):
        """The node serves the configured chain, so a signature for it is not wasted on another."""
        got = int(self._rpc("chain-id"))
        if got != self.chain_id:
            raise ChainError(f"RPC serves chain {got}, configured for {self.chain_id}")

    def timestamp(self):
        return int(self._rpc("block", "latest", "--field", "timestamp"))

    def call(self, sig, *args):
        return self._rpc("call", self.verifier, sig, *args)

    def counts(self, notary):
        return self.call("counts(address)(bool)", notary) == "true"

    def threshold(self):
        return int(self.call("threshold()(uint256)").split()[0])

    def window(self):
        """(firstPeriod, maxPublicationLagDays, CHALLENGE_WINDOW): the periods the verifier accepts. All are
        immutable, so they are read once."""
        if self._window is None:
            self._window = tuple(int(self.call(f"{f}()(uint256)").split()[0])
                                 for f in ("firstPeriod", "maxPublicationLagDays", "CHALLENGE_WINDOW"))
        return self._window

    def submit_bond(self):
        return int(self.call("submitBond()(uint256)").split()[0])

    def submitted(self, commitment):
        """Whether the verifier already holds this observation."""
        out = self.call(f"observation(bytes32)(({OBSERVATION},uint32,uint32,address,bool))", "0x" + commitment)
        # The submitter, the struct's last address, is set exactly when it is held (submit()'s Duplicate check).
        # Only that field is read: an identifier such as `basis` may itself spell the zero address.
        submitter = out.rstrip().removesuffix(")").rsplit(",", 2)[-2].strip()
        if not re.fullmatch(r"0x[0-9a-fA-F]{40}", submitter):
            raise ChainError(f"observation(): unexpected answer {out[-120:]!r}")
        return int(submitter, 16) != 0

    def address_of(self, signer):
        return address_of(signer)

    def sign(self, commitment, signer):
        return cast("wallet", "sign", "--data", json.dumps(typed_data(self.chain_id, self.verifier, commitment)),
                    *signer)

    def verify(self, commitment, address, signature):
        try:
            cast("wallet", "verify", "--data", "--address", address,
                 json.dumps(typed_data(self.chain_id, self.verifier, commitment)), signature)
            return True
        except ChainError:
            return False

    def submit(self, obs, signatures, value, signer, dry_run=False):
        args = [SUBMIT, observation_tuple(obs), "[" + ",".join(signatures) + "]", "--value", str(value)]
        if dry_run:
            # eth_call as the submitter: any revert surfaces here, before a transaction is sent.
            frm = cast("wallet", "address", *signer)
            return self._rpc("call", self.verifier, *args, "--from", frm)
        return self._rpc("send", self.verifier, *args, *signer, "--json")

    def refund(self, commitment, signer):
        return self._rpc("send", self.verifier, "refundBond(bytes32)", "0x" + commitment, *signer, "--json")


def address_of(signer):
    return cast("wallet", "address", *signer)
