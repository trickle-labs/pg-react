"""Deterministic claimed React delivery versus MDM pause, edits and replacement."""
import copy
import json
import select
import socket
import subprocess
import threading
import time


class _ReplyDropProxy:
    def __init__(self, target_port):
        self.target_port = target_port
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("0.0.0.0", 0))
        self.listener.listen(1)
        self.listener.settimeout(30)
        self.port = self.listener.getsockname()[1]
        self.armed = threading.Event()
        self.result_captured = threading.Event()
        self.stopped = threading.Event()
        self.lock = threading.Lock()
        self.captured = bytearray()
        self.forwarded_after_arm = 0
        self.errors = []
        self.client = None
        self.upstream = None
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        try:
            client, _ = self.listener.accept()
            self.client = client
            upstream = socket.create_connection(("127.0.0.1", self.target_port), timeout=15)
            upstream.settimeout(None)
            self.upstream = upstream
        except BaseException as error:
            if not self.stopped.is_set():
                self.errors.append(str(error))
            return

        def pipe(source, destination, capture_reply=False):
            try:
                while not self.stopped.is_set():
                    data = source.recv(65536)
                    if not data:
                        break
                    if capture_reply and self.armed.is_set():
                        with self.lock:
                            self.captured.extend(data)
                            if b"COMPLETED" in self.captured:
                                self.result_captured.set()
                    else:
                        destination.sendall(data)
                        if capture_reply and self.armed.is_set():
                            with self.lock:
                                self.forwarded_after_arm += len(data)
            except OSError as error:
                if not self.stopped.is_set():
                    self.errors.append(str(error))
            finally:
                self._shutdown()

        client_to_server = threading.Thread(target=pipe, args=(client, upstream), daemon=True)
        server_to_client = threading.Thread(target=pipe, args=(upstream, client, True), daemon=True)
        client_to_server.start()
        server_to_client.start()
        client_to_server.join()
        server_to_client.join()

    def wait_for_result(self, timeout=15):
        if not self.result_captured.wait(timeout):
            raise AssertionError({"error": "proxy did not capture the committed execute result",
                                  "errors": self.errors})

    def drop(self):
        self._shutdown()
        with self.lock:
            captured = bytes(self.captured)
        return {"reply_bytes_captured_and_dropped": len(captured),
                "execute_result_captured": b"COMPLETED" in captured,
                "forwarded_reply_bytes_after_arm": self.forwarded_after_arm,
                "proxy_errors": list(self.errors)}

    def _shutdown(self):
        if self.stopped.is_set():
            return
        self.stopped.set()
        for connection in (self.client, self.upstream):
            if connection is not None:
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                try:
                    connection.close()
                except OSError:
                    pass

    def close(self):
        self._shutdown()
        try:
            self.listener.close()
        except OSError:
            pass


