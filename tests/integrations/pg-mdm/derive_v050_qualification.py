#!/usr/bin/env python3
"""Derive the v0.50 release decision from its artifact tuple and required gates."""

import argparse
import hashlib
import json
import math
import re
from datetime import datetime
from pathlib import Path


ARTIFACT_FIELDS = (
    "postgresql_version",
    "runtime_image_digest",
    "pg_react_version",
    "pg_react_source_commit",
    "pg_react_shared_library_sha256",
    "pg_trickle_version",
    "pg_trickle_source_commit",
    "pg_trickle_shared_library_sha256",
    "pg_mdm_version",
    "pg_mdm_source_commit",
    "pg_mdm_source_archive_sha256",
    "pg_mdm_shared_library_sha256",
    "mdm_contract_digest",
    "public_projection_digest",
    "adapter_package_digest",
    "platform",
    "isolation",
    "cdc",
    "coordinator_owner",
    "temporal_configuration",
    "capability_response",
)
GATE_IDS = tuple([f"R{number}" for number in range(1, 9)] + [f"C{number:02}" for number in range(1, 13)])
GATE_STATUSES = {"passed", "failed", "blocked", "not_run", "skipped"}
DIGEST_FIELDS = (
    "runtime_image_digest",
    "pg_react_shared_library_sha256",
    "pg_trickle_shared_library_sha256",
    "pg_mdm_source_archive_sha256",
    "pg_mdm_shared_library_sha256",
    "mdm_contract_digest",
    "public_projection_digest",
    "adapter_package_digest",
)
COMMIT_FIELDS = ("pg_react_source_commit", "pg_trickle_source_commit", "pg_mdm_source_commit")
OBJECT_FIELDS = ("temporal_configuration", "capability_response")
RECORD_FIELDS = (
    "workload.id",
    "workload.owner",
    "workload.administrative_domain",
    "cohort.membership_definition",
    "cohort.membership_manifest",
    "cohort.membership_sha256",
    "cohort.member_count",
    "cohort.policy_revisions",
    "cohort.expected_exceptions",
    "cohort.package_manifest",
    "cohort.package_digest",
    "shadow.reference_population_sha256",
    "shadow.coverage_manifest",
    "shadow.expected_case_count",
    "shadow.observed_case_count",
    "shadow.partial",
    "shadow.duplicate_case_count",
    "shadow.owner_approval",
    "operating_envelope.baseline_evidence",
    "operating_envelope.thresholds.case_count_max",
    "operating_envelope.thresholds.churn_per_hour_max",
    "operating_envelope.thresholds.queue_backlog_max",
    "operating_envelope.thresholds.latency_p95_ms_max",
    "operating_envelope.thresholds.retention_horizon_seconds",
    "operating_envelope.thresholds.recovery_rto_seconds_max",
    "operating_envelope.observation.started_at",
    "operating_envelope.observation.ended_at",
    "operating_envelope.operator_threshold_approval",
    "operating_envelope.release_owner_threshold_approval",
    "support_documents.release_notes",
    "support_documents.support_matrix",
    "support_documents.operator_guide",
    "final_signoffs.operator",
    "final_signoffs.release_owner",
    "final_signoffs.independent_reviewer",
)
LIMIT_FIELDS = (
    "operating_envelope.thresholds.case_count_max",
    "operating_envelope.thresholds.churn_per_hour_max",
    "operating_envelope.thresholds.queue_backlog_max",
    "operating_envelope.thresholds.latency_p95_ms_max",
    "operating_envelope.thresholds.retention_horizon_seconds",
    "operating_envelope.thresholds.recovery_rto_seconds_max",
)
TEXT_FIELDS = tuple(
    field for field in ARTIFACT_FIELDS
    if field not in DIGEST_FIELDS + COMMIT_FIELDS + OBJECT_FIELDS
)
SHADOW_ROUTE_FIELDS = {
    "decision", "current_queue", "selected_queue", "action", "priority", "reason_code",
    "competitors", "reason", "applicable", "manual_assignment_protected",
    "pending_stewardship", "due_at", "deadline_due", "current_escalation_level",
    "requested_escalation_level",
}
SHADOW_DEADLINE_FIELDS = {"decision", "existing_due_at", "proposed_due_at", "reason"}
ROUTE_DECISIONS = {"WINNER", "AMBIGUOUS", "NO_CANDIDATE", "NO_OP", "PROTECTED", "INELIGIBLE"}
DEADLINE_DECISIONS = {"INELIGIBLE", "OPENED_AT_UNKNOWN", "PRESERVED", "PROPOSED", "REPLACEMENT"}


