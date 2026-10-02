#!/usr/bin/env python3
"""Run the S1 entry audit in one disposable joint-stack container."""
import copy
import datetime
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid


def main():
    image, output = sys.argv[1:3]
    maintenance = sys.argv[3:] == ["--maintenance"]
    if sys.argv[3:] and not maintenance:
        raise ValueError("only --maintenance is supported after IMAGE OUTPUT")
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[4]
    container = "pgreact-s1-" + uuid.uuid4().hex[:12]
    observations = {"image": image, "checks": [], "entry_decision": "INCOMPLETE"}
    created = False

    def command(*args):
        result = subprocess.run(args, capture_output=True, text=True, timeout=300)
        if result.returncode:
            raise RuntimeError(" ".join(args) + "\n" + result.stdout + result.stderr)
        return result.stdout

    def sql(query, database="s1_idle"):
        return command("docker", "exec", container, "psql", "-XAtq", "-U",
                       "postgres", "-d", database, "-v", "ON_ERROR_STOP=1", "-c", query).strip()

    def timestamp(value):
        try:
            return datetime.datetime.fromisoformat(value)
        except ValueError:
            layout = "%Y-%m-%dT%H:%M:%S.%f%z" if "." in value else "%Y-%m-%dT%H:%M:%S%z"
            return datetime.datetime.strptime(value, layout)

    def fixture(name, file, database="foundation", variables=()):
        started = time.monotonic()
        result = command("docker", "exec", container, "psql", "-XAtq", "-U",
                         "postgres", "-d", database, "-v", "ON_ERROR_STOP=1", *variables, "-f", file)
        (output / (name + ".log")).write_text(result)
        observations["checks"].append({"name": name, "result": "passed",
                                       "seconds": time.monotonic() - started})
        print("PASS: " + name, flush=True)

    def cases():
        return json.loads(sql("SELECT jsonb_agg(to_jsonb(c) ORDER BY c.case_key) "
                              "FROM mdm_steward.policy_cases_v1 c"))

    try:
        observations["image_id"] = command("docker", "image", "inspect", image,
                                           "--format", "{{.Id}}").strip()
        command("docker", "run", "--detach", "--name", container, "--network", "none",
                "--env", "POSTGRES_HOST_AUTH_METHOD=trust", "--volume", str(root) + ":/work:ro",
                image, "postgres", "-c", "shared_preload_libraries=pg_trickle,pg_react",
                "-c", "pg_trickle.enabled=off", "-c", "pg_trickle.cdc_mode=trigger",
                "-c", "pg_trickle.differential_max_change_ratio=1.0")
        created = True
        for _ in range(60):
            result = subprocess.run(["docker", "exec", container, "pg_isready", "-U", "postgres"],
                                    capture_output=True)
            if result.returncode == 0 and "PostgreSQL init process complete" in command("docker", "logs", container):
                break
            time.sleep(1)
        else:
            raise RuntimeError("PostgreSQL readiness exceeded 60 seconds")
        fixture("mdm-bootstrap", "/tests/e2e.sql", "postgres")
        fixture("mdm-policy-fixtures", "/tests/e2e_policy.sql")
        observations["mdm_entry_cases"] = json.loads(sql(
            "SELECT jsonb_agg(to_jsonb(c) ORDER BY case_key) FROM mdm_steward.policy_cases_v1 c", "foundation"))
        observations["mdm_entry_receipts"] = json.loads(sql(
            "SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id) FROM mdm_steward.policy_receipts_v1 r", "foundation"))
        observations["fixture_sha256"] = command("docker", "exec", container, "sha256sum",
            "/tests/e2e.sql", "/tests/e2e_policy.sql", "/usr/lib/postgresql/18/lib/pg_react.so",
            "/usr/lib/postgresql/18/lib/pg_mdm.so", "/usr/lib/postgresql/18/lib/pg_trickle.so").splitlines()
        sql("ALTER DATABASE foundation ALLOW_CONNECTIONS false", "postgres")
        sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='foundation'", "postgres")
        try:
            command("docker", "exec", container, "createdb", "-U", "postgres",
                    "--template=foundation", "s1_idle")
        finally:
            sql("ALTER DATABASE foundation ALLOW_CONNECTIONS true", "postgres")
        # Recover only the disposable clone's capture identity, before future-deadline setup.
        observations["clone_capture_recovery"] = sql("SELECT pgtrickle.recover_capture_instance()")
        assert cases() == observations["mdm_entry_cases"], "clone recovery changed MDM cases"
        assert json.loads(sql("SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id) "
                              "FROM mdm_steward.policy_receipts_v1 r")) == observations["mdm_entry_receipts"], "clone recovery changed MDM receipts"
        for database in ("foundation", "s1_idle"):
            version = "0.46.0" if maintenance and database == "foundation" else "0.46.1"
            sql("CREATE EXTENSION pg_react VERSION '{}'".format(version), database)
        for name in ("v0.47", "v0.47-typed", "v0.48-codec"):
            fixture(name, "/work/tests/integrations/pg-mdm/" + name + ".sql", "postgres")
        for name in ("v0.47-live-setup", "v0.47-live", "v0.48-codec", "v0.48-live", "v0.48-security"):
            fixture(name, "/work/tests/integrations/pg-mdm/" + name + ".sql")
        observations["foundation_receipts"] = json.loads(sql(
            "SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id) FROM mdm_steward.policy_receipts_v1 r", "foundation"))
        if maintenance:
            observations["maintenance"] = {}
            for database, upgrade in (("core_claim", False), ("core_upgrade", True), ("foundation", True)):
                if database != "foundation":
                    command("docker", "exec", container, "createdb", "-U", "postgres", database)
                    sql("CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react VERSION '" +
                        ("0.46.0" if upgrade else "0.46.1") + "'", database)
                else:
                    sql("SELECT pgreact_api.pause_rule(rule_name) FROM pgreact.rules WHERE state='ACTIVE'", database)
                    pause_commands = json.loads(sql(
                        "SELECT COALESCE(jsonb_agg(format('SET SESSION AUTHORIZATION %I; SET ROLE %I; "
                        "SELECT pgreact_mdm.pause_intent_binding(%L::uuid,%s)', "
                        "(SELECT login.rolname FROM pg_catalog.pg_roles login WHERE login.rolcanlogin "
                        "AND NOT login.rolsuper AND NOT login.rolbypassrls "
                        "AND pg_has_role(login.oid,b.entity_execution_role,'MEMBER') ORDER BY login.rolname LIMIT 1), "
                        "b.entity_execution_role,b.binding_id,r.runtime_version)), '[]') "
                        "FROM pgreact_mdm.policy_intent_bindings b JOIN pgreact_mdm.policy_intent_runtime r USING(binding_id) "
                        "WHERE b.enabled", database))
                    for pause in pause_commands:
                        sql(pause, database)
                fixture(database, "/work/tests/integrations/pg-mdm/time/maintenance.sql", database,
                        ("-v", "upgrade=" + str(upgrade).lower(), "-v", "direct=" + str(database != "foundation").lower()))
                observations["maintenance"][database] = json.loads(sql(
                    "SELECT jsonb_build_object('before',to_jsonb(b),'after',to_jsonb(a),'result',r.vector) "
                    "FROM claim_maintenance.before_upgrade b, claim_maintenance.after_upgrade a, "
                    "claim_maintenance.result r", database))
            assert observations["maintenance"]["core_claim"]["after"]["api"] == observations["maintenance"]["core_upgrade"]["after"]["api"], "fresh/upgrade public callable inventories differ"
        command("docker", "exec", "--user", "postgres", container, "sh",
                "/work/tests/integrations/pg-mdm/v0.48-admission.sh", "s1_missing_mdm")
        observations["checks"].append({"name": "missing-mdm-admission", "result": "passed"})
        command("docker", "exec", container, "createdb", "-U", "postgres", "s1_boundary")
        sql("CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react", "s1_boundary")
        fixture("sample-boundaries", "/work/tests/integrations/pg-mdm/time/boundaries.sql", "s1_boundary")
        fixture("idle-setup", "/work/tests/integrations/pg-mdm/time/idle.sql", "s1_idle")
        observations["installed_extensions"] = json.loads(sql(
            "SELECT jsonb_agg(jsonb_build_object('name',extname,'version',extversion) ORDER BY extname) "
            "FROM pg_extension"))
        observations["server_version_num"] = int(sql("SELECT current_setting('server_version_num')"))
        observations["installed_functions"] = json.loads(sql(
            "SELECT jsonb_agg(jsonb_build_object('identity',p.oid::regprocedure::text,"
            "'owner',pg_get_userbyid(p.proowner),'security_definer',p.prosecdef,'acl',p.proacl::text,"
            "'result',pg_get_function_result(p.oid),"
            "'definition_sha256',encode(sha256(convert_to(pg_get_functiondef(p.oid),'UTF8')),'hex')) "
            "ORDER BY p.oid::regprocedure::text) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace "
            "WHERE n.nspname IN ('pgreact_api','pgreact_mdm','mdm_steward') AND p.prokind='f' "
            "AND p.proname IN ('author_deadline_rule','author_temporal_rule','validate_deadline_rule',"
            "'run','managed_status','managed_cycle','deadline_history','temporal_status','temporal_history',"
            "'submit_policy_intent','submit_escalation_intent','submit_intent_as_worker')"))
        before = cases()
        source = json.loads(sql("SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id) "
                                "FROM public.policy_qualification_source s"))
        temporal_source = json.loads(sql("SELECT jsonb_agg(to_jsonb(s) ORDER BY s.case_key) "
                                         "FROM s1_audit.source s"))
        assert len(temporal_source) == 1, temporal_source
        case_key = temporal_source[0]["case_key"]
        deadline = timestamp(temporal_source[0]["deadline"])
        expected = copy.deepcopy(before)
        for row in expected:
            if row["case_key"] == case_key:
                assert row["escalation_level"] == 1 and row["due_at"] == temporal_source[0]["deadline"]
                row["escalation_level"] = 2
                row["action_revision"] += 1
                expected_revision = row["action_revision"]
        expected_control = json.loads(sql(
            "SELECT jsonb_build_object('assigned_queue',c.assigned_queue,'due_at',c.due_at::text,"
            "'escalation_level',2,'manual_assignment_protected',c.manual_assignment_protected) "
            "FROM mdm_steward.policy_cases_v1 c WHERE c.case_key=" + str(case_key)))
        binding = json.loads(sql("SELECT jsonb_build_object('binding_id',binding_id,"
            "'binding_version',binding_version,'policy_digest',encode(policy_digest,'hex')) "
            "FROM pgreact_mdm.policy_intent_bindings "
            "WHERE policy_revision='s1-idle-feasibility' AND enabled"))
        uuid.UUID(binding["binding_id"])
        assert deadline > datetime.datetime.now(datetime.timezone.utc), temporal_source
        observations.update(cases_before=before, business_source=source,
                            temporal_source=temporal_source, cases_expected=expected)
        sql("ALTER SYSTEM SET pg_react.databases = 's1_idle'")
        sql("ALTER SYSTEM SET pg_react.worker_role = 'mdm_s1_runtime'")
        command("docker", "restart", container)
        end = time.monotonic() + 120
        receipts = []
        while time.monotonic() < end:
            ready = subprocess.run(["docker", "exec", container, "pg_isready", "-U", "postgres"],
                                   capture_output=True)
            if ready.returncode:
                time.sleep(0.2)
                continue
            receipts = json.loads(sql("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.receipt_id), '[]') "
                "FROM mdm_steward.policy_receipts_v1 r WHERE request_body->>'policy_revision'='s1-idle-feasibility'"))
            status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            detail = (status.get("process") or {}).get("detail") or ""
            if receipts or (detail.startswith("42702:") and '"rule_version_id" is ambiguous' in detail):
                break
            if detail.startswith("permission denied: must be owner of stream table ") and \
                    datetime.datetime.now(datetime.timezone.utc) >= deadline:
                break
            failed = sql("SELECT EXISTS (SELECT 1 FROM pgreact.attempts "
                         "WHERE name='s1-future-idle' AND status='FAILED')")
            if failed == "t" and datetime.datetime.now(datetime.timezone.utc) >= deadline:
                break
            time.sleep(0.2)
        observations["runtime_settings"] = json.loads(sql(
            "SELECT jsonb_object_agg(name,setting) FROM pg_settings WHERE name IN "
            "('pg_react.databases','pg_react.worker_role','pg_react.poll_interval_ms',"
            "'pg_react.batch_size','pg_react.max_pending_jobs','max_worker_processes')"))
        observations["managed_status"] = json.loads(sql("SELECT pgreact_api.managed_status()"))
        observations["work"] = json.loads(sql("SELECT COALESCE(jsonb_agg(to_jsonb(w) ORDER BY work_id),'[]') "
                                              "FROM pgreact.work w WHERE name='s1-future-idle'"))
        observations["attempts"] = json.loads(sql("SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY execution_id),'[]') "
                                                  "FROM pgreact.attempts a WHERE name='s1-future-idle'"))
        if not receipts and ((observations["managed_status"].get("process") or {}).get("detail") or "").startswith("42702:"):
            query = "SELECT * FROM pgreact.claim('s1-independent-diagnostic',32,interval '60 seconds',NULL::text[])"
            failure = subprocess.run(["docker", "exec", container, "psql", "-XAtq", "-U", "postgres",
                "-d", "s1_idle", "-v", "VERBOSITY=verbose", "-c", query], capture_output=True, text=True)
            observations["generic_claim_failure"] = {"query": query, "exit": failure.returncode,
                                                    "stdout": failure.stdout, "stderr": failure.stderr}
            assert failure.returncode != 0 and "42702" in failure.stderr, failure.stderr
            assert 'column reference "rule_version_id" is ambiguous' in failure.stderr, failure.stderr
            assert "pgreact.claim(text,integer,interval,text[])" in failure.stderr, failure.stderr
            observations["generic_claim_definition"] = sql(
                "SELECT pg_get_functiondef('pgreact.claim(text,integer,interval,text[])'::regprocedure)")
            observations["cases_actual"] = cases()
            assert observations["cases_actual"] == before, "generic STOP changed the complete MDM case population"
            assert json.loads(sql("SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id) "
                                  "FROM public.policy_qualification_source s")) == source
            assert json.loads(sql("SELECT jsonb_agg(to_jsonb(s) ORDER BY s.case_key) "
                                  "FROM s1_audit.source s")) == temporal_source
            observations["receipts_actual"] = json.loads(sql(
                "SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id) FROM mdm_steward.policy_receipts_v1 r"))
            assert observations["receipts_actual"] == observations["mdm_entry_receipts"], "generic STOP changed retained public receipts"
            observations["entry_decision"] = "STOP"
            observations["stop_reason"] = "The installed generic managed claim operation fails before dispatch; working idle-time support is unavailable on this exact artifact."
            observations["conditional_work_not_performed"] = ["1000-case due/churn measurements", "numeric envelope/sign-off",
                "downstream S2/S3 implementation and qualification"]
            observations["checks"].append({"name": "generic-claim-unavailability", "result": "confirmed",
                                            "sqlstate": "42702"})
            print("STOP: independently confirmed generic managed claim defect 42702; re-estimation required", flush=True)
            return
        if not receipts:
            observations["cases_actual"] = cases()
            observations["receipts_actual"] = json.loads(sql(
                "SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id) FROM mdm_steward.policy_receipts_v1 r"))
            assert observations["cases_actual"] == before, "blocked worker changed MDM cases"
            assert observations["receipts_actual"] == observations["mdm_entry_receipts"], "blocked worker changed MDM receipts"
            assert json.loads(sql("SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id) "
                                  "FROM public.policy_qualification_source s")) == source
            assert json.loads(sql("SELECT jsonb_agg(to_jsonb(s) ORDER BY s.case_key) "
                                  "FROM s1_audit.source s")) == temporal_source
            observations["blocked_populations_unchanged"] = True
        assert len(receipts) == 1, {key: observations[key] for key in ("runtime_settings", "managed_status", "work", "attempts")}
        receipt = receipts[0]
        assert receipt["case_key"] == case_key and receipt["outcome"] == "APPLIED_CONTROL", receipts
        assert receipt["reason_code"] == "CONTROL_APPLIED" and receipt["resulting_publication_revision"] is None, receipts
        assert receipt["actor"] == "pgreact_mdm_worker" and receipt["action_revision"] == expected_revision, receipts
        assert receipt["control"] == expected_control, receipts
        assert receipt["request_body"]["action"] == "ESCALATE" and receipt["request_body"]["arguments"] == {"level": 2}, receipts
        delivered_at = timestamp(receipt["created_at"])
        assert delivered_at >= deadline, receipts
        actual = cases()
        assert actual == expected, {"expected": expected, "actual": actual}
        assert json.loads(sql("SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id) "
                              "FROM public.policy_qualification_source s")) == source
        assert json.loads(sql("SELECT jsonb_agg(to_jsonb(s) ORDER BY s.case_key) "
                              "FROM s1_audit.source s")) == temporal_source
        matches = json.loads(sql("SELECT jsonb_agg(to_jsonb(m)) FROM pgreact.matches m "
                                 "WHERE name='s1-future-idle'"))
        assert len(matches) == 1 and matches[0]["active"] and matches[0]["generation"] == 1, matches
        activation = matches[0]
        uuid.UUID(activation["activation_id"])
        uuid.UUID(activation["rule_version_id"])
        status = json.loads(sql("SELECT pgreact_api.managed_status()"))
        work, attempts = observations["work"], observations["attempts"]
        assert [{k: v for k, v in row.items() if k not in ("work_id", "updated_at")}
                for row in work] == [{"kind": "rule", "name": "s1-future-idle", "version": "1",
                                     "state": "COMPLETED", "claimable": False}], work
        worker = "pg-react-managed/s1_idle/" + str(status["process"]["pid"])
        assert [{k: v for k, v in row.items() if k not in
                 ("execution_id", "episode_id", "started_at", "finished_at")}
                for row in attempts] == [{"attempt_no": 1, "worker_id": worker, "status": "COMPLETED",
                    "error_message": None, "error_code": None, "event_kind": "ACTIVATE",
                    "name": "s1-future-idle"}], attempts
        assert int(work[0]["work_id"]) == attempts[0]["episode_id"] > 0
        assert isinstance(attempts[0]["execution_id"], int) and attempts[0]["execution_id"] > 0
        started_at = timestamp(attempts[0]["started_at"])
        finished_at = timestamp(attempts[0]["finished_at"])
        updated_at = timestamp(work[0]["updated_at"])
        # MDM receipt creation and core attempt timestamps are separate writes.
        assert deadline <= started_at <= finished_at <= updated_at
        prior_case = next(row for row in before if row["case_key"] == case_key)
        expected_body = {
            "action": "ESCALATE", "arguments": {"level": 2}, "case_key": case_key,
            "binding_id": binding["binding_id"], "policy_revision": "s1-idle-feasibility",
            "expected_policy_digest": binding["policy_digest"],
            "expected_evidence_basis_digest": prior_case["evidence_basis_digest"][2:],
            "evaluation_ref": "pgreact:" + activation["activation_id"],
            "work_ref": "pgreact:" + activation["rule_version_id"] + ":" + work[0]["work_id"],
            **{"expected_" + name: prior_case[name] for name in ("review_version", "definition_version",
                "publication_revision", "stewardship_epoch", "action_revision")}}
        request_key = sql("SELECT encode(pgreact_mdm.intent_request_key('{}'::uuid,"
            "'s1-idle-feasibility',{},1,{},'escalate_level_2',2),'hex')".format(
                binding["binding_id"], int(case_key), int(prior_case["action_revision"])))
        request_digest = sql("SELECT encode(pgreact_mdm.intent_request_digest('" +
            json.dumps(expected_body).replace("'", "''") + "'::jsonb),'hex')")
        uuid.UUID(receipt["receipt_id"])
        expected_receipt = {"receipt_id": receipt["receipt_id"], "created_at": receipt["created_at"],
            "actor": "pgreact_mdm_worker", "selected_role_name": "pgreact_mdm_worker",
            "session_role_name": "mdm_s1_runtime", "action": "ESCALATE", "outcome": "APPLIED_CONTROL",
            "reason_code": "CONTROL_APPLIED", "control": expected_control, "case_key": case_key,
            "binding_id": binding["binding_id"], "binding_version": binding["binding_version"],
            "action_revision": expected_revision, "resulting_publication_revision": None,
            "request_body": expected_body, "request_key": "\\x" + request_key,
            "request_digest": "\\x" + request_digest}
        assert receipts == [expected_receipt], {"expected": expected_receipt, "actual": receipts}
        retained_receipts = json.loads(sql("SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id) "
                                          "FROM mdm_steward.policy_receipts_v1 r"))
        assert retained_receipts == observations["mdm_entry_receipts"] + [expected_receipt]
        sql("ALTER SYSTEM SET pg_react.databases = ''")
        command("docker", "restart", container)
        end = time.monotonic() + 30
        while time.monotonic() < end:
            ready = subprocess.run(["docker", "exec", container, "pg_isready", "-U", "postgres"],
                                   capture_output=True)
            if not ready.returncode:
                break
            time.sleep(0.2)
        assert not ready.returncode, "PostgreSQL did not restart for the role-reset failure check"
        sql("CREATE OR REPLACE FUNCTION pgreact_api.managed_cycle() RETURNS jsonb "
            "LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp "
            "AS $audit$ BEGIN RAISE EXCEPTION 'injected managed cycle failure'; END $audit$")
        failure = subprocess.run(["docker", "exec", container, "psql", "-XAtq", "-U",
            "mdm_s1_runtime", "-d", "s1_idle", "-f",
            "/workspace/tests/integrations/pg-mdm/time/role-reset-on-error.sql"],
            capture_output=True, text=True, timeout=30)
        assert failure.returncode == 0, failure.stderr
        assert failure.stdout == "mdm_s1_runtime|mdm_s1_runtime\n", failure.stdout
        assert "injected managed cycle failure" in failure.stderr, failure.stderr
        observations["callback_error_reset"] = {"exit": failure.returncode,
            "stdout": failure.stdout, "error_observed": "injected managed cycle failure" in failure.stderr}
        observations["checks"].append({"name": "callback-error-role-reset", "result": "passed"})
        assert json.loads(sql("SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id) "
                              "FROM mdm_steward.policy_receipts_v1 r")) == retained_receipts
        sql("CREATE ROLE mdm_s1_runtime_no_set LOGIN")
        sql("GRANT CONNECT ON DATABASE s1_idle TO mdm_s1_runtime_no_set")
        sql("GRANT USAGE ON SCHEMA pgreact_api TO mdm_s1_runtime_no_set")
        sql("ALTER SYSTEM SET pg_react.worker_role = 'mdm_s1_runtime_no_set'")
        sql("ALTER SYSTEM SET pg_react.databases = 's1_idle'")
        command("docker", "restart", container)
        end = time.monotonic() + 20
        rejection_lines = []
        while time.monotonic() < end:
            ready = subprocess.run(["docker", "exec", container, "pg_isready", "-U", "postgres"],
                                   capture_output=True)
            if not ready.returncode:
                logs = subprocess.run(["docker", "logs", "--tail", "200", container],
                                      capture_output=True, text=True, timeout=30)
                rejection_lines = [line for line in (logs.stdout + logs.stderr).splitlines()
                                   if "managed worker role must be a unique SET-capable function grantee" in line]
                if rejection_lines:
                    break
            time.sleep(0.2)
        assert rejection_lines, "worker without SET membership was not rejected by the managed path"
        assert sql("SELECT pg_catalog.pg_has_role('mdm_s1_runtime_no_set',"
                   "'pgreact_mdm_worker','SET')") == "f"
        assert sql("SELECT current_setting('pg_react.worker_role')") == "mdm_s1_runtime_no_set"
        assert json.loads(sql("SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id) "
                              "FROM mdm_steward.policy_receipts_v1 r")) == retained_receipts
        assert cases() == actual
        assert json.loads(sql("SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id) "
                              "FROM public.policy_qualification_source s")) == source
        assert json.loads(sql("SELECT jsonb_agg(to_jsonb(s) ORDER BY s.case_key) "
                              "FROM s1_audit.source s")) == temporal_source
        assert json.loads(sql("SELECT COALESCE(jsonb_agg(to_jsonb(w) ORDER BY work_id),'[]') "
                              "FROM pgreact.work w WHERE name='s1-future-idle'")) == work
        assert json.loads(sql("SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY execution_id),'[]') "
                              "FROM pgreact.attempts a WHERE name='s1-future-idle'")) == attempts
        observations["no_set_membership"] = {"worker_login": "mdm_s1_runtime_no_set",
            "configured_role": "pgreact_mdm_worker", "set_membership": False,
            "rejection": rejection_lines[-1], "public_state_unchanged": True}
        observations["checks"].append({"name": "worker-missing-set-membership", "result": "passed"})
        observations.update(receipt_expected=expected_receipt, matches=matches, idle_binding=binding)
        observations.update(cases_actual=actual, receipts=receipts,
                            deadline_to_receipt_seconds=(delivered_at - deadline).total_seconds(),
                            managed_status=json.loads(sql("SELECT pgreact_api.managed_status()")),
                            deadline_history=json.loads(sql("SELECT pgreact_api.deadline_history('s1-future-idle')")))
        observations["checks"].append({"name": "future-idle-mdm-receipt", "result": "passed"})
        observations["entry_decision"] = "INPUT_BLOCKED"
        observations["remaining_inputs"] = ["1000-case/churn workload measurements", "owner-confirmed complete escalation fixtures",
                                             "signed numeric operating envelope"]
        print("PASS: future idle deadline -> actual MDM receipt; complete case/source vectors", flush=True)
    except BaseException as error:
        observations["failure"] = str(error)
        if created:
            logs = subprocess.run(["docker", "logs", "--tail", "100", container],
                                  capture_output=True, text=True, timeout=30)
            observations["failure_logs"] = logs.stdout + logs.stderr
        raise
    finally:
        (output / "observations.json").write_text(json.dumps(observations, indent=2) + "\n")
        if created:
            command("docker", "rm", "--force", "--volumes", container)


if __name__ == "__main__":
    main()
