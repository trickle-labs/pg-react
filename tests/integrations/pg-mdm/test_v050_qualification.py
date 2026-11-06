#!/usr/bin/env python3
import copy
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


HERE = Path(__file__).parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
from derive_v050_qualification import (
    ARTIFACT_FIELDS,
    COMMIT_FIELDS,
    DIGEST_FIELDS,
    GATE_IDS,
    OBJECT_FIELDS,
    RECORD_FIELDS,
    _valid_shadow_competitors,
    derive,
)


def complete_manifest(evidence_directory):
    artifact_tuple = {field: "qualified-value" for field in ARTIFACT_FIELDS}
    for field in DIGEST_FIELDS:
        artifact_tuple[field] = "a" * 64
    artifact_tuple["runtime_image_digest"] = "sha256:" + "a" * 64
    for field in COMMIT_FIELDS:
        artifact_tuple[field] = "b" * 40
    for field in OBJECT_FIELDS:
        artifact_tuple[field] = {"qualified": True}
    artifact_tuple["coordinator_owner"] = "pg-react"
    evidence_dir = evidence_directory / "logs"
    evidence_dir.mkdir(exist_ok=True)
    gates = []
    evidence_references = {}
    for gate_id in GATE_IDS:
        path = f"logs/{gate_id}.log"
        content = f"retained evidence for {gate_id}\n".encode()
        (evidence_directory / path).write_bytes(content)
        reference = {"path": path, "sha256": hashlib.sha256(content).hexdigest()}
        evidence_references[gate_id] = reference
        gates.append({
            "id": gate_id,
            "required": True,
            "status": "passed",
            "evidence": [reference],
        })
    baseline_reference = None
    thresholds = None

    def approval(name, gate_id):
        signed_at = (
            "2026-11-05T00:00:00Z" if gate_id == "R8" else "2026-10-24T10:00:00+00:00"
        )
        reference = evidence_references[gate_id]
        if gate_id == "R6":
            role = "operator" if name == "operator" else "release_owner"
            reference = retain_json(f"approval-{role}", {
                "schema_version": 1,
                "role": role,
                "approver": name,
                "signed_at": signed_at,
                "baseline_sha256": baseline_reference["sha256"],
                "thresholds": thresholds,
            })
        return {
            "name": name,
            "signed_at": signed_at,
            "evidence": reference,
        }

    def retain_json(name, value):
        path = f"logs/{name}.json"
        content = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        (evidence_directory / path).write_bytes(content)
        return {"path": path, "sha256": hashlib.sha256(content).hexdigest()}

    case_keys = list(range(1, 101))
    membership = retain_json("membership", {
        "schema_version": 1,
        "population_id": "cohort-1",
        "case_keys": case_keys,
    })
    current = {
        "route": {
            "decision": "WINNER",
            "current_queue": "general",
            "selected_queue": None,
            "action": "ESCALATE",
            "priority": 1,
            "reason_code": "POSSIBLE_DUPLICATE",
            "competitors": [{
                "reason_code": "POSSIBLE_DUPLICATE",
                "entity_name": "domain-1",
                "queue": None,
                "priority": 1,
                "action": "ESCALATE",
                "level": 1,
            }],
            "reason": "best allowed candidate",
            "applicable": True,
            "manual_assignment_protected": True,
            "pending_stewardship": False,
            "due_at": "2026-11-04T10:00:00+00:00",
            "deadline_due": True,
            "current_escalation_level": 0,
            "requested_escalation_level": 1,
        },
        "deadline": {
            "decision": "PRESERVED",
            "existing_due_at": "2026-11-04T10:00:00+00:00",
            "proposed_due_at": None,
            "reason": "existing deadline is preserved",
        },
    }
    proposed = copy.deepcopy(current)
    coverage = retain_json("coverage", [{
        "state": "complete",
        "read_only": True,
        "captured_at": "2026-11-04T10:00:00+00:00",
        "policy_revisions": {"current": "policy-r1", "proposed": "policy-r2"},
        "coverage": {
            "population_id": "cohort-1",
            "membership": case_keys,
            "expected_count": len(case_keys),
            "observed_count": len(case_keys),
            "partial": False,
            "snapshot": "one READ COMMITTED statement per read",
        },
        "rows": [
            {"case_key": key, "current": current, "proposed": proposed, "changed": False}
            for key in case_keys
        ],
    }])
    package_content = b"retained adapter package artifact\n"
    package_path = "logs/adapter-package.bin"
    (evidence_directory / package_path).write_bytes(package_content)
    package = {"path": package_path, "sha256": hashlib.sha256(package_content).hexdigest()}
    thresholds = {
        "case_count_max": 100,
        "churn_per_hour_max": 20,
        "queue_backlog_max": 50,
        "latency_p95_ms_max": 2000,
        "retention_horizon_seconds": 7776000,
        "recovery_rto_seconds_max": 3600,
    }
    artifact_tuple_sha256 = hashlib.sha256(
        json.dumps(artifact_tuple, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()

    def operating_run(run_id, started_at, ended_at):
        return {
            "schema_version": 1,
            "run_id": run_id,
            "workload_id": "workload-1",
            "cohort_membership_sha256": membership["sha256"],
            "artifact_tuple_sha256": artifact_tuple_sha256,
            "started_at": started_at,
            "ended_at": ended_at,
            "truncated": False,
            "safety_degraded": False,
            "scenarios": {
                scenario: {
                    "conditions": f"synthetic {scenario.replace('_', ' ')} profile",
                    "database_writes": 100,
                    "wal_bytes": 2048,
                    "storage_bytes": 4096,
                    **(
                        {"recovery_rto_seconds": 1800}
                        if scenario in {"restart", "populated_restore"} else {}
                    ),
                    **({"drain_duration_seconds": 60} if scenario == "backlog_drain" else {}),
                }
                for scenario in (
                    "no_change_cycles", "bursts", "hot_case_conflicts",
                    "stale_token_churn", "deadline_bursts", "backlog_drain",
                    "restart", "populated_restore",
                )
            },
            "summary": {
                "case_count": 100,
                "churn_per_hour": 10,
                "queue_backlog": 25,
                "latency_p95_ms": 1000,
                "retention_horizon_seconds": 7776000,
                "recovery_rto_seconds": 1800,
            },
            "unavailable_metrics": [],
        }

    baseline_reference = retain_json("baseline", operating_run(
        "baseline-1", "2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z"
    ))
    final_reference = retain_json("final-operating-run", operating_run(
        "final-1", "2026-11-01T00:00:00Z", "2026-11-04T00:00:00Z"
    ))
    next(gate for gate in gates if gate["id"] == "R6")["evidence"] = [
        final_reference, evidence_references["R6"]
    ]
    return {
        "schema_version": 1,
        "release": "pg-react MDM adapter 0.50.0",
        "artifact_tuple": artifact_tuple,
        "release_record": {
            "workload": {"id": "workload-1", "owner": "owner", "administrative_domain": "domain-1"},
            "cohort": {
                "membership_definition": "case_key in the frozen membership manifest",
                "membership_manifest": membership,
                "membership_sha256": membership["sha256"],
                "member_count": 100,
                "policy_revisions": ["policy-r1", "policy-r2"],
                "expected_exceptions": evidence_references["R3"],
                "package_manifest": package,
                "package_digest": package["sha256"],
            },
            "shadow": {
                "reference_population_sha256": membership["sha256"],
                "coverage_manifest": coverage,
                "expected_case_count": 100,
                "observed_case_count": 100,
                "partial": False,
                "duplicate_case_count": 0,
                "owner_approval": approval("owner", "R3"),
            },
            "operating_envelope": {
                "baseline_evidence": baseline_reference,
                "thresholds": thresholds,
                "observation": {
                    "started_at": "2026-11-01T00:00:00Z",
                    "ended_at": "2026-11-04T00:00:00Z",
                },
                "operator_threshold_approval": approval("operator", "R6"),
                "release_owner_threshold_approval": approval("release-owner", "R6"),
            },
            "support_documents": {
                "release_notes": "docs/v0.50.0-release-notes.md",
                "support_matrix": "docs/v0.50.0-support-matrix.md",
                "operator_guide": "docs/v0.50.0-operations.md",
            },
            "final_signoffs": {
                "operator": approval("operator", "R8"),
                "release_owner": approval("release-owner", "R8"),
                "independent_reviewer": approval("independent-reviewer", "R8"),
            },
        },
        "gates": gates,
    }


class V050QualificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.evidence_directory = Path(self.temporary_directory.name)
        self.addCleanup(self.temporary_directory.cleanup)

    def test_shadow_competitors_preserve_assignment_and_escalation_shapes(self):
        assignment = {
            "reason_code": "POSSIBLE_DUPLICATE", "entity_name": None,
            "queue": "priority", "priority": 1, "action": "ASSIGN_QUEUE",
        }
        escalation = {
            "reason_code": "POSSIBLE_DUPLICATE", "entity_name": "domain-1",
            "queue": None, "priority": 1, "action": "ESCALATE", "level": 1,
        }
        invalid_escalation = {**escalation, "level": "1"}
        missing_level = {key: value for key, value in escalation.items() if key != "level"}
        assignment_with_level = {**assignment, "level": 1}
        self.assertEqual(
            [
                _valid_shadow_competitors([assignment]),
                _valid_shadow_competitors([escalation]),
                _valid_shadow_competitors([invalid_escalation]),
                _valid_shadow_competitors([missing_level]),
                _valid_shadow_competitors([assignment_with_level]),
            ],
            [True, True, False, False, False],
        )

    def test_coordinator_owner_must_remain_pg_react(self):
        manifest = complete_manifest(self.evidence_directory)
        manifest["artifact_tuple"]["coordinator_owner"] = "mdm"
        self.assertEqual(
            derive(manifest, self.evidence_directory),
            {
                "release_qualified": False,
                "artifact_tuple_complete": False,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": ["coordinator_owner"],
                "blocking_gates": ["R6"],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": [
                    "operating_envelope.baseline_evidence",
                    "operating_envelope.final_evidence",
                ],
                "release_record_complete": False,
            },
        )

    def test_adapter_source_does_not_call_mdm_refresh(self):
        sql_directory = ROOT / "integrations/pg-mdm/sql"
        source = "\n".join(path.read_text() for path in sorted(sql_directory.glob("*.sql")))
        self.assertEqual(
            re.findall(r"(?i)\bmdm\s*\.\s*refresh\s*\(", source),
            [],
        )

    def test_current_manifest_remains_blocked_on_missing_external_evidence(self):
        manifest = json.loads((HERE / "evidence/v0.50.0/manifest.json").read_text())
        result = derive(manifest, HERE / "evidence/v0.50.0")
        self.assertEqual(
            result,
            {
                "release_qualified": False,
                "artifact_tuple_complete": False,
                "missing_artifact_fields": list(ARTIFACT_FIELDS),
                "invalid_artifact_fields": [],
                "blocking_gates": list(GATE_IDS),
                "manifest_errors": [],
                "missing_release_fields": [
                    field for field in RECORD_FIELDS
                    if field not in {
                        "support_documents.release_notes",
                        "support_documents.support_matrix",
                        "support_documents.operator_guide",
                    }
                ],
                "invalid_release_fields": [],
                "release_record_complete": False,
            },
        )

    def test_require_qualified_exit_status_matches_the_derived_decision(self):
        blocked_path = HERE / "evidence/v0.50.0/manifest.json"
        qualified_path = self.evidence_directory / "qualified-manifest.json"
        qualified_path.write_text(json.dumps(complete_manifest(self.evidence_directory)))
        for path, expected_status in ((blocked_path, False), (qualified_path, True)):
            completed = subprocess.run(
                [sys.executable, str(HERE / "derive_v050_qualification.py"),
                 str(path), "--require-qualified"],
                capture_output=True,
                text=True,
                check=False,
            )
            result = json.loads(completed.stdout)
            self.assertEqual(result, derive(json.loads(path.read_text()), path.parent))
            self.assertEqual(result["release_qualified"], expected_status)
            self.assertEqual(completed.returncode, 0 if expected_status else 1)
            self.assertEqual(completed.stderr, "")

    def test_complete_tuple_and_every_retained_required_gate_qualify(self):
        result = derive(complete_manifest(self.evidence_directory), self.evidence_directory)
        self.assertEqual(
            result,
            {
                "release_qualified": True,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": [],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": [],
                "release_record_complete": True,
            },
        )

    def test_final_signoff_must_follow_observation_end(self):
        manifest = complete_manifest(self.evidence_directory)
        manifest["release_record"]["final_signoffs"]["operator"]["signed_at"] = (
            "2026-11-04T00:00:00Z"
        )
        self.assertEqual(
            derive(manifest, self.evidence_directory),
            {
                "release_qualified": False,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": [],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": ["final_signoffs.operator"],
                "release_record_complete": False,
            },
        )

    def test_baseline_requires_all_scenario_measurements(self):
        manifest = complete_manifest(self.evidence_directory)
        reference = manifest["release_record"]["operating_envelope"]["baseline_evidence"]
        path = self.evidence_directory / reference["path"]
        report = json.loads(path.read_text())
        report["scenarios"].pop("hot_case_conflicts")
        content = json.dumps(report, sort_keys=True, separators=(",", ":")).encode()
        path.write_bytes(content)
        reference["sha256"] = hashlib.sha256(content).hexdigest()
        for field in (
            "operator_threshold_approval",
            "release_owner_threshold_approval",
        ):
            approval_reference = manifest["release_record"]["operating_envelope"][field]["evidence"]
            approval_path = self.evidence_directory / approval_reference["path"]
            approval = json.loads(approval_path.read_text())
            approval["baseline_sha256"] = reference["sha256"]
            approval_content = json.dumps(
                approval, sort_keys=True, separators=(",", ":")
            ).encode()
            approval_path.write_bytes(approval_content)
            approval_reference["sha256"] = hashlib.sha256(approval_content).hexdigest()
        self.assertEqual(
            derive(manifest, self.evidence_directory),
            {
                "release_qualified": False,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": ["R6"],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": ["operating_envelope.baseline_evidence"],
                "release_record_complete": False,
            },
        )

    def test_final_operating_run_must_meet_every_approved_bound(self):
        manifest = complete_manifest(self.evidence_directory)
        reference = next(
            gate for gate in manifest["gates"] if gate["id"] == "R6"
        )["evidence"][0]
        path = self.evidence_directory / reference["path"]
        report = json.loads(path.read_text())
        report["summary"]["latency_p95_ms"] = 2001
        content = json.dumps(report, sort_keys=True, separators=(",", ":")).encode()
        path.write_bytes(content)
        reference["sha256"] = hashlib.sha256(content).hexdigest()
        self.assertEqual(
            derive(manifest, self.evidence_directory),
            {
                "release_qualified": False,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": ["R6"],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": [
                    "operating_envelope.thresholds.latency_p95_ms_max"
                ],
                "release_record_complete": False,
            },
        )

    def test_required_metrics_cannot_be_marked_unavailable(self):
        manifest = complete_manifest(self.evidence_directory)
        reference = next(
            gate for gate in manifest["gates"] if gate["id"] == "R6"
        )["evidence"][0]
        path = self.evidence_directory / reference["path"]
        report = json.loads(path.read_text())
        report["unavailable_metrics"] = [
            {"name": "latency_p95_ms", "reason": "not measured"}
        ]
        content = json.dumps(report, sort_keys=True, separators=(",", ":")).encode()
        path.write_bytes(content)
        reference["sha256"] = hashlib.sha256(content).hexdigest()
        self.assertEqual(
            derive(manifest, self.evidence_directory),
            {
                "release_qualified": False,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": ["R6"],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": ["operating_envelope.final_evidence"],
                "release_record_complete": False,
            },
        )

    def test_threshold_approvals_must_bind_the_baseline_and_exact_limits(self):
        manifest = complete_manifest(self.evidence_directory)
        manifest["release_record"]["operating_envelope"]["thresholds"][
            "latency_p95_ms_max"
        ] = 3000
        self.assertEqual(
            derive(manifest, self.evidence_directory),
            {
                "release_qualified": False,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": ["R6"],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": [
                    "operating_envelope.operator_threshold_approval",
                    "operating_envelope.release_owner_threshold_approval",
                ],
                "release_record_complete": False,
            },
        )

    def test_threshold_approval_must_precede_the_final_run(self):
        manifest = complete_manifest(self.evidence_directory)
        approval = manifest["release_record"]["operating_envelope"][
            "operator_threshold_approval"
        ]
        approval["signed_at"] = "2026-11-02T00:00:00Z"
        reference = approval["evidence"]
        path = self.evidence_directory / reference["path"]
        evidence = json.loads(path.read_text())
        evidence["signed_at"] = approval["signed_at"]
        content = json.dumps(evidence, sort_keys=True, separators=(",", ":")).encode()
        path.write_bytes(content)
        reference["sha256"] = hashlib.sha256(content).hexdigest()
        self.assertEqual(
            derive(manifest, self.evidence_directory),
            {
                "release_qualified": False,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": ["R6"],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": [
                    "operating_envelope.operator_threshold_approval"
                ],
                "release_record_complete": False,
            },
        )

    def test_skipped_required_gate_cannot_qualify(self):
        manifest = complete_manifest(self.evidence_directory)
        manifest["gates"][0]["status"] = "skipped"
        result = derive(manifest, self.evidence_directory)
        self.assertEqual(
            result,
            {
                "release_qualified": False,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": [GATE_IDS[0]],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": [],
                "release_record_complete": True,
            },
        )

    def test_passed_gate_without_evidence_cannot_qualify(self):
        manifest = copy.deepcopy(complete_manifest(self.evidence_directory))
        manifest["gates"][0]["evidence"] = []
        result = derive(manifest, self.evidence_directory)
        self.assertEqual(
            result,
            {
                "release_qualified": False,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": [GATE_IDS[0]],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": [],
                "release_record_complete": True,
            },
        )

    def test_malformed_artifact_digest_cannot_qualify(self):
        manifest = complete_manifest(self.evidence_directory)
        manifest["artifact_tuple"]["pg_mdm_shared_library_sha256"] = "not-a-digest"
        result = derive(manifest, self.evidence_directory)
        self.assertEqual(
            result,
            {
                "release_qualified": False,
                "artifact_tuple_complete": False,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": ["pg_mdm_shared_library_sha256"],
                "blocking_gates": ["R6"],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": [
                    "operating_envelope.baseline_evidence",
                    "operating_envelope.final_evidence",
                ],
                "release_record_complete": False,
            },
        )

    def test_artifact_tuple_rejects_non_text_versions_and_non_object_configuration(self):
        manifest = complete_manifest(self.evidence_directory)
        manifest["artifact_tuple"]["pg_react_version"] = 50
        manifest["artifact_tuple"]["temporal_configuration"] = "configured"
        result = derive(manifest, self.evidence_directory)
        self.assertEqual(
            result,
            {
                "release_qualified": False,
                "artifact_tuple_complete": False,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": ["pg_react_version", "temporal_configuration"],
                "blocking_gates": ["R6"],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": [
                    "operating_envelope.baseline_evidence",
                    "operating_envelope.final_evidence",
                ],
                "release_record_complete": False,
            },
        )

    def test_passed_gate_requires_retained_file_with_matching_digest(self):
        manifest = complete_manifest(self.evidence_directory)
        (self.evidence_directory / "logs/R1.log").write_text("changed evidence\n")
        result = derive(manifest, self.evidence_directory)
        self.assertEqual(
            result,
            {
                "release_qualified": False,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": ["R1"],
                "manifest_errors": ["R1 evidence[0] sha256 does not match the retained file"],
                "missing_release_fields": [],
                "invalid_release_fields": [],
                "release_record_complete": True,
            },
        )

    def test_evidence_path_cannot_escape_manifest_directory(self):
        manifest = complete_manifest(self.evidence_directory)
        manifest["gates"][0]["evidence"][0]["path"] = "../R1.log"
        result = derive(manifest, self.evidence_directory)
        self.assertEqual(
            result,
            {
                "release_qualified": False,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": ["R1"],
                "manifest_errors": ["R1 evidence[0] path must be a relative path inside the manifest directory"],
                "missing_release_fields": [],
                "invalid_release_fields": [],
                "release_record_complete": True,
            },
        )

    def test_partial_shadow_coverage_cannot_qualify(self):
        manifest = complete_manifest(self.evidence_directory)
        manifest["release_record"]["shadow"]["partial"] = True
        result = derive(manifest, self.evidence_directory)
        self.assertEqual(
            result,
            {
                "release_qualified": False,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": [],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": ["shadow.partial"],
                "release_record_complete": False,
            },
        )

    def test_shadow_count_mismatch_and_duplicate_keys_cannot_qualify(self):
        manifest = complete_manifest(self.evidence_directory)
        manifest["release_record"]["shadow"]["observed_case_count"] = 99
        manifest["release_record"]["shadow"]["duplicate_case_count"] = 1
        result = derive(manifest, self.evidence_directory)
        self.assertEqual(
            result,
            {
                "release_qualified": False,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": [],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": [
                    "shadow.observed_case_count",
                    "shadow.duplicate_case_count",
                ],
                "release_record_complete": False,
            },
        )

    def test_coverage_manifest_must_match_the_frozen_membership(self):
        manifest = complete_manifest(self.evidence_directory)
        reference = manifest["release_record"]["shadow"]["coverage_manifest"]
        path = self.evidence_directory / reference["path"]
        coverage = json.loads(path.read_text())
        coverage[0]["coverage"]["membership"].pop()
        content = json.dumps(coverage, sort_keys=True, separators=(",", ":")).encode()
        path.write_bytes(content)
        reference["sha256"] = hashlib.sha256(content).hexdigest()
        result = derive(manifest, self.evidence_directory)
        self.assertEqual(
            result,
            {
                "release_qualified": False,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": [],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": ["shadow.coverage_manifest"],
                "release_record_complete": False,
            },
        )

    def test_shadow_requires_assignment_deadline_and_escalation_details(self):
        manifest = complete_manifest(self.evidence_directory)
        reference = manifest["release_record"]["shadow"]["coverage_manifest"]
        path = self.evidence_directory / reference["path"]
        coverage = json.loads(path.read_text())
        for side in ("current", "proposed"):
            route = coverage[0]["rows"][0][side]["route"]
            for field in ("current_queue", "requested_escalation_level"):
                route.pop(field)
            coverage[0]["rows"][0][side]["deadline"].pop("existing_due_at")
        content = json.dumps(coverage, sort_keys=True, separators=(",", ":")).encode()
        path.write_bytes(content)
        reference["sha256"] = hashlib.sha256(content).hexdigest()
        result = derive(manifest, self.evidence_directory)
        self.assertEqual(
            result,
            {
                "release_qualified": False,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": [],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": [
                    "shadow.coverage_manifest",
                    "shadow.observed_case_count",
                ],
                "release_record_complete": False,
            },
        )

    def test_package_digest_must_match_its_retained_artifact(self):
        manifest = complete_manifest(self.evidence_directory)
        manifest["release_record"]["cohort"]["package_digest"] = "f" * 64
        result = derive(manifest, self.evidence_directory)
        self.assertEqual(
            result,
            {
                "release_qualified": False,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": [],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": ["cohort.package_digest"],
                "release_record_complete": False,
            },
        )

    def test_coverage_evidence_must_decode_to_a_manifest(self):
        manifest = complete_manifest(self.evidence_directory)
        reference = manifest["release_record"]["shadow"]["coverage_manifest"]
        path = self.evidence_directory / reference["path"]
        content = b"null"
        path.write_bytes(content)
        reference["sha256"] = hashlib.sha256(content).hexdigest()
        result = derive(manifest, self.evidence_directory)
        self.assertEqual(
            result,
            {
                "release_qualified": False,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": [],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": ["shadow.coverage_manifest"],
                "release_record_complete": False,
            },
        )

    def test_duplicate_rows_cannot_be_hidden_by_matching_recorded_counts(self):
        manifest = complete_manifest(self.evidence_directory)
        reference = manifest["release_record"]["shadow"]["coverage_manifest"]
        path = self.evidence_directory / reference["path"]
        coverage = json.loads(path.read_text())
        coverage[0]["rows"][-1]["case_key"] = coverage[0]["rows"][-2]["case_key"]
        content = json.dumps(coverage, sort_keys=True, separators=(",", ":")).encode()
        path.write_bytes(content)
        reference["sha256"] = hashlib.sha256(content).hexdigest()
        result = derive(manifest, self.evidence_directory)
        self.assertEqual(
            result,
            {
                "release_qualified": False,
                "artifact_tuple_complete": True,
                "missing_artifact_fields": [],
                "invalid_artifact_fields": [],
                "blocking_gates": [],
                "manifest_errors": [],
                "missing_release_fields": [],
                "invalid_release_fields": [
                    "shadow.coverage_manifest",
                    "shadow.duplicate_case_count",
                ],
                "release_record_complete": False,
            },
        )


if __name__ == "__main__":
    unittest.main()