def _present(value):
    return value is not None and value != "" and value != {} and value != []


def _verify_evidence(reference, manifest_directory, gate_id, index):
    label = f"{gate_id} evidence[{index}]"
    if not isinstance(reference, dict) or set(reference) != {"path", "sha256"}:
        return f"{label} must contain exactly path and sha256"
    path = reference["path"]
    digest = reference["sha256"]
    if not isinstance(path, str) or not path or Path(path).is_absolute() or ".." in Path(path).parts:
        return f"{label} path must be a relative path inside the manifest directory"
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        return f"{label} sha256 is invalid"
    if manifest_directory is None:
        return f"{label} cannot be checked without the manifest directory"
    root = Path(manifest_directory).resolve()
    try:
        retained_file = (root / path).resolve(strict=True)
        retained_file.relative_to(root)
    except (OSError, ValueError):
        return f"{label} file is missing or outside the manifest directory"
    if not retained_file.is_file():
        return f"{label} is not a file"
    hasher = hashlib.sha256()
    with retained_file.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    if hasher.hexdigest() != digest:
        return f"{label} sha256 does not match the retained file"
    return None


def _read_json_evidence(reference, manifest_directory, label):
    error = _verify_evidence(reference, manifest_directory, label, 0)
    if error:
        return None, error
    path = (Path(manifest_directory).resolve() / reference["path"]).resolve()
    try:
        return json.loads(path.read_text()), None
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None, f"{label} must contain valid JSON"


def _valid_case_keys(value):
    return (
        isinstance(value, list)
        and all(type(key) is int and 0 < key <= 9223372036854775807 for key in value)
        and len(value) == len(set(value))
    )


def _valid_shadow_competitors(value):
    if not isinstance(value, list):
        return False
    base_fields = {"reason_code", "entity_name", "queue", "priority", "action"}
    for candidate in value:
        if (not isinstance(candidate, dict)
                or set(candidate) not in (base_fields, base_fields | {"level"})
                or not isinstance(candidate["reason_code"], str)
                or any(candidate[key] is not None and not isinstance(candidate[key], str)
                       for key in ("entity_name", "queue"))
                or type(candidate["priority"]) is not int
                or not isinstance(candidate["action"], str)
                or candidate["action"] not in {"ASSIGN_QUEUE", "ESCALATE"}
                or (candidate["action"] == "ESCALATE") != ("level" in candidate)
                or "level" in candidate and (
                    type(candidate["level"]) is not int or candidate["level"] < 1
                )):
            return False
    return True


