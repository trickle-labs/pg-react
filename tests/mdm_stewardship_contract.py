import hashlib
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = ROOT / "contracts/MDM-STEWARDSHIP-1.json"
FIXTURE_PATH = ROOT / "contracts/MDM-STEWARDSHIP-1-fixture.json"
CONTRACT_SHA256 = "2161ce22b9d924ff3f3e6d8acde62fed01b6b1c1c4d7ba0fd4d5eb6e396e0fcf"
FIXTURE_SHA256 = "900f365533bab13480fcb88ab8e8b7956beb4f14a8cfc92cd46770b2e26ef3e4"


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
    assert contract["status"] == "approved"
    assert contract["approvals"]["pg_mdm_owner"]["status"] == "approved"
    assert contract["approvals"]["pg_mdm_owner"]["role"] == "pg-mdm M0 contract owner"
    assert contract["approvals"]["pg_react_owner"]["status"] == "approved"
    assert contract["approvals"]["pg_react_owner"]["role"] == "pg-react R0 adapter owner"
    assert contract["conformance_fixture"] == {
        "file": FIXTURE_PATH.name,
        "sha256": FIXTURE_SHA256,
    }
    assert contract["shared_conformance_cases"] == fixture["shared_conformance_cases"]

    encoding = contract["canonical_encoding"]
    for domain_key, vector_key in (
        ("policy_domain_tag", "policy_vector"),
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
    assert fixture["intent_vector"]["body"]["expected_policy_digest"] == fixture["policy_vector"]["sha256"]
    assert contract["intent"]["policy_digest"]["owner"].startswith("React computes")
    assert contract["freshness"]["review_version_meaning"].startswith("The exact concurrency_version")
    assert "PENDING_STEWARDSHIP" in contract["freshness"]["pending_stewardship_rule"]
    assert "PENDING_STEWARDSHIP" in contract["intent"]["outcomes"]
    bindings = contract["sql"]["bindings"]
    assert bindings["relation"] == "mdm_steward.policy_bindings_v1"
    assert "mdm_administrator" in bindings["administrator_surface"]["authorization"]
    assert "At most one active binding exists per scope." in bindings["invariants"]
    receipt_columns = contract["sql"]["receipts"]["columns"]
    assert ["actor", "name", "not null; captured from current_user by the invoker-facing wrapper before it calls privileged helpers; caller cannot supply it"] in receipt_columns
    assert contract["intent"]["actor_capture"].startswith("The invoker-facing SQL wrapper captures current_user")
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
