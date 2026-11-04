#!/usr/bin/env python3
"""Execute the v0.50 operator queries against real pg-mdm in its empty state."""

import argparse
import hashlib
import json
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from test_v050_operations import EMPTY_EXPECTED, QUERY_NAMES, _docker_psql, _normalize


ROOT = Path(__file__).resolve().parents[3]
EMPTY_SOURCE_EXPECTED = dict(zip(QUERY_NAMES, EMPTY_EXPECTED))
EMPTY_SOURCE_EXPECTED.update({
    "repeated-escalations": [{
        "sampled_case_levels": 0,
        "distinct_requests": 0,
        "same_request_retries": 0,
        "duplicate_applied_levels": 0,
        "sample_state": "NO_SAMPLES",
    }],
    "retention-coverage": [{
        "retained_requests": 0,
        "requests_with_receipt_id": 0,
        "retained_receipts": 0,
        "missing_receipts": 0,
        "coverage_state": "NO_SAMPLES",
        "evidence_version_coverage": "UNAVAILABLE_PUBLICLY",
    }],
})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("container", help="running pg-react image with merged pg-mdm")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    for _ in range(30):
        try:
            react_installed = _docker_psql(
                args.container,
                sql="SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_extension "
                "WHERE extname = 'pg_react');",
            ) == "t"
        except subprocess.CalledProcessError:
            react_installed = False
        if react_installed:
            break
        time.sleep(1)
    else:
        raise AssertionError("pg_react bootstrap extension was not installed")
    try:
        _docker_psql(
            args.container,
            path="/workspace/tests/integrations/pg-mdm/v0.50-real-source-setup.sql",
        )
    except subprocess.CalledProcessError as error:
        raise AssertionError(f"real pg-mdm setup failed: {error.stderr}") from error
    guide = (ROOT / "docs/v0.50.0-operations.md").read_text()
    blocks = re.findall(r"```sql\s*\n(.*?)\n```", guide, re.DOTALL)
    if len(blocks) != len(QUERY_NAMES):
        raise AssertionError(f"expected {len(QUERY_NAMES)} SQL query blocks, found {len(blocks)}")

    variables = (
        ("report_interval", "100 years"),
        ("retention_horizon", "100 years"),
        ("binding_id", "00000000-0000-0000-0000-000000000001"),
        ("adapter_rule_names", "{mdm-route}"),
    )
    results = []
    for name, block in zip(QUERY_NAMES, blocks):
        query = block.strip().removesuffix(";")
        sql = "EXPLAIN (FORMAT JSON, COSTS OFF)\n" + query
        try:
            plan = json.loads(_docker_psql(args.container, sql=sql, variables=variables))
        except subprocess.CalledProcessError as error:
            raise AssertionError(
                f"{name} could not plan against merged pg-mdm: {error.stderr}"
            ) from error
        if (
            not isinstance(plan, list)
            or len(plan) != 1
            or not isinstance(plan[0].get("Plan"), dict)
            or not isinstance(plan[0]["Plan"].get("Node Type"), str)
        ):
            raise AssertionError(f"{name} returned an unexpected PostgreSQL plan: {plan}")
        result_sql = (
            "SELECT coalesce(json_agg(to_jsonb(query_result)), '[]'::json)::text FROM (\n"
            + query
            + "\n) AS query_result;"
        )
        started = datetime.now(timezone.utc)
        try:
            output = _docker_psql(args.container, sql=result_sql, variables=variables)
        except subprocess.CalledProcessError as error:
            raise AssertionError(
                f"{name} could not execute against merged pg-mdm: {error.stderr}"
            ) from error
        finished = datetime.now(timezone.utc)
        raw_actual = json.loads(output)
        actual = _normalize(json.loads(output), started, finished)
        expected = sorted(
            EMPTY_SOURCE_EXPECTED[name], key=lambda row: json.dumps(row, sort_keys=True)
        )
        if actual != expected:
            raise AssertionError(
                f"{name} real-source empty-state output mismatch\n"
                f"expected: {expected}\nactual: {actual}"
            )
        results.append({
            "query": name,
            "plan_status": "passed",
            "empty_state_status": "passed",
            "actual": raw_actual,
        })

    report = {
        "scope": (
            "real pg-mdm source; exact empty-state queries only; no cohort data"
        ),
        "postgresql_version": _docker_psql(
            args.container, sql="SELECT current_setting('server_version');"
        ),
        "pg_mdm_version": _docker_psql(
            args.container,
            sql="SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_mdm';",
        ),
        "pg_react_version": _docker_psql(
            args.container,
            sql="SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_react';",
        ),
        "pg_trickle_version": _docker_psql(
            args.container,
            sql="SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_trickle';",
        ),
        "operations_guide_sha256": hashlib.sha256(guide.encode()).hexdigest(),
        "results": results,
    }
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