def _valid_shadow_coverage(coverage_manifest, membership, revisions):
    if not isinstance(coverage_manifest, list) or not coverage_manifest:
        return False, 0, 0
    expected_keys = set(membership["case_keys"])
    seen_members = set()
    seen_rows = []
    captured_at = None
    for result in coverage_manifest:
        if not isinstance(result, dict) or set(result) != {
            "state", "read_only", "captured_at", "policy_revisions", "coverage", "rows"
        }:
            return False, len(seen_rows), len(seen_rows) - len(set(seen_rows))
        timestamp = _record_timestamp(result["captured_at"])
        policy_pair = result["policy_revisions"]
        coverage = result["coverage"]
        rows = result["rows"]
        if (result["state"] != "complete" or result["read_only"] is not True
                or timestamp is None or (captured_at is not None and timestamp != captured_at)
                or not isinstance(policy_pair, dict)
                or set(policy_pair) != {"current", "proposed"}
                or any(not isinstance(policy_pair[key], str) or policy_pair[key] not in revisions
                       for key in ("current", "proposed"))
                or not isinstance(coverage, dict)
                or set(coverage) != {
                    "population_id", "membership", "expected_count", "observed_count",
                    "partial", "snapshot"
                }
                or coverage["population_id"] != membership["population_id"]
                or not _valid_case_keys(coverage["membership"])
                or not isinstance(rows, list)):
            return False, len(seen_rows), len(seen_rows) - len(set(seen_rows))
        captured_at = timestamp
        member_keys = coverage["membership"]
        row_keys = []
        for row in rows:
            if (not isinstance(row, dict) or set(row) != {"case_key", "current", "proposed", "changed"}
                    or type(row["case_key"]) is not int
                    or not 0 < row["case_key"] <= 9223372036854775807
                    or type(row["changed"]) is not bool
                    or row["changed"] != (row["current"] != row["proposed"])):
                return False, len(seen_rows), len(seen_rows) - len(set(seen_rows))
            for side in ("current", "proposed"):
                value = row[side]
                if not isinstance(value, dict) or set(value) != {"route", "deadline"}:
                    return False, len(seen_rows), len(seen_rows) - len(set(seen_rows))
                route, deadline = value["route"], value["deadline"]
                if (not isinstance(route, dict) or set(route) != SHADOW_ROUTE_FIELDS
                        or not isinstance(route["decision"], str)
                        or route["decision"] not in ROUTE_DECISIONS
                        or any(route[key] is not None and not isinstance(route[key], str)
                               for key in ("current_queue", "selected_queue", "action", "reason_code"))
                        or route["priority"] is not None and type(route["priority"]) is not int
                        or not _valid_shadow_competitors(route["competitors"])
                        or not isinstance(route["reason"], str)
                        or route["action"] not in {None, "ASSIGN_QUEUE", "ESCALATE"}
                        or any(type(route[key]) is not bool for key in (
                            "applicable", "manual_assignment_protected", "pending_stewardship",
                            "deadline_due"))
                        or any(route[key] is not None and type(route[key]) is not int
                               for key in ("current_escalation_level", "requested_escalation_level"))
                        or route["due_at"] is not None and _record_timestamp(route["due_at"]) is None
                        or not isinstance(deadline, dict) or set(deadline) != SHADOW_DEADLINE_FIELDS
                        or not isinstance(deadline["decision"], str)
                        or deadline["decision"] not in DEADLINE_DECISIONS
                        or any(deadline[key] is not None and _record_timestamp(deadline[key]) is None
                               for key in ("existing_due_at", "proposed_due_at"))
                        or not isinstance(deadline["reason"], str)):
                    return False, len(seen_rows), len(seen_rows) - len(set(seen_rows))
            row_keys.append(row["case_key"])
        if (type(coverage["expected_count"]) is not int
                or coverage["expected_count"] != len(member_keys)
                or type(coverage["observed_count"]) is not int
                or coverage["observed_count"] != len(row_keys)
                or coverage["partial"] is not False
                or coverage["snapshot"] != "one READ COMMITTED statement per read"
                or len(row_keys) != len(set(row_keys))
                or set(row_keys) != set(member_keys)
                or seen_members.intersection(member_keys)):
            all_rows = seen_rows + row_keys
            return False, len(all_rows), len(all_rows) - len(set(all_rows))
        seen_members.update(member_keys)
        seen_rows.extend(row_keys)
    duplicates = len(seen_rows) - len(set(seen_rows))
    return seen_members == expected_keys and set(seen_rows) == expected_keys, len(seen_rows), duplicates


def _record_value(record, dotted_path):
    value = record
    for field in dotted_path.split("."):
        if not isinstance(value, dict):
            return None
        value = value.get(field)
    return value


def _record_timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else None


def _approval_errors(value, label, manifest_directory):
    if not isinstance(value, dict) or set(value) != {"name", "signed_at", "evidence"}:
        return [f"{label} must contain exactly name, signed_at, and evidence"]
    errors = []
    if not isinstance(value["name"], str) or not value["name"]:
        errors.append(f"{label} name is invalid")
    if _record_timestamp(value["signed_at"]) is None:
        errors.append(f"{label} signed_at must be a timezone-aware timestamp")
    error = _verify_evidence(value["evidence"], manifest_directory, label, 0)
    if error:
        errors.append(error)
    return errors


