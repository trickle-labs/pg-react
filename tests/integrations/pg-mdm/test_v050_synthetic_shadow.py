#!/usr/bin/env python3
"""Retain a non-qualifying fixed-population shadow rehearsal from real MDM."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

from derive_v050_qualification import _valid_shadow_coverage


POPULATION_ID = "v050-ci-review-admission"
CURRENT_REVISION = "v0.47-upgrade-seed"
PROPOSED_REVISION = "v0.50-synthetic-shadow-proposed"
QUERY = f"""\
WITH snapshot AS (
    SELECT statement_timestamp() AS captured_at
), membership AS (
    SELECT array_agg(input.case_key ORDER BY input.case_key) AS case_keys
    FROM pgreact_mdm.policy_inputs('mdm_steward.policy_cases_v1'::regclass) AS input
    WHERE input.entity_name = 'review_admission_live'
), comparison AS (
    SELECT membership.case_keys,
           pgreact_mdm.compare_population(
               'mdm_steward.policy_cases_v1'::regclass,
               '{CURRENT_REVISION}', '{PROPOSED_REVISION}', snapshot.captured_at,
               jsonb_build_object(
                   'id', '{POPULATION_ID}',
                   'membership', to_jsonb(membership.case_keys),
                   'expected_count', cardinality(membership.case_keys))) AS result
    FROM membership CROSS JOIN snapshot
)
SELECT jsonb_build_object('case_keys', case_keys, 'coverage', result)::text
FROM comparison;
"""


def _run_query(container):
    command = [
        "docker", "exec", "-i", container, "psql", "-XAtq",
        "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "foundation",
    ]
    result = subprocess.run(command, input=QUERY, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"synthetic shadow query failed\n{result.stdout}{result.stderr}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AssertionError(f"synthetic shadow returned invalid JSON: {result.stdout}") from error


def _json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("container", help="populated pg-react image with merged pg-mdm")
    parser.add_argument("--output-directory", type=Path, required=True)
    args = parser.parse_args()

    result = _run_query(args.container)
    if not isinstance(result, dict) or set(result) != {"case_keys", "coverage"}:
        raise AssertionError(f"synthetic shadow output shape mismatch: {result}")
    case_keys = result["case_keys"]
    if (not isinstance(case_keys, list) or not case_keys
            or any(type(key) is not int or key <= 0 for key in case_keys)
            or case_keys != sorted(set(case_keys))):
        raise AssertionError(f"synthetic shadow membership is not a nonempty sorted set: {case_keys}")

    membership = {
        "schema_version": 1,
        "population_id": POPULATION_ID,
        "case_keys": case_keys,
    }
    coverage = result["coverage"]
    valid, observed, duplicates = _valid_shadow_coverage(
        [coverage], membership, [CURRENT_REVISION, PROPOSED_REVISION]
    )
    if not valid or observed != len(case_keys) or duplicates:
        raise AssertionError({
            "valid": valid,
            "observed": observed,
            "duplicates": duplicates,
            "membership": case_keys,
            "coverage": coverage,
        })
    changed_keys = [row["case_key"] for row in coverage["rows"] if row["changed"]]
    if not changed_keys or not any(
        row["proposed"]["route"]["action"] == "ASSIGN_QUEUE"
        and row["proposed"]["route"]["selected_queue"] == "m2-ready"
        for row in coverage["rows"]
    ):
        raise AssertionError(f"proposed package did not demonstrate a changed queue decision: {coverage}")

    args.output_directory.mkdir(parents=True, exist_ok=True)
    membership_bytes = _json_bytes(membership)
    coverage_bytes = _json_bytes([coverage])
    (args.output_directory / "membership.json").write_bytes(membership_bytes)
    (args.output_directory / "coverage.json").write_bytes(coverage_bytes)
    rehearsal = {
        "schema_version": 1,
        "scope": "synthetic-ci-rehearsal",
        "qualification_eligible": False,
        "reason": "synthetic cases do not provide real workload ownership, approval, or release evidence",
        "population_id": POPULATION_ID,
        "membership_sha256": hashlib.sha256(membership_bytes).hexdigest(),
        "coverage_sha256": hashlib.sha256(coverage_bytes).hexdigest(),
        "expected_case_count": len(case_keys),
        "observed_case_count": observed,
        "duplicate_case_count": duplicates,
        "captured_at": coverage["captured_at"],
        "policy_revisions": [CURRENT_REVISION, PROPOSED_REVISION],
        "changed_case_keys": changed_keys,
    }
    (args.output_directory / "rehearsal.json").write_bytes(_json_bytes(rehearsal))
    print(json.dumps(rehearsal, sort_keys=True))


if __name__ == "__main__":
    main()