def qualify(sql, command, fixture, container, observations, postmaster_crash=False,
            transport_loss_target_port=None):
    setup_output = fixture("claimed-work-setup", "/work/tests/integrations/pg-mdm/time/claimed-work.sql", "s1_idle")
    pending_inspection, = [json.loads(line) for line in setup_output.splitlines()
        if "pending_delivery_inspection" in line]
    protected_inspection, = [json.loads(line) for line in setup_output.splitlines()
        if "protected_delivery_inspection" in line]
    unconfigured_privileges, = [json.loads(line)["unconfigured_delivery_inspection_privileges"]
        for line in setup_output.splitlines()
        if "unconfigured_delivery_inspection_privileges" in line]
    assert pending_inspection["expected"] == pending_inspection["actual"], pending_inspection
    assert protected_inspection["expected"] == protected_inspection["actual"], protected_inspection
    assert protected_inspection["expected"]["current_manual_assignment_protected"] is True, protected_inspection
    assert unconfigured_privileges == {
        "schema_usage": False,
        "query": "DENIED",
        "sqlstate": "42501",
        "message": "permission denied for schema pgreact_mdm",
    }, unconfigured_privileges
    observations["unconfigured_delivery_inspection_privileges"] = unconfigured_privileges
    observations.setdefault("delivery_inspection_vectors", []).extend(
        [pending_inspection, protected_inspection])
    route_explanations = [json.loads(line) for line in setup_output.splitlines()
        if any('"' + name + '"' in line for name in (
            "authorized_route_explanation", "authorized_route_protected", "authorized_route_no_op"))]
    assert {row["name"] for row in route_explanations} == {
        "authorized_route_explanation", "authorized_route_protected", "authorized_route_no_op"}, route_explanations
    assert all(row["expected"] == row["actual"] for row in route_explanations), route_explanations
    assert {row["expected"]["decision"] for row in route_explanations} == {
        "INELIGIBLE", "PROTECTED", "NO_OP"}, route_explanations
    observations["route_explanation_vectors"] = route_explanations
    read = lambda query: json.loads(sql(query))
    state = lambda: read("SELECT s1_claimed.state()")
    worker = "claimed-pause-regression"
    transport_proxy = None
    validation_gate_installed = False
    validation_gate_controller = None
    binding = read("SELECT to_jsonb(b) FROM pgreact_mdm.policy_intent_bindings b WHERE enabled")
    runtime = read("SELECT runtime_version FROM pgreact_mdm.policy_intent_runtime")
    before = state()
    assert before["receipts"] == before["requests"] == before["intent_attempts"] == []
    processes = []

    def start(name, query, interactive=False):
        assert not interactive or not query or query.rstrip().endswith(";"), (name, query)
        args = ["docker", "exec"] + (["-i"] if interactive else []) + [container,
            "psql", "-XAtq", "-U", "postgres", "-d", "s1_idle", "-v", "ON_ERROR_STOP=1"]
        prefix = "SET application_name='" + name + "'; SET statement_timeout='30s'; "
        process = subprocess.Popen(args + ([] if interactive else ["-c", prefix + query]),
            stdin=subprocess.PIPE if interactive else subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if interactive:
            process.stdin.write(prefix + query + "\n")
            process.stdin.flush()
        processes.append(process)
        return process

    def wait_for(predicate, label):
        end = time.monotonic() + 15
        while time.monotonic() < end:
            result = predicate()
            if result:
                return result
            time.sleep(0.05)
        raise AssertionError(label)

    def activity(name):
        return read("SELECT COALESCE((SELECT jsonb_build_object('pid',pid,'state',state,"
            "'wait_event_type',wait_event_type,'wait_event',wait_event,"
            "'blockers',pg_blocking_pids(pid)) FROM pg_stat_activity WHERE application_name='" + name + "'),'null')")

    def finish(process):
        out, error = process.communicate(timeout=35)
        assert process.returncode == 0, (out, error)
        return out.strip()

    def operator(function, version):
        return read("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
            "SELECT pgreact_mdm." + function + "('" + binding["binding_id"] + "'::uuid," + str(version) + ")")

    def claim_one():
        return read("SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "
            "SELECT COALESCE(jsonb_agg(to_jsonb(c)),'[]') FROM pgreact_api.claim('" + worker + "',1,interval '60 seconds') c")

    commit_claim_workers = ("claimed-concurrent-commit-first", "claimed-concurrent-commit-second")
    commit_agenda_before = None

    def restore_committed_claims(snapshot):
        if snapshot is None:
            return
        encoded = json.dumps(snapshot, separators=(",", ":")).replace("'", "''")
        sql("WITH prior AS (SELECT * FROM jsonb_to_recordset('" + encoded + "'::jsonb) AS p("
            "episode_id bigint,state text,lease_token uuid,worker_id text,claimed_at timestamptz,"
            "lease_expires_at timestamptz,completed_at timestamptz,attempt_count integer,"
            "last_error jsonb,state_changed_at timestamptz)) "
            "UPDATE pgreact_internal.agenda agenda SET "
            "state=prior.state,lease_token=prior.lease_token,worker_id=prior.worker_id,"
            "claimed_at=prior.claimed_at,lease_expires_at=prior.lease_expires_at,"
            "completed_at=prior.completed_at,attempt_count=prior.attempt_count,"
            "last_error=prior.last_error FROM prior "
            "WHERE agenda.episode_id=prior.episode_id AND agenda.worker_id IN ('" +
            "','".join(commit_claim_workers) + "')")
        sql("WITH prior AS (SELECT * FROM jsonb_to_recordset('" + encoded + "'::jsonb) AS p("
            "episode_id bigint,state text,lease_token uuid,worker_id text,claimed_at timestamptz,"
            "lease_expires_at timestamptz,completed_at timestamptz,attempt_count integer,"
            "last_error jsonb,state_changed_at timestamptz)) "
            "UPDATE pgreact_internal.agenda agenda SET state_changed_at=prior.state_changed_at "
            "FROM prior WHERE agenda.episode_id=prior.episode_id")

    def execute(c):
        return read("SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "
            "SELECT to_jsonb(pgreact_api.execute(" + str(c["episode_id"]) + ",'" + worker + "','" + c["lease_token"] + "'::uuid))")

    def check_delivery(prior, actual, c, outcome, reason, generation=1, current_case=None):
        case_key = c["bindings"]["case_key"]
        case = next(x for x in prior["cases"] if x["case_key"] == case_key)
        current_case = current_case or case
        expected_cases = copy.deepcopy(prior["cases"])
        for row in expected_cases:
            if row["case_key"] == case_key:
                row.update(current_case)
                if outcome == "APPLIED_CONTROL":
                    row.update(escalation_level=2,action_revision=case["action_revision"]+1)
        assert actual["cases"] == expected_cases, (expected_cases,actual["cases"])
        ref = "pgreact:" + c["rule_version_id"] + ":" + str(c["episode_id"])
        body = {"action":"ESCALATE","arguments":{"level":2},"case_key":case_key,
            "binding_id":binding["binding_id"],"policy_revision":binding["policy_revision"],
            "expected_policy_digest":binding["policy_digest"][2:],
            "expected_evidence_basis_digest":case["evidence_basis_digest"][2:],
            "evaluation_ref":"pgreact:"+c["activation_id"],"work_ref":ref,
            **{"expected_"+k:case[k] for k in ("action_revision","review_version","definition_version","publication_revision","stewardship_epoch")}}
        request, = [r for r in actual["requests"] if r["work_ref"] == ref]
        digest = "\\x"+sql("SELECT encode(pgreact_mdm.intent_request_digest('"+json.dumps(body).replace("'","''")+"'::jsonb),'hex')")
        request_key = "\\x"+sql("SELECT encode(pgreact_mdm.intent_request_key('"+binding["binding_id"]+
            "'::uuid,'s1-idle-feasibility',"+str(case_key)+","+str(generation)+","+str(case["action_revision"])+",'escalate_level_2',2),'hex')")
        assert request == {"binding_id":binding["binding_id"],"request_key":request_key,"request_digest":digest,
            "request_body":body,"work_ref":ref,"policy_revision":binding["policy_revision"],"case_key":case_key,
            "lifecycle_generation":generation,"action_revision":case["action_revision"],"consequence_identity":"escalate_level_2",
            "escalation_level":2,"first_episode_id":int(c["episode_id"]),"created_at":request["created_at"]},request
        receipt, = [r for r in actual["receipts"] if r["request_body"]["work_ref"] == ref]
        revision = current_case["action_revision"] + (outcome == "APPLIED_CONTROL")
        control = {"assigned_queue":None,"due_at":current_case["due_at"].replace("T"," ").removesuffix(":00"),
            "escalation_level":2 if outcome == "APPLIED_CONTROL" else current_case["escalation_level"],"manual_assignment_protected":False}
        assert receipt == {"receipt_id":receipt["receipt_id"],"created_at":receipt["created_at"],"actor":"pgreact_mdm_worker",
            "selected_role_name":"pgreact_mdm_worker","session_role_name":"mdm_s1_runtime","action":"ESCALATE",
            "outcome":outcome,"reason_code":reason,"control":control,"case_key":case_key,"binding_id":binding["binding_id"],
            "binding_version":binding["binding_version"],"action_revision":revision,"resulting_publication_revision":None,
            "request_body":body,"request_key":request_key,"request_digest":digest},receipt
        attempt, = [a for a in actual["intent_attempts"] if a["work_ref"] == ref]
        assert attempt == {"episode_id":int(c["episode_id"]),"attempt_no":1,"binding_id":binding["binding_id"],
            "request_key":request_key,"request_digest":digest,"request_body":body,"work_ref":ref,"receipt_id":receipt["receipt_id"],
            "outcome":outcome,"reason_code":reason,"case_key":case_key,"action_revision":revision,"control":control,
            "resulting_publication_revision":None,"attempted_at":attempt["attempted_at"]},attempt
        assert actual["requests"] == sorted(prior["requests"]+[request],key=lambda r:r["work_ref"])
        assert actual["receipts"] == prior["receipts"]+[receipt]
        assert actual["intent_attempts"] == prior["intent_attempts"]+[attempt]
        for name in ("source","technical_source"):
            assert actual[name] == prior[name]
        display_case = copy.deepcopy(current_case)
        if outcome == "APPLIED_CONTROL":
            display_case.update(escalation_level=2,action_revision=case["action_revision"]+1)
        hold = [h for h in actual["holds"] if h["binding_id"] == binding["binding_id"]
            and h["case_key"] == case_key and h["policy_revision"] == binding["policy_revision"]
            and h["action"] == "ESCALATE" and h["expected_action_revision"] == request["action_revision"]]
        current_holds = [h for h in hold
            if h["reason_code"] != "BINDING_PAUSED" or outcome == "BINDING_PAUSED"]
        held = outcome not in ("APPLIED_CONTROL","NO_CHANGE")
        if held:
            current_hold, = current_holds
            expected_holds = [{"action":"ESCALATE","binding_id":binding["binding_id"],
                "case_key":case_key,"expected_action_revision":request["action_revision"],
                "policy_revision":binding["policy_revision"],"reason_code":reason,
                "held_at":current_hold["held_at"]}]
        else:
            expected_holds = []
        assert current_holds == expected_holds, (expected_holds, current_holds, hold)
        inspection = read("SET SESSION AUTHORIZATION s1_claimed_reader; SELECT to_jsonb(i) "
            "FROM pgreact_mdm.delivery_inspection_v1 i WHERE work_ref='" + ref + "'; RESET SESSION AUTHORIZATION")
        expected_inspection = {
            "work_ref":ref,"binding_id":binding["binding_id"],"binding_version":binding["binding_version"],
            "entity_name":binding["entity_name"],"policy_revision":binding["policy_revision"],
            "policy_digest":binding["policy_digest"][2:],"case_key":case_key,
            "lifecycle_generation":generation,"action_revision":request["action_revision"],"action":"ESCALATE",
            "requested_at":request["created_at"],"delivery_outcome":outcome,"delivery_reason_code":reason,
            "attempted_at":attempt["attempted_at"],"mdm_receipt_id":receipt["receipt_id"],
            "mdm_outcome":outcome,"mdm_reason_code":reason,
            "resulting_publication_revision":receipt["resulting_publication_revision"],
            "current_case_status":display_case["status"],
            "current_publication_revision":display_case["publication_revision"],
            "remediation_state":"HELD" if held else "NONE",
            "remediation_reason_code":reason if held else None,
            "remediation_at":hold[0]["held_at"] if held else None,
            "requested_due_at":None,"current_due_at":display_case["due_at"],
            "requested_escalation_level":2,
            "applied_escalation_level":2 if outcome == "APPLIED_CONTROL" else None,
            "current_escalation_level":display_case["escalation_level"],
            "current_manual_assignment_protected":display_case["manual_assignment_protected"],
            "current_pending_stewardship":display_case["pending_stewardship"]}
        assert inspection == expected_inspection, inspection
        observations.setdefault("delivery_inspection_vectors", []).append(
            {"work_ref":ref,"expected":expected_inspection,"actual":inspection})
        work, = [w for w in actual["work"] if w["work_id"] == str(c["episode_id"])]
        assert work == {"work_id":str(c["episode_id"]),"kind":"rule","name":"s1-claimed-work","version":"1",
            "state":"COMPLETED","claimable":False,"updated_at":work["updated_at"]},work
        core, = [a for a in actual["attempts"] if a["episode_id"] == int(c["episode_id"])]
        assert core == {**{k:core[k] for k in ("execution_id","started_at","finished_at")},"episode_id":int(c["episode_id"]),
            "worker_id":worker,"attempt_no":1,"status":"COMPLETED","error_message":None,"error_code":None,
            "event_kind":"ACTIVATE","name":"s1-claimed-work"},core

    try:
        first_claim = start("claimed-concurrent-claim-first",
            "BEGIN; SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "
            "SELECT COALESCE(jsonb_agg(to_jsonb(c)),'[]') FROM pgreact_api.claim('claimed-concurrent-first',1,interval '60 seconds') c; "
            "SELECT pg_sleep(3); ROLLBACK")
        first_claim_wait = wait_for(lambda:(a if (a:=activity("claimed-concurrent-claim-first")) and
            a["state"]=="active" and a["wait_event"]=="PgSleep" else None),
            "first concurrent claim did not hold its transaction after leasing")
        second_claim = start("claimed-concurrent-claim-second",
            "BEGIN; SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "
            "SELECT COALESCE(jsonb_agg(to_jsonb(c)),'[]') FROM pgreact_api.claim('claimed-concurrent-second',1,interval '60 seconds') c; "
            "SELECT pg_sleep(1); ROLLBACK")
        second_claim_wait = wait_for(lambda:(a if (a:=activity("claimed-concurrent-claim-second")) and
            first_claim_wait["pid"] in a["blockers"] else None),
            "second concurrent claim did not wait behind the first claim transaction")
        first_result = json.loads(finish(first_claim))
        second_result = json.loads(finish(second_claim))
        assert len(first_result)==len(second_result)==1,(first_result,second_result)
        first_item,second_item = first_result[0],second_result[0]
        claim_fields = {"episode_id","lease_token","activation_id","bindings","event_kind","rule_version_id"}
        assert set(first_item)==set(second_item)==claim_fields,(first_item,second_item)
        assert first_item["episode_id"]==second_item["episode_id"],(first_item,second_item)
        assert first_item["lease_token"]!=second_item["lease_token"],(first_item,second_item)
        assert second_item=={**first_item,"lease_token":second_item["lease_token"]},(first_item,second_item)
        state_after_concurrent=state()
        assert state_after_concurrent==before,(before,state_after_concurrent)
        observations["concurrent_public_claims"]={"first":first_item,"second":second_item,
            "first_transaction":first_claim_wait,"second_blocked":second_claim_wait,"state_after_rollback":state_after_concurrent}

        commit_before = state()
        assert commit_before == before, (before, commit_before)
        commit_agenda_before = read("SELECT COALESCE(jsonb_agg(jsonb_build_object("
            "'episode_id',agenda.episode_id,'state',agenda.state,'lease_token',agenda.lease_token,"
            "'worker_id',agenda.worker_id,'claimed_at',agenda.claimed_at,"
            "'lease_expires_at',agenda.lease_expires_at,'completed_at',agenda.completed_at,"
            "'attempt_count',agenda.attempt_count,'last_error',agenda.last_error,"
            "'state_changed_at',agenda.state_changed_at) ORDER BY agenda.episode_id),'[]') "
            "FROM pgreact_internal.agenda agenda JOIN pgreact_internal.rule_versions version USING (rule_version_id) "
            "WHERE agenda.state IN ('PENDING','RETRY_WAIT') AND agenda.available_at <= clock_timestamp() "
            "AND version.state IN ('ACTIVE','DRAINING') AND NOT EXISTS (SELECT 1 FROM pgreact_internal.rule_barriers barrier "
            "WHERE barrier.rule_version_id=agenda.rule_version_id)")
        assert commit_agenda_before, "committed-claim race had no eligible agenda rows"
        assert read("SELECT COALESCE(jsonb_agg(worker_id ORDER BY worker_id),'[]') "
            "FROM pgreact_internal.agenda WHERE worker_id IN ('" + "','".join(commit_claim_workers) + "')") == [], \
            "committed-claim worker IDs already own agenda rows"
        first_commit = start(commit_claim_workers[0],
            "BEGIN; SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "
            "SELECT COALESCE(jsonb_agg(to_jsonb(c)),'[]') FROM pgreact_api.claim('" +
            commit_claim_workers[0] + "',1,interval '60 seconds') c;", interactive=True)
        first_commit_wait = wait_for(lambda:(a if (a:=activity(commit_claim_workers[0])) and
            a["state"]=="idle in transaction" else None),
            "first committed-claim transaction did not hold its lease")
        second_commit = start(commit_claim_workers[1],
            "BEGIN; SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "
            "SELECT COALESCE(jsonb_agg(to_jsonb(c)),'[]') FROM pgreact_api.claim('" +
            commit_claim_workers[1] + "',1,interval '60 seconds') c; COMMIT")
        second_commit_wait = wait_for(lambda:(a if (a:=activity(commit_claim_workers[1])) and
            first_commit_wait["pid"] in a["blockers"] else None),
            "second committed-claim transaction did not wait behind the first claim")
        first_commit.stdin.write("COMMIT;\n\\q\n")
        first_commit.stdin.flush()
        first_commit.stdin.close()
        first_commit_result = json.loads(finish(first_commit))
        second_commit_result = json.loads(finish(second_commit))
        assert len(first_commit_result)==1 and len(second_commit_result)<=1, \
            (first_commit_result,second_commit_result)
        first_commit_item, = first_commit_result
        assert first_commit_item["episode_id"] not in {item["episode_id"] for item in second_commit_result}, \
            (first_commit_result,second_commit_result)
        for item, claimant in [(first_commit_item,commit_claim_workers[0])] + [
                (item,commit_claim_workers[1]) for item in second_commit_result]:
            persisted = read("SELECT COALESCE((SELECT jsonb_build_object("
                "'episode_id',agenda.episode_id,'lease_token',agenda.lease_token,"
                "'activation_id',agenda.activation_id,'bindings',agenda.new_bindings,"
                "'event_kind',agenda.event_kind,'rule_version_id',agenda.rule_version_id) "
                "FROM pgreact_internal.agenda agenda WHERE agenda.episode_id=" +
                str(item["episode_id"]) + " AND agenda.state='LEASED' AND agenda.worker_id='" +
                claimant + "'),'null')")
            assert persisted == item, (item,persisted)
        restore_committed_claims(commit_agenda_before)
        commit_agenda_after = read("SELECT COALESCE(jsonb_agg(jsonb_build_object("
            "'episode_id',agenda.episode_id,'state',agenda.state,'lease_token',agenda.lease_token,"
            "'worker_id',agenda.worker_id,'claimed_at',agenda.claimed_at,"
            "'lease_expires_at',agenda.lease_expires_at,'completed_at',agenda.completed_at,"
            "'attempt_count',agenda.attempt_count,'last_error',agenda.last_error,"
            "'state_changed_at',agenda.state_changed_at) ORDER BY agenda.episode_id),'[]') "
            "FROM pgreact_internal.agenda agenda WHERE agenda.episode_id = ANY(ARRAY[" +
            ",".join(str(row["episode_id"]) for row in commit_agenda_before) + "]::bigint[])")
        assert commit_agenda_after == commit_agenda_before, (commit_agenda_before,commit_agenda_after)
        commit_after = state()
        assert commit_after == commit_before, (commit_before,commit_after)
        observations["concurrent_public_claim_commit"] = {
            "first":first_commit_item,"second":second_commit_result,
            "first_transaction":first_commit_wait,"second_blocked":second_commit_wait,
            "agenda_before":commit_agenda_before,"agenda_after_restore":commit_agenda_after,
            "state_before":commit_before,"state_after_restore":commit_after}
        claim = read("SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "
            "SELECT to_jsonb(c) FROM pgreact_api.claim('" + worker + "',1,interval '60 seconds') c")
        key = claim["bindings"]["case_key"]
        episode = int(claim["episode_id"])
        claimed_state = state()
        sql("CREATE FUNCTION s1_claimed.fail_commit() RETURNS trigger LANGUAGE plpgsql AS $$ "
            "BEGIN RAISE EXCEPTION 'injected work commit failure'; END $$; "
            "CREATE CONSTRAINT TRIGGER s1_claimed_commit_failure AFTER UPDATE ON pgreact_internal.agenda "
            "DEFERRABLE INITIALLY DEFERRED FOR EACH ROW "
            "EXECUTE FUNCTION s1_claimed.fail_commit()")
        failed_delivery = subprocess.run(
            ["docker", "exec", container, "psql", "-XAtq", "-U", "postgres", "-d", "s1_idle",
             "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=terse", "-c",
             "SET application_name='claimed-commit-failure'; SET statement_timeout='30s'; "
             "SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "
             "SELECT to_jsonb(pgreact_api.execute(" + str(episode) + ",'" + worker + "','" +
             claim["lease_token"] + "'::uuid))"], capture_output=True, text=True, timeout=35)
        assert (failed_delivery.returncode, failed_delivery.stdout, failed_delivery.stderr) == (
            1, "", "ERROR:  injected work commit failure\n"), (
                failed_delivery.returncode, failed_delivery.stdout, failed_delivery.stderr)
        rolled_back = state()
        assert rolled_back == claimed_state, (claimed_state, rolled_back)
        sql("DROP TRIGGER s1_claimed_commit_failure ON pgreact_internal.agenda; "
            "DROP FUNCTION s1_claimed.fail_commit()")
        observations["commit_failure_retry"] = {
            "failure": {"returncode":failed_delivery.returncode,"stdout":failed_delivery.stdout,
                        "stderr":failed_delivery.stderr},
            "claimed_state":claimed_state,"rolled_back_state":rolled_back}

        holder = start("claimed-case-holder", "BEGIN; SELECT case_key FROM mdm_steward.policy_cases_v1 "
                       "WHERE case_key=" + str(key) + " FOR UPDATE;", interactive=True)
        held = wait_for(lambda: (lambda a: a if a and a["state"] == "idle in transaction" else None)(
            activity("claimed-case-holder")), "case holder did not acquire its row lock")
        delivery = start("claimed-delivery", "SET SESSION AUTHORIZATION mdm_s1_runtime; "
            "SET ROLE pgreact_mdm_worker; SELECT to_jsonb(pgreact_api.execute(" + str(episode) +
            ",'" + worker + "','" + claim["lease_token"] + "'::uuid))")
        blocked = wait_for(lambda: (lambda a: a if a and held["pid"] in a["blockers"] else None)(
            activity("claimed-delivery")), "React delivery did not reach the MDM case lock")
        pause = start("claimed-pause", "SET SESSION AUTHORIZATION mdm_legacy_login; "
            "SET ROLE mdm_legacy_administrator; SELECT pgreact_mdm.pause_intent_binding('" +
            binding["binding_id"] + "'::uuid," + str(runtime) + ")")
        barrier = wait_for(lambda: "acknowledged" if pause.poll() is not None else (
            (lambda a: a if a and blocked["pid"] in a["blockers"] else None)(activity("claimed-pause"))),
            "pause neither acknowledged nor waited for the in-flight delivery")
        acknowledged_early = barrier == "acknowledged"
        during = state()
        holder.stdin.write("COMMIT;\n\\q\n")
        holder.stdin.flush()
        finish(holder)
        delivered = json.loads(finish(delivery))
        paused_version = int(finish(pause))
        after = state()
        observations["claimed_pause"] = {"claim": claim, "holder": held, "delivery": blocked,
            "pause_barrier": barrier, "pause_acknowledged_before_delivery_release": acknowledged_early,
            "runtime_before": runtime, "runtime_after": paused_version, "before": before,
            "during": during, "after": after, "delivery_result": delivered}
        observations["commit_failure_retry"]["retry_state"] = after
        applied = [r for r in after["receipts"] if r["case_key"] == key and r["outcome"] == "APPLIED_CONTROL"]
        assert not (acknowledged_early and applied), "authorized pause acknowledged before a blocked React delivery subsequently applied ESCALATE"
        assert not acknowledged_early, "pause did not serialize with the in-flight delivery"
        assert delivered == "COMPLETED"
        assert paused_version == runtime + 1
        check_delivery(before,after,claim,"APPLIED_CONTROL","CONTROL_APPLIED")

        # Pause owns the binding first. Delivery must read runtime again after
        # its lock wait, rather than use an eligibility snapshot from before it.
        active_version = operator("reconcile_intent_binding",paused_version)
        before_b = state()
        claim_b, = claim_one()
        pause_first = start("claimed-pause-first","BEGIN; SET SESSION AUTHORIZATION mdm_legacy_login; "
            "SET ROLE mdm_legacy_administrator; SELECT pgreact_mdm.pause_intent_binding('"+
            binding["binding_id"]+"'::uuid,"+str(active_version)+");",interactive=True)
        paused = wait_for(lambda:(lambda a:a if a and a["state"]=="idle in transaction" else None)(
            activity("claimed-pause-first")),"pause did not finish its uncommitted transition")
        delivery_b = start("claimed-delivery-b","SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "
            "SELECT to_jsonb(pgreact_api.execute("+str(claim_b["episode_id"])+",'"+worker+"','"+claim_b["lease_token"]+"'::uuid))")
        blocked_b = wait_for(lambda:(lambda a:a if a and paused["pid"] in a["blockers"] else None)(
            activity("claimed-delivery-b")),"delivery did not wait behind the pause binding lock")
        pause_first.stdin.write("COMMIT;\n\\q\n")
        pause_first.stdin.flush()
        paused_b_version = int(finish(pause_first))
        assert json.loads(finish(delivery_b)) == "COMPLETED"
        after_b = state()
        observations["pause_first_delivery"] = {"claim":claim_b,"blocked":blocked_b,"before":before_b,"after":after_b}
        check_delivery(before_b,after_b,claim_b,"BINDING_PAUSED","BINDING_PAUSED")

        # A fully committed pause precedes the next claim. Keep the old queued
        # identity, but submit no MDM request from the now-ineligible episode.
        sql("SELECT pgreact_api.run()")
        active_version = operator("reconcile_intent_binding",paused_b_version)
        sql("SELECT pgreact_api.run()")
        committed_version = operator("pause_intent_binding",active_version)
        before_committed = state()
        for _ in before["cases"]:
            c, = claim_one()
            assert execute(c) == "COMPLETED"
        assert claim_one() == []
        after_committed = state()
        for name in ("cases","receipts","requests","intent_attempts","holds","source","technical_source"):
            assert after_committed[name] == before_committed[name],name
        observations["pause_committed_before_claim"] = {"before":before_committed,"after":after_committed}

        # Fresh reevaluation after authorized resumption may progress the case
        # whose previous attempted request ended terminally paused.
        sql("SELECT pgreact_api.run()")
        active_version = operator("reconcile_intent_binding",committed_version)
        sql("SELECT pgreact_api.run()")
        before_fresh = state()
        for _ in before["cases"]:
            c, = claim_one()
            if c["bindings"]["case_key"] == claim_b["bindings"]["case_key"]:
                lost_ack = start("claimed-lost-ack-controller", "", interactive=True)
                if transport_loss_target_port is not None:
                    transport_proxy = _ReplyDropProxy(transport_loss_target_port)
                    lost_ack.stdin.write(
                        "SELECT dblink_connect('claimed_lost_ack', format("
                        "'dbname=%s user=mdm_s1_runtime host=host.docker.internal port=" +
                        str(transport_proxy.port) +
                        " application_name=claimed-lost-ack-worker connect_timeout=10', current_database()));\n")
                    lost_ack.stdin.flush()
                    ready, _, _ = select.select([lost_ack.stdout], [], [], 15)
                    assert ready, "dblink did not connect through the reply-drop proxy"
                    connect_output = lost_ack.stdout.readline().strip()
                    assert connect_output == "OK", connect_output
                    transport_proxy.armed.set()
                    lost_ack.stdin.write(
                        "SELECT dblink_send_query('claimed_lost_ack', format("
                        "'WITH worker AS MATERIALIZED (SELECT set_config(''role'', ''pgreact_mdm_worker'', false)) "
                        "SELECT to_jsonb(pgreact_api.execute(%L::bigint, %L, %L::uuid)) FROM worker', "
                        + str(c["episode_id"]) + ", '" + worker + "', '" + c["lease_token"] + "'));\n")
                else:
                    lost_ack.stdin.write(
                        "SELECT dblink_connect('claimed_lost_ack', format("
                        "'dbname=%s user=mdm_s1_runtime application_name=claimed-lost-ack-worker', current_database()));\n"
                        "SELECT dblink_send_query('claimed_lost_ack', format("
                        "'WITH worker AS MATERIALIZED (SELECT set_config(''role'', ''pgreact_mdm_worker'', false)) "
                        "SELECT to_jsonb(pgreact_api.execute(%L::bigint, %L, %L::uuid)) FROM worker', "
                        + str(c["episode_id"]) + ", '" + worker + "', '" + c["lease_token"] + "'));\n")
                lost_ack.stdin.flush()
                lost_episode = str(c["episode_id"])
                wait_for(lambda: read("SELECT count(*) FROM pgreact_internal.executions e "
                    "JOIN pgreact_internal.agenda a USING (episode_id) WHERE e.episode_id=" + lost_episode +
                    " AND e.status='COMPLETED' AND a.state='COMPLETED'") == 1,
                    "claimed execute did not commit before losing its result")
                committed = state()
                transport_loss = None
                if transport_proxy is not None:
                    transport_proxy.wait_for_result()
                    transport_loss = transport_proxy.drop()
                    assert transport_loss["reply_bytes_captured_and_dropped"] > 0, transport_loss
                    assert transport_loss["execute_result_captured"] is True, transport_loss
                    assert transport_loss["forwarded_reply_bytes_after_arm"] == 0, transport_loss
                    assert transport_loss["proxy_errors"] == [], transport_loss
                if postmaster_crash:
                    old_postmaster = sql("SELECT pg_postmaster_start_time()")
                    command("docker", "kill", "--signal=KILL", container)
                    controller_stdout, controller_stderr = lost_ack.communicate(timeout=35)
                    assert lost_ack.returncode != 0, (controller_stdout, controller_stderr)
                    assert "COMPLETED" not in controller_stdout.splitlines(), controller_stdout
                    command("docker", "start", container)
                    command("docker", "exec", container, "sh", "-c",
                        "until pg_isready -U postgres >/dev/null 2>&1; do sleep 0.2; done")
                    new_postmaster = sql("SELECT pg_postmaster_start_time()")
                    assert new_postmaster > old_postmaster, (old_postmaster, new_postmaster)
                    after_crash = state()
                    assert after_crash == committed, (committed, after_crash)
                else:
                    lost_ack.stdin.write("SELECT dblink_disconnect('claimed_lost_ack');\n\\q\n")
                    lost_ack.stdin.flush()
                    controller_stdout = (connect_output + "\n" if transport_proxy is not None else "") + finish(lost_ack)
                    controller_stderr = ""
                    assert controller_stdout.splitlines() == ["OK", "1", "OK"], controller_stdout
                lost_retry = subprocess.run(
                    ["docker", "exec", container, "psql", "-XAtq", "-U", "postgres", "-d", "s1_idle",
                     "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=terse", "-c",
                     "SET application_name='claimed-lost-ack-retry'; SET statement_timeout='30s'; "
                     "SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "
                     "SELECT to_jsonb(pgreact_api.execute(" + lost_episode + ",'" + worker + "','" +
                     c["lease_token"] + "'::uuid))"], capture_output=True, text=True, timeout=35)
                expected_error = "ERROR:  lease is no longer valid for episode " + lost_episode + "\n"
                assert (lost_retry.returncode, lost_retry.stdout, lost_retry.stderr) == (
                    1, "", expected_error), (lost_retry.returncode, lost_retry.stdout, lost_retry.stderr)
                after_lost_retry = state()
                assert after_lost_retry == committed, (committed, after_lost_retry)
                if postmaster_crash:
                    observations["postmaster_crash_after_commit"] = {
                        "container_killed_with": "SIGKILL",
                        "old_postmaster_start": old_postmaster,
                        "new_postmaster_start": new_postmaster,
                        "controller_exit_code": lost_ack.returncode,
                        "controller_stdout": controller_stdout,
                        "controller_stderr": controller_stderr,
                        "execute_result_received": "COMPLETED" in controller_stdout.splitlines(),
                        "durable_state_after_crash_matches_committed_state": after_crash == committed,
                        "same_lease_retry": {"returncode":lost_retry.returncode,"stdout":lost_retry.stdout,
                                             "stderr":lost_retry.stderr},
                        "retry_left_durable_state_unchanged": after_lost_retry == committed}
                    observations["entry_decision"] = "FOCUSED_POSTMASTER_CRASH_RECOVERY_QUALIFIED"
                    observations["checks"].append({
                        "name": "postmaster-crash-after-commit-idempotent-retry",
                        "result": "passed"})
                    print("PASS: committed React delivery survived SIGKILL and same-lease retry", flush=True)
                    return
                observations["lost_ack_after_commit"] = {
                    "client_disconnected_before_result_fetch": True,
                    "controller_output": controller_stdout.splitlines(),
                    "packet_level_reply_drop": transport_loss,
                    "same_lease_retry": {"returncode":lost_retry.returncode,"stdout":lost_retry.stdout,
                                         "stderr":lost_retry.stderr},
                    "retry_left_durable_state_unchanged": after_lost_retry == committed}
                fresh = committed
                observations["fresh_after_pause"] = {"before":before_fresh,"after":fresh}
                check_delivery(before_fresh,fresh,c,"APPLIED_CONTROL","CONTROL_APPLIED",generation=3)
            else:
                assert execute(c) == "COMPLETED"
        assert claim_one() == []
        after_fresh = state()
        observations["fresh_after_pause"] = {"before":before_fresh,"after":after_fresh}
        assert after_fresh["receipts"][:len(after_b["receipts"])] == after_b["receipts"]
        paused_ref = "pgreact:"+claim_b["rule_version_id"]+":"+str(claim_b["episode_id"])
        inspections = read("SET SESSION AUTHORIZATION s1_claimed_reader; SELECT jsonb_agg(jsonb_build_object('work_ref',work_ref,'outcome',delivery_outcome,"
            "'remediation',remediation_state,'reason',remediation_reason_code) ORDER BY requested_at) "
            "FROM pgreact_mdm.delivery_inspection_v1 WHERE case_key="+str(claim_b["bindings"]["case_key"]))
        assert inspections == [{"work_ref":paused_ref,"outcome":"BINDING_PAUSED","remediation":"HELD","reason":"BINDING_PAUSED"},
            {"work_ref":after_fresh["receipts"][-1]["request_body"]["work_ref"],"outcome":"APPLIED_CONTROL","remediation":"NONE","reason":None}],inspections

        # A human lowering the already-applied level cannot authorize it again,
        # even after a fresh React generation produces a different request key.
        for current in after_fresh["cases"]:
            sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
                "SELECT mdm_steward.set_case_controls("+str(current["case_key"])+",NULL,'"+current["due_at"]+"'::timestamptz,1,false,"+
                str(current["action_revision"])+",'Claimed-work cross-key human reduction')")
        paused_version = operator("pause_intent_binding",active_version)
        sql("SELECT pgreact_api.run()")
        active_version = operator("reconcile_intent_binding",paused_version)
        sql("SELECT pgreact_api.run()")
        before_lowered = state()

        # React claims first, then an authorized human changes its deadline and
        # commits while delivery is waiting on that human-held case lock.
        edit_claim, = claim_one()
        key = edit_claim["bindings"]["case_key"]
        old_case = next(c for c in before_lowered["cases"] if c["case_key"]==key)
        future = read("SELECT to_jsonb(clock_timestamp()+interval '1 hour')")
        human = start("claimed-human-edit","BEGIN; SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
            "SELECT action_revision FROM mdm_steward.set_case_controls("+str(key)+",NULL,'"+future+"'::timestamptz,1,false,"+
            str(old_case["action_revision"])+",'Claimed-work human deadline replacement');",interactive=True)
        human_lock = wait_for(lambda:(lambda a:a if a and a["state"]=="idle in transaction" else None)(
            activity("claimed-human-edit")),"human edit did not hold its case row")
        edit_delivery = start("claimed-edit-delivery","SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "
            "SELECT to_jsonb(pgreact_api.execute("+str(edit_claim["episode_id"])+",'"+worker+"','"+edit_claim["lease_token"]+"'::uuid))")
        edit_wait = wait_for(lambda:(lambda a:a if a and human_lock["pid"] in a["blockers"] else None)(
            activity("claimed-edit-delivery")),"React delivery did not wait for the human edit")
        before_replacement = state()
        replacement_process = start("claimed-binding-replace-overlap","SET SESSION AUTHORIZATION mdm_legacy_login; "
            "SET ROLE mdm_legacy_administrator; SELECT to_jsonb(b) FROM pgreact_mdm.replace_intent_binding('"+
            binding["binding_id"]+"'::uuid,"+str(binding["binding_version"])+",'s1-idle-feasibility',"
            "ARRAY['ESCALATE'],ARRAY[]::text[],NULL,2) b")
        replacement_wait = wait_for(lambda:(a if (a:=activity("claimed-binding-replace-overlap")) and
            edit_wait["pid"] in a["blockers"] else None),"replacement did not wait for the in-flight human-stale delivery")
        during_replacement = state()
        assert during_replacement == before_replacement, (before_replacement,during_replacement)
        human.stdin.write("COMMIT;\n\\q\n")
        human.stdin.flush()
        edited_revision = int(finish(human))
        assert edited_revision == old_case["action_revision"]+1
        assert json.loads(finish(edit_delivery)) == "COMPLETED"
        edited_case = {**old_case,"due_at":future,"action_revision":edited_revision}
        stale_edit = state()
        check_delivery(before_lowered,stale_edit,edit_claim,"STALE_CASE","FRESHNESS_TOKEN_MISMATCH",generation=4,current_case=edited_case)
        replacement = json.loads(finish(replacement_process))
        old_binding = read("SELECT to_jsonb(b) FROM pgreact_mdm.policy_intent_bindings b WHERE binding_id='"+binding["binding_id"]+"'::uuid")
        assert old_binding == {**binding,"enabled":False},old_binding
        new_binding = read("SELECT to_jsonb(b) FROM pgreact_mdm.policy_intent_bindings b WHERE binding_id='"+replacement["binding_id"]+"'::uuid")
        assert new_binding == {**binding,**replacement,"max_escalation_level":2,"created_at":new_binding["created_at"]},new_binding
        observations["human_edit_after_claim"] = {"claim":edit_claim,"barrier":edit_wait,"before":before_lowered,"after":stale_edit}
        observations["replacement_overlap"] = {"replacement":replacement,"old_binding":old_binding,
            "new_binding":new_binding,"delivery_barrier":edit_wait,"replacement_barrier":replacement_wait,
            "before":before_replacement,"during":during_replacement,"after":stale_edit}
        binding = new_binding
        runtime = read("SELECT runtime_version FROM pgreact_mdm.policy_intent_runtime")
        active_version = runtime
        sql("SELECT pgreact_api.run()")

        # The second human change commits before React even claims its old
        # episode. The native callback must recheck eligibility and do nothing.
        second_key = next(c["case_key"] for c in before_lowered["cases"] if c["case_key"]!=key)
        second = next(c for c in stale_edit["cases"] if c["case_key"]==second_key)
        sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
            "SELECT mdm_steward.set_case_controls("+str(second_key)+",NULL,'"+second["due_at"]+"'::timestamptz,2,false,"+
            str(second["action_revision"])+",'Human level change before claim')")
        before_edit_first = state()
        edit_first_claim, = claim_one()
        assert edit_first_claim["bindings"]["case_key"] == second_key
        assert execute(edit_first_claim) == "COMPLETED"
        after_edit_first = state()
        for name in ("cases","receipts","requests","intent_attempts","holds","source","technical_source"):
            assert after_edit_first[name] == before_edit_first[name],name
        observations["human_edit_before_claim"] = {"before":before_edit_first,"after":after_edit_first}

        sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
            "SELECT mdm_steward.set_case_controls("+str(key)+",NULL,'"+old_case["due_at"]+"'::timestamptz,1,false,"+
            str(edited_revision)+",'Authorized due-time restoration after stale request')")
        paused_version = operator("pause_intent_binding",active_version)
        sql("SELECT pgreact_api.run()")
        active_version = operator("reconcile_intent_binding",paused_version)
        sql("SELECT pgreact_api.run()")
        before_lowered = state()
        for _ in before["cases"]:
            c, = claim_one()
            assert execute(c) == "COMPLETED"
            if c["bindings"]["case_key"] == key:
                check_delivery(before_lowered,state(),c,"ACTION_DENIED","ESCALATION_LEVEL_ALREADY_APPLIED",generation=5)
        assert claim_one() == []
        terminal = state()
        for _ in range(3):
            assert read("SET SESSION AUTHORIZATION mdm_s1_runtime; SELECT pgreact_api.managed_cycle()")["state"] == "ready"
        assert state() == terminal,"later managed cycles changed terminal vectors"
        observations["cross_key_after_human_reduction"] = {"before":before_lowered,"after":terminal}

        # Distinct request keys racing for one unapplied level may apply it once.
        existing_race_keys = tuple(c["case_key"] for c in terminal["cases"])
        existing_race_key_sql = ",".join(str(case_key) for case_key in existing_race_keys)
        sql("INSERT INTO public.policy_qualification_source VALUES "
            "(1013,'Race One','race-one@example.test',statement_timestamp()),"
            "(1014,'Race One','race-pair@example.test',statement_timestamp()),"
            "(1015,'Race Two','race-two@example.test',statement_timestamp()),"
            "(1016,'Race Two','race-pair@example.test',statement_timestamp())")
        sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
            "SELECT mdm.refresh('policy_qualification','ALLOW'); RESET ROLE; RESET SESSION AUTHORIZATION")
        race_cases = read("SELECT jsonb_agg(to_jsonb(c) ORDER BY c.case_key) "
            "FROM mdm_steward.policy_cases_v1 c WHERE c.entity_name='policy_qualification' "
            "AND c.status='open' AND c.case_key NOT IN ("+existing_race_key_sql+")")
        assert len(race_cases) == 1, race_cases
        race_case, = race_cases
        race_case_key = race_case["case_key"]
        sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
            "SELECT mdm_steward.set_case_controls("+str(race_case_key)+",NULL,"
            "statement_timestamp()-interval '1 hour',1,false,"+str(race_case["action_revision"])+
            ",'Claimed-work concurrent cross-key setup'); RESET ROLE; RESET SESSION AUTHORIZATION")
        race_before = state()
        race_case = next(c for c in race_before["cases"] if c["case_key"] == race_case_key)
        assert race_case["escalation_level"] == 1, race_case
        assert not any(r["case_key"] == race_case_key and r["action"] == "ESCALATE"
            and r["outcome"] == "APPLIED_CONTROL" and r["control"]["escalation_level"] == 2
            for r in race_before["receipts"]), race_before["receipts"]

        def cross_key_submit(generation):
            evaluation_ref = "pgreact-cross-key-race-eval-"+str(generation)
            work_ref = "pgreact-cross-key-race-work-"+str(generation)
            request_key = ("pgreact_mdm.intent_request_key('"+binding["binding_id"]+
                "'::uuid,'"+binding["policy_revision"]+"',"+str(race_case_key)+","+str(generation)+","+
                str(race_case["action_revision"])+",'escalate_level_2',2)")
            return ("SELECT jsonb_build_object('request_key',encode("+request_key+",'hex'),"
                "'result',to_jsonb(receipt)) FROM mdm_steward.submit_policy_intent('"+
                binding["binding_id"]+"'::uuid,"+request_key+","+str(race_case_key)+",'ESCALATE',"
                "'{\"level\":2}'::jsonb,"+str(race_case["review_version"])+","+
                str(race_case["definition_version"])+","+str(race_case["publication_revision"])+","+
                str(race_case["stewardship_epoch"])+",decode('"+race_case["evidence_basis_digest"][2:]+
                "','hex'),"+str(race_case["action_revision"])+",decode('"+binding["policy_digest"][2:]+
                "','hex'), '"+binding["policy_revision"]+"','"+evaluation_ref+"','"+work_ref+
                "') AS receipt;")

        race_generations = (9001,9002)
        first_race = start("claimed-cross-key-race-first",
            "BEGIN; SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "+
            cross_key_submit(race_generations[0]), interactive=True)
        first_race_tx = wait_for(lambda:(lambda a:a if a and a["state"]=="idle in transaction" else None)(
            activity("claimed-cross-key-race-first")),"first cross-key submission did not hold its transaction")
        second_race = start("claimed-cross-key-race-second",
            "SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "+
            cross_key_submit(race_generations[1]))
        second_race_wait = wait_for(lambda:(lambda a:a if a and first_race_tx["pid"] in a["blockers"] else None)(
            activity("claimed-cross-key-race-second")),"second distinct-key submission did not wait on the case transaction")
        first_race.stdin.write("COMMIT;\n\\q\n")
        first_race.stdin.flush()
        first_output = finish(first_race)
        second_output = finish(second_race)
        first_response, = [json.loads(line) for line in first_output.splitlines() if line.startswith("{")]
        second_response, = [json.loads(line) for line in second_output.splitlines() if line.startswith("{")]
        assert first_response["request_key"] != second_response["request_key"], (first_response,second_response)
        before_case = race_case
        expected_control = {"assigned_queue":before_case["assigned_queue"],
            "due_at":before_case["due_at"].replace("T"," ").removesuffix(":00"),
            "escalation_level":2,"manual_assignment_protected":before_case["manual_assignment_protected"]}
        expected_first = {"receipt_id":first_response["result"]["receipt_id"],"outcome":"APPLIED_CONTROL",
            "reason_code":"CONTROL_APPLIED","case_key":race_case_key,"action_revision":before_case["action_revision"]+1,
            "control":expected_control,"resulting_publication_revision":None}
        expected_second = {"receipt_id":second_response["result"]["receipt_id"],"outcome":"STALE_CASE",
            "reason_code":"FRESHNESS_TOKEN_MISMATCH","case_key":race_case_key,
            "action_revision":before_case["action_revision"]+1,"control":expected_control,
            "resulting_publication_revision":None}
        assert first_response["result"] == expected_first, first_response
        assert second_response["result"] == expected_second, second_response
        race_after = state()
        expected_cases = copy.deepcopy(race_before["cases"])
        for case in expected_cases:
            if case["case_key"] == race_case_key:
                case.update(escalation_level=2,action_revision=before_case["action_revision"]+1)
        assert race_after["cases"] == expected_cases, race_after["cases"]
        expected_new_receipts = []
        for generation, response, result, outcome, reason in (
            (race_generations[0],first_response,expected_first,"APPLIED_CONTROL","CONTROL_APPLIED"),
            (race_generations[1],second_response,expected_second,"STALE_CASE","FRESHNESS_TOKEN_MISMATCH")):
            evaluation_ref = "pgreact-cross-key-race-eval-"+str(generation)
            work_ref = "pgreact-cross-key-race-work-"+str(generation)
            body = {"action":"ESCALATE","arguments":{"level":2},"binding_id":binding["binding_id"],
                "case_key":race_case_key,"evaluation_ref":evaluation_ref,
                "expected_action_revision":before_case["action_revision"],
                "expected_definition_version":before_case["definition_version"],
                "expected_evidence_basis_digest":before_case["evidence_basis_digest"][2:],
                "expected_policy_digest":binding["policy_digest"][2:],
                "expected_publication_revision":before_case["publication_revision"],
                "expected_review_version":before_case["review_version"],
                "expected_stewardship_epoch":before_case["stewardship_epoch"],
                "policy_revision":binding["policy_revision"],"work_ref":work_ref}
            digest = "\\x"+sql("SELECT encode(pgreact_mdm.intent_request_digest('"+
                json.dumps(body).replace("'","''")+"'::jsonb),'hex')")
            request_key = "\\x"+response["request_key"]
            receipt, = [r for r in race_after["receipts"] if r["request_key"] == request_key]
            expected_receipt = {"receipt_id":result["receipt_id"],"created_at":receipt["created_at"],
                "actor":"pgreact_mdm_worker","session_role_name":"mdm_s1_runtime",
                "selected_role_name":"pgreact_mdm_worker","binding_id":binding["binding_id"],
                "binding_version":binding["binding_version"],"case_key":race_case_key,"action":"ESCALATE",
                "action_revision":result["action_revision"],"outcome":outcome,"reason_code":reason,
                "control":expected_control,"resulting_publication_revision":None,
                "request_body":body,"request_key":request_key,"request_digest":digest}
            assert receipt == expected_receipt, receipt
            expected_new_receipts.append(receipt)
        expected_receipts = sorted(race_before["receipts"]+expected_new_receipts,
            key=lambda receipt:(receipt["created_at"],receipt["receipt_id"]))
        assert race_after["receipts"] == expected_receipts, race_after["receipts"]
        for name in ("requests","intent_attempts","work","attempts","holds","source","technical_source"):
            assert race_after[name] == race_before[name], name
        observations["concurrent_cross_key_submission"] = {"generations":race_generations,
            "first_transaction":first_race_tx,"second_blocked":second_race_wait,
            "first":first_response,"second":second_response,"before":race_before,"after":race_after}
        future_race_due = read("SELECT to_jsonb(clock_timestamp()+interval '1 hour')")
        sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
            "SELECT mdm_steward.set_case_controls("+str(race_case_key)+",NULL,'"+
            future_race_due+"'::timestamptz,2,false,"+str(expected_first["action_revision"])+
            ",'Keep concurrency fixture out of later due work'); RESET ROLE; RESET SESSION AUTHORIZATION")
        race_future = state()
        expected_future_cases = copy.deepcopy(race_after["cases"])
        for case in expected_future_cases:
            if case["case_key"] == race_case_key:
                case.update(due_at=future_race_due,action_revision=expected_first["action_revision"]+1)
        assert race_future["cases"] == expected_future_cases, race_future["cases"]
        for name in ("receipts","requests","intent_attempts","holds","source"):
            assert race_future[name] == race_after[name], name
        sql("INSERT INTO s1_claimed.cases SELECT case_key FROM mdm_steward.policy_cases_v1 "
            "WHERE case_key="+str(race_case_key)+" ON CONFLICT DO NOTHING; "
            "INSERT INTO s1_audit.source SELECT case_key,due_at FROM mdm_steward.policy_cases_v1 "
            "WHERE case_key="+str(race_case_key)+" ON CONFLICT DO NOTHING; "
            "SELECT pgreact_mdm.sync_intent_case_identities(); SELECT pgreact_api.run()")
        drain_before = state()
        assert claim_one() == [], "future-due concurrency fixture produced work"
        drained_state = state()
        for name in ("cases","receipts","requests","intent_attempts","holds","source"):
            assert drained_state[name] == race_future[name], name
        assert drained_state["work"] == drain_before["work"], drained_state["work"]
        assert drained_state["attempts"] == drain_before["attempts"], drained_state["attempts"]
        expected_technical_source = copy.deepcopy(race_future["technical_source"])
        expected_technical_source.append({"case_key":race_case_key,"deadline":future_race_due})
        expected_technical_source.sort(key=lambda row:row["case_key"])
        assert drained_state["technical_source"] == expected_technical_source, drained_state["technical_source"]
        observations["concurrent_cross_key_future_due"] = {
            "future_control_state":race_future,"before":drain_before,"after":drained_state}
        terminal = drained_state

        # Move a queued case's deadline out before claim. The old episode may
        # finish, but it must not submit an escalation from its stale due snapshot.
        existing_keys = tuple(c["case_key"] for c in terminal["cases"])
        existing_key_sql = ",".join(str(case_key) for case_key in existing_keys)
        sql("INSERT INTO public.policy_qualification_source VALUES "
            "(1009,'Deadline One','deadline-one@example.test',statement_timestamp()),"
            "(1010,'Deadline One','deadline-pair@example.test',statement_timestamp()),"
            "(1011,'Deadline Two','deadline-two@example.test',statement_timestamp()),"
            "(1012,'Deadline Two','deadline-pair@example.test',statement_timestamp())")
        sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
            "SELECT mdm.refresh('policy_qualification','ALLOW'); RESET ROLE; RESET SESSION AUTHORIZATION")
        deadline_cases = read("SELECT jsonb_agg(to_jsonb(c) ORDER BY c.case_key) "
            "FROM mdm_steward.policy_cases_v1 c WHERE c.entity_name='policy_qualification' "
            "AND c.status='open' AND c.case_key NOT IN ("+existing_key_sql+")")
        assert len(deadline_cases) == 1, deadline_cases
        deadline_case, = deadline_cases
        past_deadline = read("SELECT to_jsonb(clock_timestamp()-interval '1 hour')")
        sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
            "SELECT mdm_steward.set_case_controls("+str(deadline_case["case_key"])+",NULL,'"+
            past_deadline+"'::timestamptz,1,false,"+str(deadline_case["action_revision"])+
            ",'Queue deadline before replacement')")
        sql("INSERT INTO s1_claimed.cases SELECT case_key FROM mdm_steward.policy_cases_v1 "
            "WHERE case_key="+str(deadline_case["case_key"])+" ON CONFLICT DO NOTHING; "
            "INSERT INTO s1_audit.source SELECT case_key,due_at FROM mdm_steward.policy_cases_v1 "
            "WHERE case_key="+str(deadline_case["case_key"])+" ON CONFLICT DO NOTHING; "
            "SELECT pgreact_mdm.sync_intent_case_identities(); SELECT pgreact_api.run()")
        queued_deadline_state = state()
        queued_deadline_case = next(c for c in queued_deadline_state["cases"]
            if c["case_key"] == deadline_case["case_key"])
        assert queued_deadline_case["due_at"] == past_deadline, queued_deadline_case
        pending_deadline_work = [w for w in queued_deadline_state["work"]
            if w["name"] == "s1-claimed-work" and w["state"] == "PENDING"]
        assert len(pending_deadline_work) == 1, pending_deadline_work
        future_deadline = read("SELECT to_jsonb(clock_timestamp()+interval '1 hour')")
        sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
            "SELECT mdm_steward.set_case_controls("+str(deadline_case["case_key"])+",NULL,'"+
            future_deadline+"'::timestamptz,1,false,"+str(queued_deadline_case["action_revision"])+
            ",'Replace queued deadline before claim')")
        replaced_deadline_state = state()
        replaced_deadline_case = next(c for c in replaced_deadline_state["cases"]
            if c["case_key"] == deadline_case["case_key"])
        expected_deadline_case = {**queued_deadline_case,"due_at":future_deadline,
            "action_revision":queued_deadline_case["action_revision"]+1}
        assert replaced_deadline_case == expected_deadline_case, replaced_deadline_case
        still_queued = next(w for w in replaced_deadline_state["work"]
            if w["work_id"] == pending_deadline_work[0]["work_id"])
        assert still_queued["state"] == "PENDING" and still_queued["claimable"], still_queued
        deadline_claim, = claim_one()
        assert deadline_claim["bindings"]["case_key"] == deadline_case["case_key"]
        assert deadline_claim["episode_id"] == int(pending_deadline_work[0]["work_id"])
        assert execute(deadline_claim) == "COMPLETED"
        after_deadline_delivery = state()
        for name in ("cases","receipts","requests","intent_attempts","holds","source","technical_source"):
            assert after_deadline_delivery[name] == replaced_deadline_state[name], name
        observations["queued_deadline_replacement_before_claim"] = {
            "queued_state":queued_deadline_state,"replaced_deadline_state":replaced_deadline_state,
            "claim":deadline_claim,"after_delivery":after_deadline_delivery}

        # Earlier matrix cases already applied level 2; use a fresh claimed
        # case so that history cannot mask the replacement result.
        existing_keys = tuple(c["case_key"] for c in after_deadline_delivery["cases"])
        existing_key_sql = ",".join(str(case_key) for case_key in existing_keys)
        sql("INSERT INTO public.policy_qualification_source VALUES "
            "(1005,'Replacement One','replacement-one@example.test',statement_timestamp()),"
            "(1006,'Replacement One','replacement-pair@example.test',statement_timestamp()),"
            "(1007,'Replacement Two','replacement-two@example.test',statement_timestamp()),"
            "(1008,'Replacement Two','replacement-pair@example.test',statement_timestamp())")
        sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
            "SELECT mdm.refresh('policy_qualification','ALLOW'); RESET ROLE; RESET SESSION AUTHORIZATION")
        existing_key_sql = ",".join(str(case_key) for case_key in existing_keys)
        fresh_cases = read("SELECT jsonb_agg(to_jsonb(c) ORDER BY c.case_key) "
            "FROM mdm_steward.policy_cases_v1 c WHERE c.entity_name='policy_qualification' "
            "AND c.status='open' AND c.case_key NOT IN ("+existing_key_sql+")")
        assert len(fresh_cases) == 1, fresh_cases
        replacement_old_case, = fresh_cases
        replacement_queued_case = next(c for c in terminal["cases"] if c["case_key"]==key)
        replacement_future_case = next(c for c in terminal["cases"] if c["case_key"]==second_key)
        replacement_old_key = replacement_old_case["case_key"]
        replacement_queued_key = replacement_queued_case["case_key"]
        sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
            "SELECT mdm_steward.set_case_controls("+str(replacement_old_key)+",NULL,"
            "statement_timestamp()-interval '2 hours',1,false,"+
            str(replacement_old_case["action_revision"])+",'Fresh replacement claim setup'); "
            "SELECT mdm_steward.set_case_controls("+str(replacement_queued_key)+",NULL,"
            "statement_timestamp()+interval '1 hour',1,false,"+
            str(replacement_queued_case["action_revision"])+",'Keep earlier case pending but not due'); "
            "SELECT mdm_steward.set_case_controls("+str(replacement_future_case["case_key"])+",NULL,"
            "statement_timestamp()+interval '1 hour',1,false,"+
            str(replacement_future_case["action_revision"])+",'Keep third case out of replacement queue')")
        sql("INSERT INTO s1_claimed.cases SELECT case_key FROM mdm_steward.policy_cases_v1 "
            "WHERE case_key="+str(replacement_old_key)+" ON CONFLICT DO NOTHING; "
            "INSERT INTO s1_audit.source SELECT case_key,due_at FROM mdm_steward.policy_cases_v1 "
            "WHERE case_key="+str(replacement_old_key)+" ON CONFLICT DO NOTHING; "
            "SELECT pgreact_mdm.sync_intent_case_identities()")
        replacement_queued_case = next(c for c in state()["cases"]
            if c["case_key"]==replacement_queued_key)
        observations["replacement_fresh_cases"] = {
            "claimed_first":replacement_old_case,"queued_second":replacement_queued_case}
        paused_version = operator("pause_intent_binding",active_version)
        sql("SELECT pgreact_api.run()")
        operator("reconcile_intent_binding",paused_version)
        sql("SELECT pgreact_api.run()")
        old_claim, = claim_one()
        assert old_claim["bindings"]["case_key"] == replacement_old_key
        before_replaced = state()
        first_after_setup = next(c for c in before_replaced["cases"] if c["case_key"]==replacement_old_key)
        assert first_after_setup["action_revision"] == replacement_old_case["action_revision"]+1
        assert old_claim["bindings"]["action_revision"] == first_after_setup["action_revision"]
        react_episode = read("SELECT jsonb_build_object('agenda',to_jsonb(a),'activation',to_jsonb(s)) "
            "FROM pgreact_internal.agenda a JOIN pgreact_internal.activation_state s "
            "USING(rule_version_id,activation_id) WHERE a.episode_id="+str(old_claim["episode_id"]))
        assert react_episode["agenda"]["state"] == "LEASED", react_episode
        assert react_episode["agenda"]["event_kind"] == "ACTIVATE", react_episode
        assert (react_episode["activation"]["active"] and
            react_episode["agenda"]["activation_generation"] ==
            react_episode["activation"]["generation"]), react_episode
        replacement_generation = react_episode["agenda"]["activation_generation"]
        assert not any(r["case_key"]==replacement_old_key for r in before_replaced["requests"])
        replacement_claim = {"claim":old_claim,"before":before_replaced,
            "react_episode":react_episode,"expected_generation":replacement_generation}
        observations["replacement_claim_first"] = replacement_claim
        replacement_process = start("claimed-binding-replace-first",
            "BEGIN; SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
            "SELECT to_jsonb(b) FROM pgreact_mdm.replace_intent_binding('"+binding["binding_id"]+"'::uuid,"+
            str(binding["binding_version"])+",'s1-idle-feasibility',ARRAY['ESCALATE'],ARRAY[]::text[],NULL,1) b;",
            interactive=True)
        replacement_barrier = wait_for(lambda:(a if (a:=activity("claimed-binding-replace-first")) and
            a["state"]=="idle in transaction" else None),"replacement did not hold its binding lock")
        replacement_claim["replacement_barrier"] = replacement_barrier
        old_delivery = start("claimed-replaced-delivery","SET SESSION AUTHORIZATION mdm_s1_runtime; "
            "SET ROLE pgreact_mdm_worker; SELECT to_jsonb(pgreact_api.execute("+str(old_claim["episode_id"])+",'"+
            worker+"','"+old_claim["lease_token"]+"'::uuid))")
        def delivery_status():
            current = activity("claimed-replaced-delivery")
            if current and (replacement_barrier["pid"] in current["blockers"] or
                    current["wait_event_type"] == "Lock"):
                return {"activity":current}
            if old_delivery.poll() is not None:
                stdout, stderr = old_delivery.communicate()
                return {"activity":current,"returncode":old_delivery.returncode,
                    "stdout":stdout,"stderr":stderr}
            return None
        delivery_observation = wait_for(delivery_status,
            "old-claim delivery did not wait for the replacement transaction")
        replacement_claim["delivery_observation"] = delivery_observation
        if not (delivery_observation["activity"] and
                replacement_barrier["pid"] in delivery_observation["activity"]["blockers"]):
            replacement_claim["state_after_early_delivery"] = state()
            raise AssertionError(delivery_observation)
        delivery_barrier = delivery_observation["activity"]
        during_replacement = state()
        assert during_replacement == before_replaced, (before_replaced,during_replacement)
        replacement_process.stdin.write("COMMIT;\n\\q\n")
        replacement_process.stdin.flush()
        replacement = json.loads(finish(replacement_process))
        assert json.loads(finish(old_delivery)) == "COMPLETED"
        after_replaced_delivery = state()
        check_delivery(before_replaced,after_replaced_delivery,old_claim,
            "BINDING_REPLACED","BINDING_REPLACED",generation=replacement_generation)
        no_due_claim = claim_one()
        assert no_due_claim == []
        replaced = state()
        expected_work = copy.deepcopy(before_replaced["work"])
        expected_attempts = copy.deepcopy(before_replaced["attempts"])
        for c in (old_claim,):
            episode_id = int(c["episode_id"])
            work, = [w for w in replaced["work"] if w["work_id"] == str(episode_id)]
            expected_work_row = {"work_id":str(episode_id),"kind":"rule","name":"s1-claimed-work",
                "version":"1","state":"COMPLETED","claimable":False,"updated_at":work["updated_at"]}
            assert work == expected_work_row, work
            index = next(i for i,w in enumerate(expected_work) if w["work_id"] == str(episode_id))
            expected_work[index] = expected_work_row
            attempt, = [a for a in replaced["attempts"] if a["episode_id"] == episode_id]
            expected_attempt = {**{k:attempt[k] for k in ("execution_id","started_at","finished_at")},
                "episode_id":episode_id,"worker_id":worker,"attempt_no":1,"status":"COMPLETED",
                "error_message":None,"error_code":None,"event_kind":"ACTIVATE","name":"s1-claimed-work"}
            assert attempt == expected_attempt, attempt
            expected_attempts.append(expected_attempt)
        assert replaced["work"] == expected_work, replaced["work"]
        assert replaced["attempts"] == expected_attempts, replaced["attempts"]
        for name in ("cases","receipts","requests","intent_attempts","holds","source","technical_source"):
            assert replaced[name] == after_replaced_delivery[name],name
        old_binding = read("SELECT to_jsonb(b) FROM pgreact_mdm.policy_intent_bindings b WHERE binding_id='"+binding["binding_id"]+"'::uuid")
        assert old_binding == {**binding,"enabled":False},old_binding
        new_binding = read("SELECT to_jsonb(b) FROM pgreact_mdm.policy_intent_bindings b WHERE binding_id='"+replacement["binding_id"]+"'::uuid")
        assert new_binding == {**binding,**replacement,"max_escalation_level":1,"created_at":new_binding["created_at"]},new_binding
        observations["replacement_claim_orders"] = {"claimed_before":old_claim,"claimed_after":no_due_claim,
            "replacement_barrier":replacement_barrier,"delivery_barrier":delivery_barrier,
            "old_binding":old_binding,"new_binding":new_binding,"before":before_replaced,
            "after_replaced_delivery":after_replaced_delivery,"after":replaced}
        for _ in range(3):
            assert read("SET SESSION AUTHORIZATION mdm_s1_runtime; SELECT pgreact_api.managed_cycle()")["state"] == "ready"
        assert state() == replaced,"managed cycles ignored replacement or replayed old work"

        # Use the final isolated case to hit the gap between candidate
        # validation and request-revision selection without changing earlier
        # matrix expectations.
        replacement_binding = json.loads(sql("SET SESSION AUTHORIZATION mdm_legacy_login; "
            "SET ROLE mdm_legacy_administrator; SELECT to_jsonb(b) FROM pgreact_mdm.replace_intent_binding('"+
            new_binding["binding_id"]+"'::uuid,"+str(new_binding["binding_version"])+
            ",'s1-idle-feasibility',ARRAY['ESCALATE'],ARRAY[]::text[],NULL,2) b; "
            "RESET ROLE; RESET SESSION AUTHORIZATION"))
        binding = read("SELECT to_jsonb(b) FROM pgreact_mdm.policy_intent_bindings b WHERE binding_id='"+
            replacement_binding["binding_id"]+"'::uuid")
        runtime = read("SELECT runtime_version FROM pgreact_mdm.policy_intent_runtime")
        active_version = runtime
        race_existing_keys = tuple(c["case_key"] for c in state()["cases"])
        race_existing_sql = ",".join(str(case_key) for case_key in race_existing_keys)
        sql("INSERT INTO public.policy_qualification_source VALUES "
            "(1017,'Validation Race One','validation-race-one@example.test',statement_timestamp()),"
            "(1018,'Validation Race One','validation-race-pair@example.test',statement_timestamp()),"
            "(1019,'Validation Race Two','validation-race-two@example.test',statement_timestamp()),"
            "(1020,'Validation Race Two','validation-race-pair@example.test',statement_timestamp())")
        sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
            "SELECT mdm.refresh('policy_qualification','ALLOW'); RESET ROLE; RESET SESSION AUTHORIZATION")
        race_new_cases = read("SELECT jsonb_agg(to_jsonb(c) ORDER BY c.case_key) "
            "FROM mdm_steward.policy_cases_v1 c WHERE c.entity_name='policy_qualification' "
            "AND c.status='open' AND c.case_key NOT IN ("+race_existing_sql+")")
        assert len(race_new_cases) == 1, race_new_cases
        race_seed_case, = race_new_cases
        sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
            "SELECT mdm_steward.set_case_controls("+str(race_seed_case["case_key"])+",NULL,"
            "statement_timestamp()-interval '1 hour',1,false,"+str(race_seed_case["action_revision"])+
            ",'Inter-statement validation race setup'); "
            "RESET ROLE; RESET SESSION AUTHORIZATION")
        sql("INSERT INTO s1_claimed.cases SELECT "+str(race_seed_case["case_key"])+" "
            "ON CONFLICT DO NOTHING; INSERT INTO s1_audit.source "
            "SELECT case_key,due_at FROM mdm_steward.policy_cases_v1 WHERE case_key="+
            str(race_seed_case["case_key"])+" ON CONFLICT DO NOTHING; "
            "SELECT pgreact_mdm.sync_intent_case_identities()")
        sql("SELECT pgreact_api.run()")
        race_claim, = claim_one()
        race_before = state()
        race_case = next(c for c in race_before["cases"]
            if c["case_key"] == race_claim["bindings"]["case_key"])
        race_generation = int(sql("SELECT activation_generation FROM pgreact_internal.agenda "
            "WHERE episode_id="+str(race_claim["episode_id"])))
        race_gate_lock = (578804123, 20261102)
        sql("ALTER FUNCTION pgreact_mdm.intent_escalation_candidate_for_case(uuid,bigint) "
            "RENAME TO intent_escalation_candidate_for_case_race_original; "
            "CREATE FUNCTION pgreact_mdm.intent_escalation_candidate_for_case("
            "target_binding_id uuid, target_case_key bigint) RETURNS jsonb "
            "LANGUAGE plpgsql VOLATILE SECURITY DEFINER "
            "SET search_path = pg_catalog, pg_temp AS $race_gate$ "
            "DECLARE calls integer; result jsonb; BEGIN "
            "result := pgreact_mdm.intent_escalation_candidate_for_case_race_original($1,$2); "
            "calls := COALESCE(NULLIF(current_setting('s1_claimed.validation_gate_calls',true),''),'0')::integer+1; "
            "PERFORM set_config('s1_claimed.validation_gate_calls',calls::text,true); "
            "IF calls = 3 AND current_setting('s1_claimed.validation_gate',true) = 'on' THEN "
            "PERFORM pg_catalog.pg_advisory_lock("+str(race_gate_lock[0])+","+
            str(race_gate_lock[1])+'); END IF; RETURN result; END $race_gate$; '
            "ALTER FUNCTION pgreact_mdm.intent_escalation_candidate_for_case(uuid,bigint) OWNER TO mdm_helper_owner; "
            "REVOKE ALL ON FUNCTION pgreact_mdm.intent_escalation_candidate_for_case(uuid,bigint) FROM PUBLIC; "
            "GRANT EXECUTE ON FUNCTION pgreact_mdm.intent_escalation_candidate_for_case(uuid,bigint) "
            "TO pgreact_mdm_worker, mdm_s1_runner; "
            "DO $recompile$ DECLARE definition text; BEGIN "
            "definition := pg_catalog.pg_get_functiondef('pgreact_mdm.submit_intent(pgreact.activation_context,jsonb)'::regprocedure); "
            "EXECUTE definition; "
            "definition := pg_catalog.pg_get_functiondef('pgreact_mdm.submit_escalation_intent(pgreact.activation_context,pgreact_mdm.intent_deployer_policy_cases_v1)'::regprocedure); "
            "EXECUTE definition; END $recompile$")
        validation_gate_installed = True
        gated_candidate = read("SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "
            "SELECT pgreact_mdm.intent_escalation_candidate_for_case('"+binding["binding_id"]+
            "'::uuid,"+str(race_case["case_key"])+"); RESET ROLE; RESET SESSION AUTHORIZATION")
        assert gated_candidate and gated_candidate["arguments"] == {"level":2}, gated_candidate
        validation_gate_controller = start("claimed-validation-gate-holder",
            "SELECT pg_catalog.pg_advisory_lock("+str(race_gate_lock[0])+","+
            str(race_gate_lock[1])+");", interactive=True)
        gate_holder = wait_for(lambda:(lambda a:a if a and a["state"] == "idle" else None)(
            activity("claimed-validation-gate-holder")),
            "validation race controller did not acquire its advisory lock")
        gate_worker_query = ("BEGIN; SET SESSION AUTHORIZATION mdm_s1_runtime; "
            "SET ROLE pgreact_mdm_worker; SET LOCAL s1_claimed.validation_gate='on'; "
            "SELECT to_jsonb(pgreact_api.execute("+str(race_claim["episode_id"])+",'"+
            worker+"','"+race_claim["lease_token"]+"'::uuid)); COMMIT")
        gate_delivery = start("claimed-validation-delivery",gate_worker_query)
        def validation_gate_status():
            current = activity("claimed-validation-delivery")
            if current and gate_holder["pid"] in current["blockers"]:
                return current
            if gate_delivery.poll() is not None:
                stdout, stderr = gate_delivery.communicate()
                failed_attempts = [attempt for attempt in state()["attempts"]
                    if attempt["episode_id"] == int(race_claim["episode_id"])]
                raise AssertionError(("delivery exited before validation barrier",
                    gate_delivery.returncode,stdout,stderr,current,failed_attempts))
            return None
        gate_wait = wait_for(validation_gate_status,
            "candidate validation did not reach the controlled inter-statement barrier")
        assert gate_wait["wait_event_type"] == "Lock", gate_wait
        race_future = read("SELECT to_jsonb(clock_timestamp()+interval '1 hour')")
        race_revision = int(sql("SET SESSION AUTHORIZATION mdm_legacy_login; "
            "SET ROLE mdm_legacy_administrator; SELECT action_revision FROM mdm_steward.set_case_controls("+
            str(race_case["case_key"])+",NULL,'"+race_future+"'::timestamptz,1,false,"+
            str(race_case["action_revision"])+",'Inter-statement validation race'); "
            "RESET ROLE; RESET SESSION AUTHORIZATION"))
        assert race_revision == race_case["action_revision"]+1, race_revision
        validation_gate_controller.stdin.write(
            "SELECT pg_catalog.pg_advisory_unlock("+str(race_gate_lock[0])+","+
            str(race_gate_lock[1])+ ");\n\\q\n")
        validation_gate_controller.stdin.flush()
        assert finish(validation_gate_controller) == "t"
        assert json.loads(finish(gate_delivery)) == "COMPLETED"
        race_after = state()
        edited_race_case = {**race_case,"due_at":race_future,"action_revision":race_revision}
        expected_race_cases = copy.deepcopy(race_before["cases"])
        for case in expected_race_cases:
            if case["case_key"] == race_case["case_key"]:
                case.update(edited_race_case)
        assert race_after["cases"] == expected_race_cases, race_after["cases"]
        for name in ("receipts","requests","intent_attempts","holds","source","technical_source"):
            assert race_after[name] == race_before[name], name
        race_work, = [work for work in race_after["work"]
            if work["work_id"] == str(race_claim["episode_id"])]
        expected_race_work = {"work_id":str(race_claim["episode_id"]),"kind":"rule",
            "name":"s1-claimed-work","version":"1","state":"COMPLETED",
            "claimable":False,"updated_at":race_work["updated_at"]}
        expected_race_works = copy.deepcopy(race_before["work"])
        race_work_index = next(i for i,work in enumerate(expected_race_works)
            if work["work_id"] == str(race_claim["episode_id"]))
        expected_race_works[race_work_index] = expected_race_work
        assert race_after["work"] == expected_race_works, race_after["work"]
        race_attempt, = [attempt for attempt in race_after["attempts"]
            if attempt["episode_id"] == int(race_claim["episode_id"])]
        expected_race_attempt = {**{key:race_attempt[key]
            for key in ("execution_id","started_at","finished_at")},
            "episode_id":int(race_claim["episode_id"]),"worker_id":worker,"attempt_no":1,
            "status":"COMPLETED","error_message":None,"error_code":None,
            "event_kind":"ACTIVATE","name":"s1-claimed-work"}
        assert race_attempt == expected_race_attempt, race_attempt
        assert race_after["attempts"] == sorted(race_before["attempts"]+[race_attempt],
            key=lambda attempt:attempt["execution_id"]), race_after["attempts"]
        race_work_ref = "pgreact:"+race_claim["rule_version_id"]+":"+str(race_claim["episode_id"])
        assert not any(request["work_ref"] == race_work_ref for request in race_after["requests"])
        assert next(c for c in race_after["cases"] if c["case_key"] == race_case["case_key"])[
            "escalation_level"] == race_case["escalation_level"], race_after
        observations["candidate_validation_human_edit_race"] = {
            "claim":race_claim,"barrier":gate_wait,"before":race_before,
            "edited_revision":race_revision,"after":race_after,
            "result":"human edit preserved; stale escalation was not enqueued"}
        observations["checks"].append({"name":"candidate-validation-human-edit-interstatement-race",
            "result":"passed"})
        sql("DROP FUNCTION pgreact_mdm.intent_escalation_candidate_for_case(uuid,bigint); "
            "ALTER FUNCTION pgreact_mdm.intent_escalation_candidate_for_case_race_original(uuid,bigint) "
            "RENAME TO intent_escalation_candidate_for_case")
        validation_gate_installed = False

        expected_outcomes = {"PENDING","APPLIED_CONTROL","BINDING_PAUSED","BINDING_REPLACED","STALE_CASE","ACTION_DENIED"}
        actual_outcomes = {vector["expected"]["delivery_outcome"]
            for vector in observations["delivery_inspection_vectors"]}
        assert expected_outcomes <= actual_outcomes, actual_outcomes
        assert all(vector["expected"] == vector["actual"]
            for vector in observations["delivery_inspection_vectors"])
        observations["entry_decision"] = ("FOCUSED_PACKET_LEVEL_ACK_LOSS_QUALIFIED"
            if transport_loss_target_port is not None else "FOCUSED_CLAIMED_PAUSE_QUALIFIED")
        observations["checks"].extend({"name":name,"result":"passed"} for name in (
            "concurrent-public-claims-single-lease","committed-public-claim-race","commit-failure-atomic-retry","claimed-pause-barrier","pause-first-runtime-freshness","paused-before-claim",
            "human-edit-claim-orders","queued-deadline-replacement-before-claim","binding-replacement-claim-orders",
            "fresh-after-terminal-pause","cross-key-after-human-reduction","concurrent-cross-key-submission",
            "delivery-inspection-output-matrix","delivery-inspection-schema-usage-boundary",
            "read-only-route-explanation",
            "client-disconnect-after-commit-idempotent-retry"))
        if transport_loss_target_port is not None:
            observations["checks"].append({"name":"packet-level-post-commit-ack-loss-retry","result":"passed"})
            print("PASS: post-commit PostgreSQL reply dropped in transit; same-lease retry was rejected", flush=True)
        else:
            print("PASS: concurrent claims and claimed-work pause/edit/deadline/replacement matrix", flush=True)
    finally:
        sql("DROP TRIGGER IF EXISTS s1_claimed_commit_failure ON pgreact_internal.agenda; "
            "DROP FUNCTION IF EXISTS s1_claimed.fail_commit()")
        sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name IN "
            "('claimed-commit-failure','claimed-case-holder','claimed-delivery','claimed-pause','claimed-pause-first','claimed-delivery-b',"
            "'claimed-validation-gate-holder','claimed-validation-delivery',"
            "'claimed-human-edit','claimed-edit-delivery','claimed-binding-replace-overlap','claimed-binding-replace-first',"
            "'claimed-replaced-delivery','claimed-lost-ack-controller',"
            "'claimed-lost-ack-worker','claimed-lost-ack-retry','claimed-concurrent-claim-first',"
            "'claimed-concurrent-claim-second','claimed-concurrent-commit-first',"
            "'claimed-concurrent-commit-second','claimed-cross-key-race-first',"
            "'claimed-cross-key-race-second') AND pid<>pg_backend_pid()")
        if validation_gate_installed:
            sql("DROP FUNCTION pgreact_mdm.intent_escalation_candidate_for_case(uuid,bigint); "
                "ALTER FUNCTION pgreact_mdm.intent_escalation_candidate_for_case_race_original(uuid,bigint) "
                "RENAME TO intent_escalation_candidate_for_case")
            validation_gate_installed = False
        restore_committed_claims(commit_agenda_before)
        if transport_proxy is not None:
            transport_proxy.close()
        for process in processes:
            if process.poll() is None:
                process.communicate(timeout=35)