def _validate_release_record(manifest, manifest_directory):
    record = manifest.get("release_record")
    if not isinstance(record, dict):
        record = {}
    missing = [field for field in RECORD_FIELDS if not _present(_record_value(record, field))]
    invalid = []

    for field in (
        "cohort.membership_sha256",
        "cohort.package_digest",
        "shadow.reference_population_sha256",
    ):
        value = _record_value(record, field)
        if _present(value) and (
            not isinstance(value, str)
            or not re.fullmatch(r"[0-9a-f]{64}", value)
        ):
            invalid.append(field)
    for field in (
        "workload.id",
        "workload.owner",
        "workload.administrative_domain",
        "cohort.membership_definition",
    ):
        value = _record_value(record, field)
        if _present(value) and (not isinstance(value, str) or not value.strip()):
            invalid.append(field)

    for field in ("cohort.member_count", "shadow.expected_case_count"):
        value = _record_value(record, field)
        if _present(value) and (type(value) is not int or value <= 0):
            invalid.append(field)
    for field in ("shadow.observed_case_count", "shadow.duplicate_case_count"):
        value = _record_value(record, field)
        if _present(value) and (type(value) is not int or value < 0):
            invalid.append(field)
    revisions = _record_value(record, "cohort.policy_revisions")
    if _present(revisions) and (
        not isinstance(revisions, list)
        or not revisions
        or any(not isinstance(item, str) or not item for item in revisions)
    ):
        invalid.append("cohort.policy_revisions")

    membership = _record_value(record, "cohort.membership_manifest")
    membership_digest = _record_value(record, "cohort.membership_sha256")
    if (isinstance(membership, dict) and isinstance(membership_digest, str)
            and membership.get("sha256") != membership_digest):
        invalid.append("cohort.membership_sha256")
    package = _record_value(record, "cohort.package_manifest")
    package_digest = _record_value(record, "cohort.package_digest")
    if isinstance(package, dict) and isinstance(package_digest, str) and package.get("sha256") != package_digest:
        invalid.append("cohort.package_digest")

    membership_data = None
    membership_error = None
    if _present(membership):
        membership_data, membership_error = _read_json_evidence(
            membership, manifest_directory, "cohort.membership_manifest"
        )
    if membership_error:
        invalid.append(membership_error)
    elif membership_data is None and _present(membership):
        invalid.append("cohort.membership_manifest")
    if membership_data is not None:
        if (not isinstance(membership_data, dict)
                or set(membership_data) != {"schema_version", "population_id", "case_keys"}
                or type(membership_data.get("schema_version")) is not int
                or membership_data["schema_version"] != 1
                or not isinstance(membership_data.get("population_id"), str)
                or not membership_data["population_id"].strip()
                or not _valid_case_keys(membership_data.get("case_keys"))
                or membership_data.get("case_keys") != sorted(membership_data.get("case_keys", []))):
            invalid.append("cohort.membership_manifest")
            membership_data = None
        else:
            member_count = _record_value(record, "cohort.member_count")
            if _present(member_count) and member_count != len(membership_data["case_keys"]):
                invalid.append("cohort.member_count")
            if _record_value(record, "shadow.reference_population_sha256") != membership_digest:
                invalid.append("shadow.reference_population_sha256")

    coverage_data = None
    coverage_reference = _record_value(record, "shadow.coverage_manifest")
    if _present(coverage_reference):
        coverage_data, coverage_error = _read_json_evidence(
            coverage_reference, manifest_directory, "shadow.coverage_manifest"
        )
        if coverage_error:
            invalid.append(coverage_error)
        elif coverage_data is None:
            invalid.append("shadow.coverage_manifest")
    if membership_data is not None and coverage_data is not None:
        valid, actual_count, actual_duplicates = _valid_shadow_coverage(
            coverage_data, membership_data, revisions if isinstance(revisions, list) else []
        )
        if not valid:
            invalid.append("shadow.coverage_manifest")
        if _present(_record_value(record, "shadow.expected_case_count")) and (
            _record_value(record, "shadow.expected_case_count") != len(membership_data["case_keys"])
        ):
            invalid.append("shadow.expected_case_count")
        if _present(_record_value(record, "shadow.observed_case_count")) and (
            _record_value(record, "shadow.observed_case_count") != actual_count
        ):
            invalid.append("shadow.observed_case_count")
        if _present(_record_value(record, "shadow.duplicate_case_count")) and (
            _record_value(record, "shadow.duplicate_case_count") != actual_duplicates
        ):
            invalid.append("shadow.duplicate_case_count")
        if _present(_record_value(record, "shadow.partial")) and (
            _record_value(record, "shadow.partial") is not False
        ):
            invalid.append("shadow.partial")

    expected = _record_value(record, "shadow.expected_case_count")
    observed = _record_value(record, "shadow.observed_case_count")
    partial = _record_value(record, "shadow.partial")
    duplicates = _record_value(record, "shadow.duplicate_case_count")
    if _present(expected) and _present(observed) and expected != observed:
        invalid.append("shadow.observed_case_count")
    if _present(partial) and partial is not False:
        invalid.append("shadow.partial")
    if _present(duplicates) and duplicates != 0:
        invalid.append("shadow.duplicate_case_count")

    for field in LIMIT_FIELDS:
        value = _record_value(record, field)
        if _present(value) and (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
            or value < 0
        ):
            invalid.append(field)
    for field in (
        "operating_envelope.thresholds.case_count_max",
        "operating_envelope.thresholds.queue_backlog_max",
    ):
        value = _record_value(record, field)
        if _present(value) and type(value) is not int:
            invalid.append(field)

    start = _record_timestamp(_record_value(record, "operating_envelope.observation.started_at"))
    end = _record_timestamp(_record_value(record, "operating_envelope.observation.ended_at"))
    for field, timestamp in (
        ("operating_envelope.observation.started_at", start),
        ("operating_envelope.observation.ended_at", end),
    ):
        if _present(_record_value(record, field)) and timestamp is None:
            invalid.append(field)
    if start is not None and end is not None and end <= start:
        invalid.append("operating_envelope.observation")

    evidence_fields = (
        "cohort.membership_manifest",
        "cohort.package_manifest",
        "cohort.expected_exceptions",
        "shadow.coverage_manifest",
        "operating_envelope.baseline_evidence",
    )
    for field in evidence_fields:
        value = _record_value(record, field)
        if _present(value):
            error = _verify_evidence(value, manifest_directory, field, 0)
            if error:
                invalid.append(error)

    for field in (
        "shadow.owner_approval",
        "operating_envelope.operator_threshold_approval",
        "operating_envelope.release_owner_threshold_approval",
    ):
        value = _record_value(record, field)
        if _present(value):
            invalid.extend(_approval_errors(value, field, manifest_directory))

    for field in ("release_notes", "support_matrix", "operator_guide"):
        value = _record_value(record, f"support_documents.{field}")
        if _present(value):
            if not isinstance(value, str) or not value.startswith("docs/") or ".." in Path(value).parts:
                invalid.append(f"support_documents.{field}")
            elif not (Path(__file__).resolve().parents[3] / value).is_file():
                invalid.append(f"support_documents.{field}")

    signoffs = _record_value(record, "final_signoffs")
    signer_names = []
    for field in ("operator", "release_owner", "independent_reviewer"):
        value = _record_value(record, f"final_signoffs.{field}")
        if _present(value):
            invalid.extend(_approval_errors(value, f"final_signoffs.{field}", manifest_directory))
            if isinstance(value, dict) and isinstance(value.get("name"), str):
                signer_names.append(value["name"])
    if len(signer_names) == 3 and len(set(signer_names)) != 3:
        invalid.append("final_signoffs must name three distinct reviewers")

    return missing, list(dict.fromkeys(invalid))


