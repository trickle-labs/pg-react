#!/usr/bin/env python3
"""Plan the v0.50 query pack against the merged pg-mdm extension schema."""

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

from test_v050_operations import QUERY_NAMES, _docker_psql


ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("container", help="running pg-react image with merged pg-mdm")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
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
    planned = []
    for name, block in zip(QUERY_NAMES, blocks):
        sql = "EXPLAIN (FORMAT JSON, COSTS OFF)\n" + block.strip().removesuffix(";")
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
        planned.append({"query": name, "status": "planned"})

    report = {
        "scope": (
            "schema-only smoke; the extension source is real and the database has no cohort data"
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
        "results": planned,
    }
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
