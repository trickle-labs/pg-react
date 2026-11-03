"""Real MDM recurrence delivered only by the ordinary PostgreSQL worker."""
import copy
import datetime
import json
import time
import uuid


def qualify(sql, command, fixture, container, observations, timestamp):
    assert timestamp("2026-10-27T09:24:55.69977+00:00") == datetime.datetime(
        2026, 10, 27, 9, 24, 55, 699770, tzinfo=datetime.timezone.utc)
    fixture("autonomous-setup", "/work/tests/integrations/pg-mdm/time/autonomous-recurrence.sql", "s1_idle")
    read = lambda query: json.loads(sql(query))
    state = lambda: read("SELECT s1_auto.state()")
    before = state()
    original = read("SELECT original_key FROM s1_auto.issue")
    binding = read("SELECT to_jsonb(b) FROM pgreact_mdm.policy_intent_bindings b WHERE enabled")

    def wait_for(predicate, description, seconds=45):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            actual = state()
            if predicate(actual):
                return actual
            time.sleep(0.2)
        observations["autonomous_failure_state"] = actual
        observations["autonomous_failure_status"] = read("SELECT pgreact_api.managed_status()")
        raise AssertionError(description)

    def delivered(before, key):
        actual = wait_for(lambda s: any(r["case_key"] == key and
            r["policy_revision"] == "s1-idle-feasibility" for r in s["requests"]),
            "managed runtime did not autonomously enroll/deliver occurrence " + str(key))
        prior = next(c for c in before["cases"] if c["case_key"] == key)
        expected_cases = copy.deepcopy(before["cases"])
        for case in expected_cases:
            if case["case_key"] == key:
                case.update(escalation_level=2, action_revision=prior["action_revision"] + 1)
        assert actual["cases"] == expected_cases, (actual["cases"], expected_cases)
        assert actual["source"] == before["source"]
        assert actual["selector"] == before["selector"]
        request, = [r for r in actual["requests"] if r["case_key"] == key]
        receipt, = [r for r in actual["receipts"] if r["case_key"] == key]
        attempt, = [a for a in actual["intent_attempts"] if a["case_key"] == key]
        work_ref = request["work_ref"]
        _, episode = work_ref.split(":")[1:]
        activation = read("SELECT to_jsonb(m) FROM pgreact.matches m WHERE name='s1-autonomous' AND semantic_key=" + str(key))
        body = {
            "action": "ESCALATE", "arguments": {"level": 2}, "case_key": key,
            "binding_id": binding["binding_id"], "policy_revision": binding["policy_revision"],
            "expected_policy_digest": binding["policy_digest"][2:],
            "expected_evidence_basis_digest": prior["evidence_basis_digest"][2:],
            "evaluation_ref": "pgreact:" + activation["activation_id"], "work_ref": work_ref,
            **{"expected_" + k: prior[k] for k in ("review_version", "definition_version",
                "publication_revision", "stewardship_epoch", "action_revision")}}
        assert request["request_body"] == body
        key_bytes = "\\x" + sql("SELECT encode(pgreact_mdm.intent_request_key('" +
            binding["binding_id"] + "'::uuid,'s1-idle-feasibility'," + str(key) + ",1," +
            str(prior["action_revision"]) + ",'escalate_level_2',2),'hex')")
        digest = "\\x" + sql("SELECT encode(pgreact_mdm.intent_request_digest('" +
            json.dumps(body).replace("'", "''") + "'::jsonb),'hex')")
        assert request == {
            "binding_id": binding["binding_id"], "request_key": key_bytes,
            "request_digest": digest, "request_body": body, "work_ref": work_ref,
            "policy_revision": binding["policy_revision"], "case_key": key,
            "lifecycle_generation": 1, "action_revision": prior["action_revision"],
            "consequence_identity": "escalate_level_2", "escalation_level": 2,
            "first_episode_id": int(episode), "created_at": request["created_at"]}, request
        assert receipt == {
            "receipt_id": receipt["receipt_id"], "created_at": receipt["created_at"],
            "actor": "pgreact_mdm_worker", "selected_role_name": "pgreact_mdm_worker",
            "session_role_name": "mdm_s1_runtime", "action": "ESCALATE",
            "outcome": "APPLIED_CONTROL", "reason_code": "CONTROL_APPLIED",
            "control": {"assigned_queue": None, "due_at": prior["due_at"].replace("T", " ").removesuffix(":00"),
                        "escalation_level": 2, "manual_assignment_protected": False},
            "case_key": key, "binding_id": binding["binding_id"], "binding_version": binding["binding_version"],
            "action_revision": prior["action_revision"] + 1, "resulting_publication_revision": None,
            "request_body": body, "request_key": key_bytes, "request_digest": digest}, receipt
        assert actual["receipts"] == before["receipts"] + [receipt]
        assert actual["requests"] == sorted(before["requests"] + [request], key=lambda r: r["work_ref"])
        assert attempt == {
            "episode_id": int(episode), "attempt_no": 1, "binding_id": binding["binding_id"],
            "request_key": key_bytes, "request_digest": digest, "request_body": body,
            "work_ref": work_ref, "receipt_id": receipt["receipt_id"],
            "outcome": "APPLIED_CONTROL", "reason_code": "CONTROL_APPLIED", "case_key": key,
            "action_revision": prior["action_revision"] + 1, "control": receipt["control"],
            "resulting_publication_revision": None, "attempted_at": attempt["attempted_at"]}, attempt
        assert actual["intent_attempts"] == before["intent_attempts"] + [attempt]
        work, = [w for w in actual["work"] if w["work_id"] == episode]
        assert work == {"work_id": episode, "kind": "rule", "name": "s1-autonomous", "version": "1",
                        "state": "COMPLETED", "claimable": False, "updated_at": work["updated_at"]}
        core_attempt, = [a for a in actual["attempts"] if a["episode_id"] == int(episode)]
        assert core_attempt == {**{k: core_attempt[k] for k in
            ("execution_id", "started_at", "finished_at", "worker_id")}, "episode_id": int(episode),
            "attempt_no": 1, "status": "COMPLETED", "error_message": None, "error_code": None,
            "event_kind": "ACTIVATE", "name": "s1-autonomous"}
        assert actual["work"] == before["work"] + [work]
        assert actual["attempts"] == before["attempts"] + [core_attempt]
        inspection = read("SET SESSION AUTHORIZATION s1_inspector; SELECT to_jsonb(d) "
            "FROM pgreact_mdm.delivery_inspection_v1 d WHERE work_ref='" + work_ref + "'; RESET SESSION AUTHORIZATION")
        assert inspection == {
            "work_ref": work_ref, "binding_id": binding["binding_id"], "binding_version": binding["binding_version"],
            "entity_name": "policy_qualification", "policy_revision": binding["policy_revision"],
            "policy_digest": binding["policy_digest"][2:], "case_key": key, "lifecycle_generation": 1,
            "action_revision": prior["action_revision"], "action": "ESCALATE", "requested_at": request["created_at"],
            "delivery_outcome": "APPLIED_CONTROL", "delivery_reason_code": "CONTROL_APPLIED",
            "attempted_at": attempt["attempted_at"], "mdm_receipt_id": receipt["receipt_id"],
            "mdm_outcome": "APPLIED_CONTROL", "mdm_reason_code": "CONTROL_APPLIED",
            "resulting_publication_revision": None, "current_case_status": "open",
            "current_publication_revision": prior["publication_revision"], "remediation_state": "NONE",
            "remediation_reason_code": None, "remediation_at": None, "requested_due_at": None,
            "current_due_at": prior["due_at"], "requested_escalation_level": 2, "applied_escalation_level": 2,
            "current_escalation_level": 2, "current_manual_assignment_protected": False,
            "current_pending_stewardship": False}, inspection
        history = read("SET SESSION AUTHORIZATION s1_inspector; "
            "SELECT pgreact_api.deadline_history('s1-autonomous'); RESET SESSION AUTHORIZATION")
        assert history == {"contract_version": 2, "rule_name": "s1-autonomous", "events": history["events"]}
        event, = [e for e in history["events"]
                  if e["semantic_key"] == key and e["event_kind"] == "ACTIVATE"]
        assert event == {"rule_name": "s1-autonomous", "semantic_key": key, "generation": 1,
                         "revision": 0, "event_kind": "ACTIVATE", "declared_deadline": prior["due_at"],
                         "clock_frontier": event["clock_frontier"]}, event
        assert timestamp(event["clock_frontier"]) >= timestamp(prior["due_at"])
        assert sql("SELECT has_function_privilege('mdm_s1_runtime',"
                   "'pgreact_mdm.sync_intent_case_identities()','EXECUTE')") == "f"
        assert sql("SELECT has_table_privilege('mdm_s1_runtime','pgtrickle.pgt_dependencies','SELECT')") == "f"
        return actual

    def reconcile_after_restart(expected):
        if sql("SELECT to_regprocedure('mdm_internal.policy_runtime_epoch()') IS NOT NULL") != "t":
            return
        end = time.monotonic() + 30
        while time.monotonic() < end:
            process = read("SELECT pgreact_api.managed_status()").get("process") or {}
            if process.get("state") == "error" and process.get("detail") == "MDM activation required":
                break
            time.sleep(0.2)
        else:
            raise AssertionError("managed worker did not block for post-restart activation")
        assert state() == expected, "restart changed durable state before reconciliation"
        runtime = read("SELECT jsonb_build_object('binding_id',b.binding_id,'runtime_version',r.runtime_version) "
                       "FROM pgreact_mdm.policy_intent_bindings b JOIN mdm_internal.policy_binding_runtime r USING(binding_id) "
                       "WHERE b.enabled AND b.policy_revision='s1-idle-feasibility'")
        sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
            "SELECT pgreact_mdm.reconcile_intent_binding('{}'::uuid,{})".format(
                runtime["binding_id"], runtime["runtime_version"]))

    sql("ALTER SYSTEM SET pg_react.databases='s1_idle'", "postgres")
    sql("ALTER SYSTEM SET pg_react.worker_role='mdm_s1_runtime'", "postgres")
    command("docker", "restart", container)
    command("docker", "exec", container, "sh", "-c",
            "until pg_isready -U postgres >/dev/null 2>&1; do sleep 0.2; done")
    reconcile_after_restart(before)
    first = delivered(before, original)
    observations["autonomous_occurrence_1"] = first
    fixture("autonomous-successor", "/work/tests/integrations/pg-mdm/time/autonomous-successor.sql", "s1_idle")
    prepared = read("SELECT vector FROM s1_auto.before_successor")
    successor, = [c for c in prepared["cases"] if c["issue_key"] ==
        next(c["issue_key"] for c in prepared["cases"] if c["case_key"] == original) and c["occurrence"] == 2]
    assert successor["case_key"] != original and successor["status"] == "open"
    assert not any(i["case_key"] == successor["case_key"] for i in prepared["identities"])
    second = delivered(prepared, successor["case_key"])
    assert [r for r in second["receipts"] if r["case_key"] == original] == [
        r for r in first["receipts"] if r["case_key"] == original]

    def later_cycles(expected_state):
        started = timestamp(json.loads(sql("SELECT to_json(clock_timestamp())")))
        wait_for(lambda _: (lambda p: p.get("state") == "ready" and p.get("heartbeat_at") and
            timestamp(p["heartbeat_at"]) > started + datetime.timedelta(seconds=3))(
                read("SELECT pgreact_api.managed_status()").get("process") or {}),
            "managed cycles failed to advance after recurrence")
        assert state() == expected_state, "later managed cycles changed durable state"

    later_cycles(second)
    successor_case_key = successor["case_key"]
    prior_request, = [r for r in second["requests"] if r["case_key"] == successor_case_key]
    prior_applied_receipt, = [r for r in second["receipts"]
        if r["case_key"] == successor_case_key and r["outcome"] == "APPLIED_CONTROL"]
    inactive_activation = read(
        "SELECT to_jsonb(a) FROM pgreact_internal.activation_state a "
        "JOIN pgreact_internal.rule_versions v USING (rule_version_id) "
        "JOIN pgreact_internal.rules r USING (rule_id) "
        "WHERE r.rule_name='s1-autonomous' AND a.semantic_key=" + str(successor_case_key))
    assert inactive_activation["active"] is False
    assert inactive_activation["generation"] == prior_request["lifecycle_generation"]

    fixture("autonomous-human-reduction",
            "/work/tests/integrations/pg-mdm/time/autonomous-human-reduction.sql", "s1_idle")
    expected_cases = copy.deepcopy(second["cases"])
    lowered_case = next(c for c in expected_cases if c["case_key"] == successor_case_key)
    lowered_case.update(escalation_level=1, action_revision=lowered_case["action_revision"] + 1)

    def generation_denial_ready(actual):
        return any(r["case_key"] == successor_case_key
            and r["lifecycle_generation"] > prior_request["lifecycle_generation"]
            and r["action_revision"] == lowered_case["action_revision"]
            for r in actual["requests"])

    after_generation_denial = wait_for(
        generation_denial_ready,
        "new React generation did not submit the same occurrence's previously applied level")
    assert after_generation_denial["cases"] == expected_cases
    assert after_generation_denial["source"] == second["source"]
    assert after_generation_denial["selector"] == second["selector"]
    generation_request, = [r for r in after_generation_denial["requests"]
        if r["case_key"] == successor_case_key
        and r["lifecycle_generation"] > prior_request["lifecycle_generation"]]
    generation = generation_request["lifecycle_generation"]
    active_activation = read(
        "SELECT to_jsonb(a) FROM pgreact_internal.activation_state a "
        "JOIN pgreact_internal.rule_versions v USING (rule_version_id) "
        "JOIN pgreact_internal.rules r USING (rule_id) "
        "WHERE r.rule_name='s1-autonomous' AND a.semantic_key=" + str(successor_case_key))
    assert generation == prior_request["lifecycle_generation"] + 1
    assert active_activation["active"] is True
    assert active_activation["generation"] == generation
    generation_activation = read(
        "SELECT to_jsonb(m) FROM pgreact.matches m WHERE name='s1-autonomous' "
        "AND semantic_key=" + str(successor_case_key))
    assert generation_activation["activation_id"] == active_activation["activation_id"]
    work_parts = generation_request["work_ref"].split(":")
    assert len(work_parts) == 3 and work_parts[0] == "pgreact"
    assert work_parts[1] == active_activation["rule_version_id"]
    episode_id = int(work_parts[2])

    expected_body = {
        "action": "ESCALATE", "arguments": {"level": 2},
        "binding_id": binding["binding_id"], "case_key": successor_case_key,
        "evaluation_ref": "pgreact:" + generation_activation["activation_id"],
        "expected_action_revision": lowered_case["action_revision"],
        "expected_definition_version": lowered_case["definition_version"],
        "expected_evidence_basis_digest": lowered_case["evidence_basis_digest"][2:],
        "expected_policy_digest": binding["policy_digest"][2:],
        "expected_publication_revision": lowered_case["publication_revision"],
        "expected_review_version": lowered_case["review_version"],
        "expected_stewardship_epoch": lowered_case["stewardship_epoch"],
        "policy_revision": binding["policy_revision"],
        "work_ref": generation_request["work_ref"],
    }
    expected_key = "\\x" + sql(
        "SELECT encode(pgreact_mdm.intent_request_key('" + binding["binding_id"] +
        "'::uuid,'s1-idle-feasibility'," + str(successor_case_key) + "," +
        str(generation) + "," + str(lowered_case["action_revision"]) +
        ",'escalate_level_2',2),'hex')")
    expected_digest = "\\x" + sql(
        "SELECT encode(pgreact_mdm.intent_request_digest('" +
        json.dumps(expected_body).replace("'", "''") + "'::jsonb),'hex')")
    expected_request = {
        "binding_id": binding["binding_id"], "request_key": expected_key,
        "request_digest": expected_digest, "request_body": expected_body,
        "work_ref": generation_request["work_ref"],
        "policy_revision": binding["policy_revision"], "case_key": successor_case_key,
        "lifecycle_generation": generation,
        "action_revision": lowered_case["action_revision"],
        "consequence_identity": "escalate_level_2", "escalation_level": 2,
        "first_episode_id": episode_id, "created_at": generation_request["created_at"],
    }
    assert generation_request == expected_request, generation_request
    timestamp(generation_request["created_at"])
    assert generation_request["request_key"] != prior_request["request_key"]

    case_receipts = [r for r in after_generation_denial["receipts"]
        if r["case_key"] == successor_case_key and r["action"] == "ESCALATE"]
    applied_receipt, = [r for r in case_receipts if r["outcome"] == "APPLIED_CONTROL"]
    denial_receipt, = [r for r in case_receipts if r["outcome"] == "ACTION_DENIED"]
    assert len(case_receipts) == 2
    assert applied_receipt == prior_applied_receipt
    assert denial_receipt["reason_code"] == "ESCALATION_LEVEL_ALREADY_APPLIED"
    expected_control = {
        "assigned_queue": lowered_case["assigned_queue"],
        "due_at": lowered_case["due_at"].replace("T", " ").removesuffix(":00"),
        "escalation_level": 1,
        "manual_assignment_protected": lowered_case["manual_assignment_protected"],
    }
    expected_denial_receipt = {
        "receipt_id": denial_receipt["receipt_id"],
        "created_at": denial_receipt["created_at"],
        "actor": "pgreact_mdm_worker", "selected_role_name": "pgreact_mdm_worker",
        "session_role_name": "mdm_s1_runtime", "action": "ESCALATE",
        "outcome": "ACTION_DENIED", "reason_code": "ESCALATION_LEVEL_ALREADY_APPLIED",
        "control": expected_control, "case_key": successor_case_key,
        "binding_id": binding["binding_id"], "binding_version": binding["binding_version"],
        "action_revision": lowered_case["action_revision"],
        "resulting_publication_revision": None, "request_body": expected_body,
        "request_key": expected_key, "request_digest": expected_digest,
    }
    assert denial_receipt == expected_denial_receipt, denial_receipt
    uuid.UUID(denial_receipt["receipt_id"])
    timestamp(denial_receipt["created_at"])
    assert len(after_generation_denial["receipts"]) == len(second["receipts"]) + 1
    assert [r for r in after_generation_denial["receipts"]
        if r["receipt_id"] in {old["receipt_id"] for old in second["receipts"]}] == second["receipts"]

    generation_attempt, = [a for a in after_generation_denial["intent_attempts"]
        if a["request_key"] == expected_key]
    expected_attempt = {
        "episode_id": episode_id, "attempt_no": 1, "binding_id": binding["binding_id"],
        "request_key": expected_key, "request_digest": expected_digest,
        "request_body": expected_body, "work_ref": generation_request["work_ref"],
        "receipt_id": denial_receipt["receipt_id"], "outcome": "ACTION_DENIED",
        "reason_code": "ESCALATION_LEVEL_ALREADY_APPLIED", "case_key": successor_case_key,
        "action_revision": lowered_case["action_revision"], "control": expected_control,
        "resulting_publication_revision": None, "attempted_at": generation_attempt["attempted_at"],
    }
    assert generation_attempt == expected_attempt
    timestamp(generation_attempt["attempted_at"])
    assert after_generation_denial["intent_attempts"] == sorted(
        second["intent_attempts"] + [generation_attempt],
        key=lambda a: (a["episode_id"], a["attempt_no"]))
    assert after_generation_denial["requests"] == sorted(
        second["requests"] + [generation_request], key=lambda r: r["work_ref"])
    generation_work, = [w for w in after_generation_denial["work"]
        if w["work_id"] == work_parts[2]]
    expected_work = {
        "work_id": work_parts[2], "kind": "rule", "name": "s1-autonomous",
        "version": "1", "state": "COMPLETED", "claimable": False,
        "updated_at": generation_work["updated_at"],
    }
    assert generation_work == expected_work
    assert len(after_generation_denial["work"]) == len(second["work"]) + 1
    old_work_ids = {w["work_id"] for w in second["work"]}
    assert [w for w in after_generation_denial["work"] if w["work_id"] in old_work_ids] == second["work"]
    generation_core_attempt, = [a for a in after_generation_denial["attempts"]
        if a["episode_id"] == episode_id]
    expected_core_attempt = {
        **{k: generation_core_attempt[k] for k in
            ("execution_id", "started_at", "finished_at", "worker_id")},
        "episode_id": episode_id, "attempt_no": 1, "status": "COMPLETED",
        "error_message": None, "error_code": None,
        "event_kind": "ACTIVATE", "name": "s1-autonomous",
    }
    assert generation_core_attempt == expected_core_attempt
    timestamp(generation_core_attempt["started_at"])
    timestamp(generation_core_attempt["finished_at"])
    old_core_attempt_ids = {a["execution_id"] for a in second["attempts"]}
    assert [a for a in after_generation_denial["attempts"]
        if a["execution_id"] in old_core_attempt_ids] == second["attempts"]
    assert len(after_generation_denial["attempts"]) == len(second["attempts"]) + 1
    assert len([r for r in after_generation_denial["receipts"]
        if r["case_key"] == successor_case_key and r["action"] == "ESCALATE"
        and r["outcome"] == "APPLIED_CONTROL" and r["control"].get("escalation_level") == 2]) == 1

    holds = read("SELECT COALESCE(jsonb_agg(to_jsonb(h) ORDER BY held_at),'[]') "
        "FROM pgreact_mdm.intent_holds h WHERE binding_id='" + binding["binding_id"] +
        "'::uuid AND case_key=" + str(successor_case_key) +
        " AND expected_action_revision=" + str(lowered_case["action_revision"]))
    hold, = holds
    assert hold["binding_id"] == binding["binding_id"]
    assert hold["case_key"] == successor_case_key
    assert hold["policy_revision"] == binding["policy_revision"]
    assert hold["action"] == "ESCALATE"
    assert hold["expected_action_revision"] == lowered_case["action_revision"]
    assert hold["reason_code"] == "ESCALATION_LEVEL_ALREADY_APPLIED"
    timestamp(hold["held_at"])

    later_cycles(after_generation_denial)
    holds_after_cycles = read("SELECT COALESCE(jsonb_agg(to_jsonb(h) ORDER BY held_at),'[]') "
        "FROM pgreact_mdm.intent_holds h WHERE binding_id='" + binding["binding_id"] +
        "'::uuid AND case_key=" + str(successor_case_key) +
        " AND expected_action_revision=" + str(lowered_case["action_revision"]))
    assert holds_after_cycles == holds
    observations["same_occurrence_cross_generation"] = {
        "case_key": successor_case_key,
        "prior_generation": prior_request["lifecycle_generation"],
        "new_generation": generation,
        "inactive_before_human_edit": inactive_activation,
        "active_after_reentry": active_activation,
        "lowered_case": lowered_case,
        "request": generation_request,
        "attempt": generation_attempt,
        "applied_receipt_unchanged": applied_receipt,
        "denial_receipt": denial_receipt,
        "hold": hold,
        "no_repeat_after_cycles": True,
    }
    observations["checks"].append({
        "name": "same-occurrence-cross-generation-repeat-denied", "result": "passed"})

    old_postmaster = sql("SELECT pg_postmaster_start_time()")
    command("docker", "restart", container)
    # Wait via docker exec without assuming a fixed startup duration.
    command("docker", "exec", container, "sh", "-c",
            "until pg_isready -U postgres >/dev/null 2>&1; do sleep 0.2; done")
    assert sql("SELECT pg_postmaster_start_time()") > old_postmaster
    reconcile_after_restart(after_generation_denial)
    later_cycles(after_generation_denial)
    holds_after_restart = read("SELECT COALESCE(jsonb_agg(to_jsonb(h) ORDER BY held_at),'[]') "
        "FROM pgreact_mdm.intent_holds h WHERE binding_id='" + binding["binding_id"] +
        "'::uuid AND case_key=" + str(successor_case_key) +
        " AND expected_action_revision=" + str(lowered_case["action_revision"]))
    assert holds_after_restart == holds
    observations["autonomous_recurrence"] = {"before": prepared, "after": second,
        "exact": True, "old_receipts_unchanged": True, "no_replay_across_cycles_and_restart": True}
    observations["checks"].append({"name": "autonomous-recurrence", "result": "passed"})
    observations["entry_decision"] = "FOCUSED_AUTONOMOUS_RECURRENCE_QUALIFIED"
    print("PASS: autonomous MDM recurrence, cross-generation duplicate denial and cold restart", flush=True)