def derive(manifest, manifest_directory=None):
    errors = []
    if not isinstance(manifest, dict):
        return {
            "release_qualified": False,
            "artifact_tuple_complete": False,
            "missing_artifact_fields": list(ARTIFACT_FIELDS),
            "invalid_artifact_fields": [],
            "blocking_gates": list(GATE_IDS),
            "manifest_errors": ["manifest must be an object"],
            "missing_release_fields": list(RECORD_FIELDS),
            "invalid_release_fields": [],
            "release_record_complete": False,
        }
    artifact_tuple = manifest.get("artifact_tuple")
    if not isinstance(artifact_tuple, dict):
        errors.append("artifact_tuple must be an object")
        artifact_tuple = {}
    missing_artifact_fields = [
        field for field in ARTIFACT_FIELDS if not _present(artifact_tuple.get(field))
    ]
    invalid_artifact_fields = []
    for field in TEXT_FIELDS:
        value = artifact_tuple.get(field)
        if _present(value) and not isinstance(value, str):
            invalid_artifact_fields.append(field)
        elif field == "coordinator_owner" and _present(value) and value != "pg-react":
            invalid_artifact_fields.append(field)
    for field in DIGEST_FIELDS:
        value = artifact_tuple.get(field)
        if _present(value) and (
            not isinstance(value, str)
            or not re.fullmatch(r"(?:sha256:)?[0-9a-f]{64}", value)
        ):
            invalid_artifact_fields.append(field)
    for field in COMMIT_FIELDS:
        value = artifact_tuple.get(field)
        if _present(value) and (
            not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value)
        ):
            invalid_artifact_fields.append(field)
    for field in OBJECT_FIELDS:
        value = artifact_tuple.get(field)
        if _present(value) and not isinstance(value, dict):
            invalid_artifact_fields.append(field)

    gates = manifest.get("gates")
    if not isinstance(gates, list):
        errors.append("gates must be an array")
        gates = []
    gate_map = {}
    duplicates = set()
    for gate in gates:
        if not isinstance(gate, dict) or not isinstance(gate.get("id"), str):
            errors.append("each gate must have a string id")
            continue
        gate_id = gate["id"]
        if gate_id in gate_map:
            duplicates.add(gate_id)
        gate_map[gate_id] = gate
        if gate.get("status") not in GATE_STATUSES:
            errors.append(f"{gate_id} has an invalid status")
        if gate.get("required") is not True:
            errors.append(f"{gate_id} must remain required")
    if duplicates:
        errors.append("duplicate gate ids: " + ", ".join(sorted(duplicates)))
    unknown = sorted(set(gate_map) - set(GATE_IDS))
    if unknown:
        errors.append("unknown gate ids: " + ", ".join(unknown))

    blocking_gates = []
    for gate_id in GATE_IDS:
        gate = gate_map.get(gate_id)
        evidence = gate.get("evidence") if gate else None
        evidence_valid = isinstance(evidence, list) and bool(evidence)
        if evidence_valid:
            for index, reference in enumerate(evidence):
                error = _verify_evidence(reference, manifest_directory, gate_id, index)
                if error:
                    errors.append(error)
                    evidence_valid = False
        if (not gate or gate.get("status") != "passed"
                or not evidence_valid):
            blocking_gates.append(gate_id)

    if manifest.get("schema_version") != 1:
        errors.append("schema_version must be 1")
    if manifest.get("release") != "pg-react MDM adapter 0.50.0":
        errors.append("release must identify pg-react MDM adapter 0.50.0")

    missing_release_fields, invalid_release_fields = _validate_release_record(
        manifest, manifest_directory
    )

    return {
        "release_qualified": (
            not missing_artifact_fields
            and not invalid_artifact_fields
            and not blocking_gates
            and not errors
            and not missing_release_fields
            and not invalid_release_fields
        ),
        "artifact_tuple_complete": not missing_artifact_fields and not invalid_artifact_fields,
        "missing_artifact_fields": missing_artifact_fields,
        "invalid_artifact_fields": invalid_artifact_fields,
        "blocking_gates": blocking_gates,
        "manifest_errors": errors,
        "missing_release_fields": missing_release_fields,
        "invalid_release_fields": invalid_release_fields,
        "release_record_complete": not missing_release_fields and not invalid_release_fields,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "manifest",
        nargs="?",
        type=Path,
        default=Path(__file__).parent / "evidence/v0.50.0/manifest.json",
    )
    parser.add_argument("--require-qualified", action="store_true")
    args = parser.parse_args()
    result = derive(json.loads(args.manifest.read_text()), args.manifest.parent)
    print(json.dumps(result, indent=2, sort_keys=True))
    if result["manifest_errors"]:
        raise SystemExit(2)
    if args.require_qualified and not result["release_qualified"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
