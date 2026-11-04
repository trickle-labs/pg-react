#!/usr/bin/env python3
"""Execute the operator SQL blocks from the v0.50 operations guide."""

import argparse
import hashlib
import json
import re
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
QUERY_NAMES = (
    "stale-intent-rate",
    "denied-invalid-conflict",
    "worker-failures",
    "overdue-open-cases",
    "work-backlog",
    "work-state-counts",
    "held-requests",
    "repeated-escalations",
    "accepted-publication",
    "pending-stewardship",
    "retention-coverage",
)
POPULATED_EXPECTED = (
    [{"stale_or_superseded_attempts": 1, "classified_attempts": 2,
      "stale_intent_rate": 0.5, "sample_state": "SAMPLED"}],
    [
        {"sample_count": 2, "sample_state": "SAMPLED",
         "failure_class": "ACCEPTED_CONTROL_PUBLICATION_OBSERVED",
         "delivery_outcome": "APPLIED_CONTROL", "delivery_reason_code": None,
         "mdm_outcome": "APPLIED_CONTROL", "mdm_reason_code": "CONTROL_APPLIED",
         "attempt_count": 1},
        {"sample_count": 2, "sample_state": "SAMPLED",
         "failure_class": "POLICY_OR_CONFIGURATION", "delivery_outcome": "STALE_CASE",
         "delivery_reason_code": "STALE_CASE", "mdm_outcome": None,
         "mdm_reason_code": None, "attempt_count": 1},
    ],
    [{"sample_count": 1, "sample_state": "SAMPLED",
      "execution_class": "RETRYING_FAILURE", "status": "FAILED",
      "current_work_state": "RETRY_WAIT", "error_code": "WORKER_TIMEOUT",
      "execution_count": 1}],
    [{"eligible_open_cases": 2, "overdue_case_count": 1,
      "overdue_without_pending_work": 1, "oldest_overdue_age": "<one-hour>",
      "captured_at": "<captured-at>", "sample_state": "SAMPLED"}],
    [{"rule_name": "mdm-route", "state": "ACTIVE", "outstanding_episodes": 3,
      "oldest_eligible_at": "2026-11-04T10:00:00+00:00", "failed_episodes": 1,
      "claims_blocked": False, "sample_state": "SAMPLED",
      "captured_at": "<captured-at>"}],
    [
        {"state": "LEASED", "episode_count": 1, "sample_state": "SAMPLED"},
        {"state": "PENDING", "episode_count": 1, "sample_state": "SAMPLED"},
        {"state": "RETRY_WAIT", "episode_count": 1, "sample_state": "SAMPLED"},
    ],
    [{"held_requests": 1, "held_reasons": ["BINDING_PAUSED"],
      "sample_state": "HELD"}],
    [{"sampled_case_levels": 1, "distinct_requests": 1,
      "same_request_retries": 0, "duplicate_applied_levels": 0,
      "sample_state": "SAMPLED"}],
    [{"accepted_control_requests": 1, "oldest_publication_age": None,
      "publication_states": ["PUBLISHED"], "publication_state": "PUBLISHED"}],
    [{"pending_cases": 1, "unknown_age_cases": 0,
      "oldest_pending_age": "<one-hour>", "pending_state": "SAMPLED"}],
    [{"retained_requests": 2, "requests_with_receipt_id": 1,
      "retained_receipts": 1, "missing_receipts": 0,
      "coverage_state": "REQUEST_RECEIPT_COVERED",
      "evidence_version_coverage": "UNAVAILABLE_PUBLICLY"}],
)
EMPTY_EXPECTED = (
    [{"stale_or_superseded_attempts": 0, "classified_attempts": 0,
      "stale_intent_rate": None, "sample_state": "NO_SAMPLES"}],
    [{"sample_count": 0, "sample_state": "NO_SAMPLES", "failure_class": None,
      "delivery_outcome": None, "delivery_reason_code": None, "mdm_outcome": None,
      "mdm_reason_code": None, "attempt_count": 0}],
    [{"sample_count": 0, "sample_state": "NO_SAMPLES", "execution_class": None,
      "status": None, "current_work_state": None, "error_code": None,
      "execution_count": 0}],
    [{"eligible_open_cases": 0, "overdue_case_count": 0,
      "overdue_without_pending_work": 0, "oldest_overdue_age": None,
      "captured_at": None, "sample_state": "NO_ELIGIBLE_CASES"}],
    [{"rule_name": None, "state": None, "outstanding_episodes": None,
      "oldest_eligible_at": None, "failed_episodes": None, "claims_blocked": None,
      "sample_state": "NO_RULE_SAMPLES", "captured_at": "<captured-at>"}],
    [
        {"state": "LEASED", "episode_count": 0, "sample_state": "NO_RULE_SAMPLES"},
        {"state": "PENDING", "episode_count": 0, "sample_state": "NO_RULE_SAMPLES"},
        {"state": "RETRY_WAIT", "episode_count": 0, "sample_state": "NO_RULE_SAMPLES"},
    ],
    [{"held_requests": 0, "held_reasons": [], "sample_state": "ZERO_HELD"}],
    [{"sampled_case_levels": 1, "distinct_requests": 1,
      "same_request_retries": 0, "duplicate_applied_levels": 0,
      "sample_state": "SAMPLED"}],
    [{"accepted_control_requests": 0, "oldest_publication_age": None,
      "publication_states": [], "publication_state": "NO_ACCEPTED_CONTROL_SAMPLES"}],
    [{"pending_cases": 0, "unknown_age_cases": 0,
      "oldest_pending_age": None, "pending_state": "NO_PENDING_CASES"}],
    [{"retained_requests": 1, "requests_with_receipt_id": 0,
      "retained_receipts": 0, "missing_receipts": 0,
      "coverage_state": "NO_RECEIPT_SAMPLES",
      "evidence_version_coverage": "UNAVAILABLE_PUBLICLY"}],
)


