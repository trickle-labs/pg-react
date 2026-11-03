"""Run the retained-history health query as a fail-closed monitor check."""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


EXPECTED_GUARDS = frozenset({
    "event-trigger/pgre_mdm_history_guard_ddl",
    "mdm_steward.policy_cases_v1/pgreact_mdm_cases_no_truncate",
    "mdm_steward.policy_cases_v1/pgreact_mdm_cases_retention",
    "mdm_steward.policy_receipts_v1/pgreact_mdm_receipts_no_truncate",
    "mdm_steward.policy_receipts_v1/pgreact_mdm_receipts_retention",
    "pgreact_mdm.intent_attempts/intent_attempts_no_truncate",
    "pgreact_mdm.intent_attempts/intent_attempts_retained",
    "pgreact_mdm.intent_case_identities/intent_case_identities_no_truncate",
    "pgreact_mdm.intent_case_identities/intent_case_identities_retained",
    "pgreact_mdm.intent_requests/intent_requests_no_truncate",
    "pgreact_mdm.intent_requests/intent_requests_retained",
    "pgreact_mdm.policy_intent_bindings/intent_bindings_no_truncate",
    "pgreact_mdm.policy_intent_bindings/intent_bindings_retained",
    "function/pgreact_mdm.guard_policy_history_retention()",
    "function/pgreact_mdm.guard_intent_retention_markers()",
    "function/pgreact_mdm.enforce_history_guard_ddl()",
    "function/pgreact_mdm.reject_intent_record_mutation()",
    "role/mdm_retention_guard_owner",
})
QUERY_TIMEOUT_SECONDS = 30


def fail(message, status=2):
    print(message, file=sys.stderr, flush=True)
    return status


def main():
    service = os.environ.get("PGSERVICE")
    if not service:
        return fail("PGSERVICE must name the retention-monitor connection service")

    psql = shutil.which("psql")
    if not psql:
        return fail("psql is required on PATH")

    query = Path(__file__).resolve().parent / "sql" / "retention-guard-health.sql"
    try:
        result = subprocess.run(
            [psql, "-X", "-A", "-t", "-q", "-w", "-v", "ON_ERROR_STOP=1",
             "-f", str(query)],
            check=False,
            capture_output=True,
            text=True,
            timeout=QUERY_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return fail("retention-guard health query exceeded 30 seconds", status=1)

    if result.returncode:
        if result.stderr:
            print(result.stderr.rstrip(), file=sys.stderr)
        return fail("retention-guard health query failed", status=1)

    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError:
        return fail("retention-guard health query did not return one JSON object", status=1)

    guards = report.get("guards") if isinstance(report, dict) else None
    if isinstance(guards, list):
        guard_names = [
            guard.get("guard")
            for guard in guards
            if isinstance(guard, dict)
        ]
    else:
        guard_names = []
    healthy = (
        isinstance(guards, list)
        and len(guards) == len(EXPECTED_GUARDS)
        and all(isinstance(name, str) for name in guard_names)
        and set(guard_names) == EXPECTED_GUARDS
        and report.get("all_healthy") is True
        and all(
            isinstance(guard, dict)
            and isinstance(guard.get("guard"), str)
            and guard.get("healthy") is True
            for guard in guards
        )
    )
    print(json.dumps(report, sort_keys=True), flush=True)
    if not healthy:
        return fail(
            "retention-guard health failed: expected all eighteen named guards healthy",
            status=1,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
