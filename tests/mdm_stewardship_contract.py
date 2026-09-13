import hashlib
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = ROOT / "contracts/MDM-STEWARDSHIP-1.json"
FIXTURE_PATH = ROOT / "contracts/MDM-STEWARDSHIP-1-fixture.json"
CONTRACT_SHA256 = "babd8510203cac5b4d0486e82a76b4d306ccec9bd539c778e444bfe3ca23764e"
FIXTURE_SHA256 = "00d0eaad21601b0048ff7139fac435ee04f222ffc26894698bd97418ac5b8e06"


def canonical_json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def vector_digest(domain, body):
    tag = domain.encode("utf-8")
    payload = canonical_json(body).encode("utf-8")
    framed = struct.pack(">I", len(tag)) + tag + struct.pack(">I", len(payload)) + payload
    return hashlib.sha256(framed).hexdigest()


def main():
    contract_bytes = CONTRACT_PATH.read_bytes()
    fixture_bytes = FIXTURE_PATH.read_bytes()
    assert hashlib.sha256(contract_bytes).hexdigest() == CONTRACT_SHA256
    assert hashlib.sha256(fixture_bytes).hexdigest() == FIXTURE_SHA256

    contract = json.loads(contract_bytes)
    fixture = json.loads(fixture_bytes)
    assert contract["contract"] == fixture["contract"] == "MDM-STEWARDSHIP/1"
    assert contract["revision"] == fixture["revision"] == 1
    assert contract["conformance_fixture"] == {
        "file": FIXTURE_PATH.name,
        "sha256": FIXTURE_SHA256,
    }
    assert contract["shared_conformance_cases"] == fixture["shared_conformance_cases"]

    encoding = contract["canonical_encoding"]
    for domain_key, vector_key in (
        ("basis_domain_tag", "basis_vector"),
        ("intent_domain_tag", "intent_vector"),
        ("request_key_domain_tag", "request_key_vector"),
    ):
        vector = fixture[vector_key]
        canonical = canonical_json(vector["body"])
        assert vector["canonical_json_utf8"] == canonical
        assert vector["sha256"] == vector_digest(encoding[domain_key], vector["body"])
        assert vector == encoding[vector_key]

    assert fixture["intent_vector"]["request_key"] == fixture["request_key_vector"]["sha256"]
    receipt_columns = contract["sql"]["receipts"]["columns"]
    assert ["actor", "name", "not null; MDM records the authenticated effective database role before privileged execution; caller cannot supply it"] in receipt_columns
    assert contract["intent"]["idempotency"]["changed_body"] == {
        "receipt_id": None,
        "outcome": "IDEMPOTENCY_CONFLICT",
        "reason_code": "REQUEST_KEY_BODY_MISMATCH",
        "insert_conflict_receipt": False,
        "existing_receipt": "unchanged",
    }
    print("pg-react MDM-STEWARDSHIP/1 contract and fixture conform")


if __name__ == "__main__":
    main()