def _docker_psql(container, sql=None, path=None, variables=()):
    command = [
        "docker", "exec", "-i", container, "psql", "-XAtq",
        "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres",
    ]
    for name, value in variables:
        command.extend(("-v", f"{name}={value}"))
    if path is not None:
        command.extend(("-f", path))
    result = subprocess.run(command, input=sql, text=True, capture_output=True, check=True)
    return result.stdout.strip()


def _parse_interval(value):
    match = re.fullmatch(r"(?:(\d+) days? )?(\d+):(\d{2}):(\d{2}(?:\.\d+)?)", value)
    if not match:
        raise AssertionError(f"unexpected PostgreSQL interval: {value}")
    days, hours, minutes, seconds = match.groups()
    return timedelta(
        days=int(days or 0), hours=int(hours), minutes=int(minutes), seconds=float(seconds)
    )


def _normalize(rows, started, finished):
    for row in rows:
        for key, value in row.items():
            if key == "captured_at" and value is not None:
                timestamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
                if not started - timedelta(seconds=2) <= timestamp <= finished + timedelta(seconds=2):
                    raise AssertionError(f"captured_at was outside the query interval: {value}")
                row[key] = "<captured-at>"
            elif key in ("oldest_overdue_age", "oldest_pending_age", "oldest_publication_age") and value is not None:
                age = _parse_interval(value)
                if not timedelta(minutes=59) <= age <= timedelta(minutes=61):
                    raise AssertionError(f"expected the seeded one-hour age, got {value}")
                row[key] = "<one-hour>"
            elif key == "oldest_eligible_at" and value is not None:
                row[key] = datetime.fromisoformat(value.replace("Z", "+00:00")).isoformat()
    return sorted(rows, key=lambda row: json.dumps(row, sort_keys=True))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("container", help="running PostgreSQL test container")
    parser.add_argument("--output", type=Path, help="write raw fixture results as JSON")
    args = parser.parse_args()
    container = args.container
    fixture = "/workspace/tests/integrations/pg-mdm/v0.50-operational-activity.sql"
    query_fixture = "/workspace/tests/integrations/pg-mdm/v0.50-operational-queries-fixture.sql"
    _docker_psql(container, path=fixture)
    _docker_psql(container, path=query_fixture)
    guide = (ROOT / "docs/v0.50.0-operations.md").read_text()
    report = {
        "schema_version": 1,
        "scope": "fixture-only; not real MDM qualification",
        "postgresql_version": _docker_psql(
            container, sql="SELECT current_setting('server_version');"
        ),
        "operations_guide_sha256": hashlib.sha256(guide.encode()).hexdigest(),
        "results": [],
    }
    blocks = re.findall(r"```sql\s*\n(.*?)\n```", guide, re.DOTALL)
    if len(blocks) != len(QUERY_NAMES):
        raise AssertionError(f"expected {len(QUERY_NAMES)} SQL query blocks, found {len(blocks)}")

    scenarios = (
        ("populated", POPULATED_EXPECTED, "00000000-0000-0000-0000-000000000001", "{mdm-route}"),
        ("empty", EMPTY_EXPECTED, "00000000-0000-0000-0000-000000000002", "{missing-rule}"),
    )
    for scenario, expectations, binding_id, rule_names in scenarios:
        for name, block, expected in zip(QUERY_NAMES, blocks, expectations):
            sql = (
                "SELECT coalesce(json_agg(to_jsonb(query_result)), '[]'::json)::text FROM (\n"
                + block.strip().removesuffix(";")
                + "\n) AS query_result;"
            )
            variables = (
                ("report_interval", "100 years"),
                ("retention_horizon", "100 years"),
                ("binding_id", binding_id),
                ("adapter_rule_names", rule_names),
            )
            started = datetime.now(timezone.utc)
            output = _docker_psql(container, sql=sql, variables=variables)
            finished = datetime.now(timezone.utc)
            raw_actual = json.loads(output)
            actual = _normalize(json.loads(output), started, finished)
            expected = sorted(expected, key=lambda row: json.dumps(row, sort_keys=True))
            if actual != expected:
                raise AssertionError(
                    f"{scenario} {name} output mismatch\nexpected: {expected}\nactual: {actual}"
                )
            report["results"].append({
                "scenario": scenario,
                "query": name,
                "status": "passed",
                "actual": raw_actual,
            })
    _docker_psql(container, sql=(
        "DELETE FROM mdm_steward.policy_receipt_publications_v1; "
        "UPDATE mdm_steward.policy_receipts_v1 "
        "SET created_at = clock_timestamp() - interval '1 hour' "
        "WHERE receipt_id = '10000000-0000-0000-0000-000000000001'; "
        "INSERT INTO pgreact_mdm.intent_attempts "
        "SELECT episode_id, 2, binding_id, request_key, clock_timestamp(), "
        "outcome, reason_code, receipt_id "
        "FROM pgreact_mdm.intent_attempts WHERE outcome = 'APPLIED_CONTROL';"
    ))
    publication_query = blocks[QUERY_NAMES.index("accepted-publication")]
    publication_sql = (
        "SELECT coalesce(json_agg(to_jsonb(query_result)), '[]'::json)::text FROM (\n"
        + publication_query.strip().removesuffix(";")
        + "\n) AS query_result;"
    )
    started = datetime.now(timezone.utc)
    output = _docker_psql(
        container,
        sql=publication_sql,
        variables=(
            ("report_interval", "100 years"),
            ("retention_horizon", "100 years"),
            ("binding_id", "00000000-0000-0000-0000-000000000001"),
            ("adapter_rule_names", "{mdm-route}"),
        ),
    )
    finished = datetime.now(timezone.utc)
    duplicate_retry_actual = _normalize(json.loads(output), started, finished)
    duplicate_retry_expected = [{
        "accepted_control_requests": 1,
        "oldest_publication_age": "<one-hour>",
        "publication_states": ["PENDING_PUBLICATION"],
        "publication_state": "PENDING_PUBLICATION",
    }]
    if duplicate_retry_actual != duplicate_retry_expected:
        raise AssertionError(
            "accepted-publication retry output mismatch\n"
            f"expected: {duplicate_retry_expected}\nactual: {duplicate_retry_actual}"
        )
    report["results"].append({
        "scenario": "duplicate-pending-retry",
        "query": "accepted-publication",
        "status": "passed",
        "actual": json.loads(output),
    })
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"{len(QUERY_NAMES)} documented queries match populated and empty-state outputs; pending retry count is exact")


if __name__ == "__main__":
    main()
