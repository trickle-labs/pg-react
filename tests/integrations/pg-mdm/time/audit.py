#!/usr/bin/env python3
"""Run the S1 entry audit in one disposable joint-stack container."""
import contextlib
import copy
import datetime
import hashlib
import importlib.util
import io
import json
import os
import queue
import select
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import types
import uuid
import zipfile
from pathlib import Path


MIN_BOUNDED_PRODUCER_FREE_BYTES = 10 * 1024**3


def require_disk_reserve(path, mode):
    probe = Path(path)
    while not probe.exists() and probe.parent != probe:
        probe = probe.parent
    free_bytes = shutil.disk_usage(probe).free
    if free_bytes < MIN_BOUNDED_PRODUCER_FREE_BYTES:
        raise SystemExit(
            f"ERROR: {mode} requires at least 10 GiB free; "
            f"{free_bytes} bytes are free at {probe}")
    return {
        "checked_path": str(probe),
        "free_bytes": free_bytes,
        "minimum_free_bytes": MIN_BOUNDED_PRODUCER_FREE_BYTES,
    }


def timestamp(value):
    value = value.replace(" ", "T", 1)
    if len(value) >= 3 and value[-3] in "+-" and value[-2:].isdigit():
        value += ":00"
    try:
        return datetime.datetime.fromisoformat(value)
    except ValueError:
        layout = "%Y-%m-%dT%H:%M:%S.%f%z" if "." in value else "%Y-%m-%dT%H:%M:%S%z"
        return datetime.datetime.strptime(value, layout)


def qualify_bounded_producer_backpressure(root):
    producer_path = root / "integrations/pg-mdm/bounded_refresh_producer.py"
    spec = importlib.util.spec_from_file_location("bounded_refresh_producer_audit", producer_path)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load bounded producer from " + str(producer_path))
    producer = importlib.util.module_from_spec(spec)
    previous_bytecode_setting = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        spec.loader.exec_module(producer)
    finally:
        sys.dont_write_bytecode = previous_bytecode_setting
    record_six_enqueued = threading.Event()
    record_seven_put_attempted = threading.Event()
    queues = []

    class ProbeQueue(queue.Queue):
        def __init__(self, maxsize=0):
            super().__init__(maxsize=1)
            queues.append(self)

        def put(self, item, block=True, timeout=None):
            record_id = item[1][0][0] if item[0] == "record" else None
            if record_id == 7:
                record_seven_put_attempted.set()
            super().put(item, block, timeout)
            if record_id == 6:
                record_six_enqueued.set()

        def get(self, block=True, timeout=None):
            item = super().get(block, timeout)
            if item[0] == "record" and item[1][0][0] == 5:
                assert record_six_enqueued.wait(5), "queue did not stage admission 6"
                assert record_seven_put_attempted.wait(5), "offerer did not reach blocked admission 7"
            return item

    producer.queue = types.SimpleNamespace(Queue=ProbeQueue, Full=queue.Full)
    producer.shutil = types.SimpleNamespace(which=lambda name: "/fake/psql")
    producer.database_identity = lambda *args, **kwargs: ("audit_db", "audit-cluster")
    source_calls = []
    refresh_calls = []

    def source_transaction(*args, **kwargs):
        source_calls.append(args[-1])
        return 1000 + len(source_calls), "source_role", "audit_db", "audit-cluster"

    def refresh_transaction(*args, **kwargs):
        refresh_calls.append(args)
        return 2000 + len(refresh_calls), "refresh_role", "audit_db", "audit-cluster", '{"changed": true}'

    producer.source_transaction = source_transaction
    producer.refresh_transaction = refresh_transaction
    records = [{"id": record_id} for record_id in range(1, 8)]
    output = io.StringIO()
    failures = []
    with tempfile.TemporaryDirectory(prefix="pg-mdm-producer-lock-order-") as temp_dir:
        input_path = Path(temp_dir) / "admissions.jsonl"
        input_path.write_text("".join(json.dumps(record) + "\n" for record in records))
        args = types.SimpleNamespace(source_service="source", refresh_service="refresh",
            entity="audit_entity", policy="ALLOW", batch_size=5, rate_per_minute=0,
            table="public.source", columns="id", key_columns="id", input=str(input_path),
            emit_admission_events=True)

        def execute():
            try:
                with contextlib.redirect_stdout(output):
                    producer.run(args)
            except Exception as error:  # noqa: BLE001 - relay worker failures to the test thread
                failures.append(error)

        runner = threading.Thread(target=execute, name="bounded-producer-lock-order-audit", daemon=True)
        runner.start()
        runner.join(5)
        if runner.is_alive():
            try:
                queues[0].get_nowait()
            except queue.Empty:
                pass
            runner.join(5)
            raise AssertionError("telemetry deadlocked when the bounded admission queue was full")
        assert not failures, failures
    events = [json.loads(line) for line in output.getvalue().splitlines() if line.strip()]
    admission_events = [event for event in events if event["event"] == "admission_offered"]
    batch_starts = [event for event in events if event["event"] == "source_batch_started"]
    batch_completions = [event for event in events if event["event"] == "batch_complete"]
    summary = events[-1]
    assert len(events) == 12, events
    assert {event["event"] for event in events} == {
        "admission_offered", "source_batch_started", "batch_complete", "producer_complete"}, events
    assert [event["admission"] for event in admission_events] == list(range(1, 8)), events
    assert [(event["batch"], event["admissions"], event["source_rows"])
        for event in batch_starts] == [(1, 5, 5), (2, 2, 2)], batch_starts
    assert [(event["batch"], event["admissions"], event["source_rows"])
        for event in batch_completions] == [(1, 5, 5), (2, 2, 2)], batch_completions
    assert all(start["started_at"] and start["started_offset_seconds"] >= 0
        for start in batch_starts), batch_starts
    for batch_number, last_admission in ((1, 5), (2, 7)):
        start_index = events.index(next(event for event in batch_starts
            if event["batch"] == batch_number))
        offered_before_start = {event["admission"] for event in events[:start_index]
            if event["event"] == "admission_offered"}
        assert set(range(1, last_admission + 1)) <= offered_before_start, events
    assert all(batch["source_txid"] != batch["refresh_txid"]
        and batch["source_database"] == batch["refresh_database"] == "audit_db"
        for batch in batch_completions), batch_completions
    assert (summary["event"], summary["admissions"], summary["source_rows"],
        summary["offered_admissions"], summary["batch_size_limit"],
        summary["batches"], summary["refresh_calls"]) == (
            "producer_complete", 7, 7, 7, 5, 2, 2), summary
    assert len(source_calls) == len(refresh_calls) == 2, (source_calls, refresh_calls)
    assert source_calls == [[[1], [2], [3], [4], [5]], [[6], [7]]], source_calls
    return {"saturated_queue_size": 1, "admissions": 7, "batches": 2,
        "telemetry_events_ordered_before_batch_start": True,
        "source_and_refresh_transactions_distinct": True}


def qualify_bounded_producer_admission_bounds(root):
    producer_path = root / "integrations/pg-mdm/bounded_refresh_producer.py"
    spec = importlib.util.spec_from_file_location("bounded_producer_admission_bounds_audit", producer_path)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load bounded producer from " + str(producer_path))
    producer = importlib.util.module_from_spec(spec)
    previous_bytecode_setting = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        spec.loader.exec_module(producer)
    finally:
        sys.dont_write_bytecode = previous_bytecode_setting
    envelope = json.loads((root / "plans/v0.49-supported-operating-envelope.json").read_text())
    intake = envelope["intake"]
    assert (producer.MAX_ADMISSIONS_PER_RUN, producer.MAX_ADMISSIONS_PER_REFRESH,
        producer.MAX_SOURCE_ROWS_PER_ADMISSION,
        producer.MAX_ADMISSION_JSONL_BYTES, producer.MAX_INPUT_JSONL_BYTES) == (
            intake["producer_admissions_per_invocation_max"], intake["admissions_per_refresh"],
            intake["source_rows_per_admission_max"],
            intake["jsonl_payload_utf8_bytes_per_admission_max_excluding_line_ending"],
            intake["jsonl_input_bytes_per_invocation_max"]), intake
    columns = ["id", "name"]
    keys = ["id"]
    rows = [{"id": index, "name": "case-" + str(index)} for index in range(1, 6)]
    accepted = producer.load_admission(json.dumps({"rows": rows[:4]}), 7, columns, keys)
    assert accepted == [[1, "case-1"], [2, "case-2"], [3, "case-3"], [4, "case-4"]], accepted
    valid_line = b'{"id":1,"name":"x"}'
    at_byte_limit = valid_line + b" " * (producer.MAX_ADMISSION_JSONL_BYTES - len(valid_line))
    decoded = producer.decode_admission_line(at_byte_limit + b"\r\n", 8)
    assert len(decoded.encode("utf-8")) == producer.MAX_ADMISSION_JSONL_BYTES, len(decoded)
    assert producer.load_admission(decoded, 8, columns, keys) == [[1, "x"]]
    calls = []
    producer.shutil = types.SimpleNamespace(which=lambda name: "/fake/psql")
    producer.database_identity = lambda *args, **kwargs: (
        calls.append("identity") or ("audit_db", "audit-system-id"))
    producer.source_transaction = lambda *args, **kwargs: (
        calls.append("source") or (1, "source_role", "audit_db", "audit-system-id"))
    producer.refresh_transaction = lambda *args, **kwargs: (
        calls.append("refresh") or (2, "refresh_role", "audit_db", "audit-system-id", '{"changed":true}'))
    previous_argv = sys.argv
    output = io.StringIO()
    errors = io.StringIO()
    rejection_exit_codes = {}
    with tempfile.TemporaryDirectory(prefix="pg-mdm-producer-admission-bound-") as temp_dir:
        input_path = Path(temp_dir) / "admissions.jsonl"
        sys.argv = [str(producer_path), "--source-service", "source", "--refresh-service", "refresh",
            "--table", "public.source", "--columns", "id,name", "--key-columns", "id",
            "--entity", "audit_entity", "--policy", "ALLOW", "--input", str(input_path),
            "--batch-size", "5", "--rate-per-minute", "0"]
        try:
            for name, raw_input, expected_error in (
                    ("five_rows", json.dumps({"rows": rows}).encode("utf-8") + b"\n",
                     "ERROR: rows at line 1 exceed supported maximum of 4 source rows per admission\n"),
                    ("over_limit_bytes", at_byte_limit + b" " + b"\n",
                     "ERROR: admission at line 1 exceeds supported maximum of 65536 UTF-8 bytes\n")):
                input_path.write_bytes(raw_input)
                output = io.StringIO()
                errors = io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                    exit_code = producer.main()
                assert exit_code == 2, exit_code
                assert output.getvalue() == "", output.getvalue()
                assert errors.getvalue() == expected_error, errors.getvalue()
                assert calls == [], calls
                rejection_exit_codes[name] = exit_code
            sys.argv[sys.argv.index("--batch-size") + 1] = str(producer.MAX_ADMISSIONS_PER_REFRESH + 1)
            input_path.write_bytes(valid_line + b"\n")
            output = io.StringIO()
            errors = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                exit_code = producer.main()
            assert exit_code == 2, exit_code
            assert output.getvalue() == "", output.getvalue()
            expected_batch_error = "ERROR: batch size must be between 1 and " + str(
                producer.MAX_ADMISSIONS_PER_REFRESH) + "\n"
            assert errors.getvalue() == expected_batch_error, errors.getvalue()
            assert calls == [], calls
            over_batch_limit_exit_code = exit_code
            sys.argv[sys.argv.index("--batch-size") + 1] = str(producer.MAX_ADMISSIONS_PER_REFRESH)
            calls.clear()
            at_run_limit = bytearray()
            for index in range(producer.MAX_ADMISSIONS_PER_RUN):
                line = json.dumps({"id": 1000 + index, "name": "case-" + str(index)}).encode("utf-8")
                at_run_limit.extend(line)
                at_run_limit.extend(b" " * (producer.MAX_ADMISSION_JSONL_BYTES - len(line)))
                at_run_limit.extend(b"\r\n")
            at_run_limit = bytes(at_run_limit)
            assert len(at_run_limit) == producer.MAX_INPUT_JSONL_BYTES, len(at_run_limit)
            input_path.write_bytes(at_run_limit)
            expected_admissions = [[[1000 + index, "case-" + str(index)]]
                for index in range(producer.MAX_ADMISSIONS_PER_RUN)]
            assert producer.load_admissions(input_path, columns, keys) == expected_admissions
            input_path.write_bytes(at_run_limit + b"\n")
            output = io.StringIO()
            errors = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                exit_code = producer.main()
            assert exit_code == 2, exit_code
            assert output.getvalue() == "", output.getvalue()
            expected_input_size_error = "ERROR: input exceeds supported maximum of " + str(
                producer.MAX_INPUT_JSONL_BYTES) + " bytes\n"
            assert errors.getvalue() == expected_input_size_error, errors.getvalue()
            assert calls == [], calls
            over_input_size_exit_code = exit_code
            over_run_limit = b"".join(
                (json.dumps({"id": 1000 + index, "name": "case-" + str(index)}) + "\n").encode("utf-8")
                for index in range(producer.MAX_ADMISSIONS_PER_RUN + 1))
            input_path.write_bytes(over_run_limit)
            output = io.StringIO()
            errors = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                exit_code = producer.main()
            assert exit_code == 2, exit_code
            assert output.getvalue() == "", output.getvalue()
            expected_run_error = "ERROR: input exceeds supported maximum of " + str(
                producer.MAX_ADMISSIONS_PER_RUN) + " admissions\n"
            assert errors.getvalue() == expected_run_error, errors.getvalue()
            assert calls == [], calls
            over_run_limit_exit_code = exit_code
        finally:
            sys.argv = previous_argv
    return {"max_admissions_per_run": producer.MAX_ADMISSIONS_PER_RUN,
        "max_admissions_per_refresh": producer.MAX_ADMISSIONS_PER_REFRESH,
        "max_source_rows_per_admission": producer.MAX_SOURCE_ROWS_PER_ADMISSION,
        "max_admission_jsonl_bytes": producer.MAX_ADMISSION_JSONL_BYTES,
        "max_input_jsonl_bytes": producer.MAX_INPUT_JSONL_BYTES,
        "producer_limits_match_supported_envelope": True,
        "at_run_limit_admissions_accepted_exactly": True,
        "at_input_byte_limit_accepted_exactly": True,
        "over_input_byte_limit_error": expected_input_size_error.strip(),
        "over_input_byte_limit_exit_code": over_input_size_exit_code,
        "over_run_limit_error": expected_run_error.strip(),
        "over_run_limit_exit_code": over_run_limit_exit_code,
        "over_batch_limit_error": expected_batch_error.strip(),
        "over_batch_limit_exit_code": over_batch_limit_exit_code,
        "four_row_admission_accepted": True,
        "five_row_admission_exit_code": rejection_exit_codes["five_rows"],
        "over_limit_payload_exit_code": rejection_exit_codes["over_limit_bytes"],
        "five_row_error": "ERROR: rows at line 1 exceed supported maximum of 4 source rows per admission",
        "at_limit_utf8_payload_accepted": True,
        "over_limit_error": "ERROR: admission at line 1 exceeds supported maximum of 65536 UTF-8 bytes",
        "source_or_refresh_calls_before_rejection": calls}


def qualify_bounded_producer_cluster_identity(root):
    producer_path = root / "integrations/pg-mdm/bounded_refresh_producer.py"
    spec = importlib.util.spec_from_file_location("bounded_refresh_producer_cluster_audit", producer_path)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load bounded producer from " + str(producer_path))
    producer = importlib.util.module_from_spec(spec)
    previous_bytecode_setting = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        spec.loader.exec_module(producer)
    finally:
        sys.dont_write_bytecode = previous_bytecode_setting
    producer.shutil = types.SimpleNamespace(which=lambda name: "/fake/psql")
    commands = []

    def psql_cluster_identity(psql_path, service, script, variables=(), deadline=None):
        commands.append(script)
        if "TARGET|" in script:
            return ["TARGET|audit_db|222"]
        if "SOURCE|" in script:
            return ["SOURCE|101|source_role|audit_db|111"]
        return ["REFRESH|201|refresh_role|audit_db|222", '{"changed": true}']

    producer.psql = psql_cluster_identity
    target_identity = producer.database_identity("/fake/psql", "refresh")
    source_identity = producer.source_transaction(
        "/fake/psql", "source", "public.source", ["id"], ["id"], [[1]],
        expected_database="audit_db", expected_system_identifier="222")
    refresh_identity = producer.refresh_transaction(
        "/fake/psql", "refresh", "audit_entity", "ALLOW",
        expected_database="audit_db", expected_system_identifier="222")
    assert target_identity == ("audit_db", "222"), target_identity
    assert source_identity == (101, "source_role", "audit_db", "111"), source_identity
    assert refresh_identity == (
        201, "refresh_role", "audit_db", "222", '{"changed": true}'), refresh_identity
    assert len(commands) == 3 and all(
        "pg_catalog.pg_control_system()" in script and "system_identifier::text" in script
        for script in commands), commands
    assert commands[1].index("DO $pgreact_producer_cluster_guard$") < commands[1].index("INSERT INTO"), commands[1]
    assert commands[2].index("DO $pgreact_producer_cluster_guard$") < commands[2].index("SELECT mdm.refresh"), commands[2]

    producer.source_transaction = lambda *args, **kwargs: (101, "source_role", "audit_db", "111")
    producer.refresh_transaction = lambda *args, **kwargs: (
        201, "refresh_role", "audit_db", "222", '{"changed": true}')
    calls = []
    original_source_transaction = producer.source_transaction
    original_refresh_transaction = producer.refresh_transaction
    producer.source_transaction = lambda *args, **kwargs: (
        calls.append("source") or original_source_transaction(*args, **kwargs))
    producer.refresh_transaction = lambda *args, **kwargs: (
        calls.append("refresh") or original_refresh_transaction(*args, **kwargs))
    with tempfile.TemporaryDirectory(prefix="pg-mdm-producer-cluster-identity-") as temp_dir:
        input_path = Path(temp_dir) / "admissions.jsonl"
        input_path.write_text('{"id":1}\n', encoding="utf-8")
        args = types.SimpleNamespace(source_service="source", refresh_service="refresh",
            entity="audit_entity", policy="ALLOW", batch_size=1, rate_per_minute=0,
            table="public.source", columns="id", key_columns="id", input=str(input_path),
            emit_admission_events=False)
        output = io.StringIO()
        try:
            with contextlib.redirect_stdout(output):
                producer.run(args)
        except RuntimeError as error:
            assert str(error) == (
                "source and refresh services connected to different database clusters"), error
        else:
            raise AssertionError("producer accepted services with one database name and different cluster IDs")
    assert calls == ["source", "refresh"], calls
    assert output.getvalue() == "", output.getvalue()
    return {"equal_database_name": True, "different_system_identifiers": True,
        "batch_completion_emitted": False}


def qualify_bounded_producer_live_cluster_guard(root, service_file, sql, state_query):
    producer_path = root / "integrations/pg-mdm/bounded_refresh_producer.py"
    spec = importlib.util.spec_from_file_location("bounded_refresh_producer_live_cluster_audit", producer_path)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load bounded producer from " + str(producer_path))
    producer = importlib.util.module_from_spec(spec)
    previous_bytecode_setting = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        spec.loader.exec_module(producer)
    finally:
        sys.dont_write_bytecode = previous_bytecode_setting
    prior_service_file = os.environ.get("PGSERVICEFILE")
    os.environ["PGSERVICEFILE"] = str(service_file)
    try:
        psql_path = producer.shutil.which("psql")
        expected_database, expected_system_identifier = producer.database_identity(
            psql_path, "mdm_refresh")
        mismatched_system_identifier = str(int(expected_system_identifier) + 1)
        before = json.loads(sql(state_query))
        try:
            producer.source_transaction(psql_path, "batch_source",
                "public.policy_qualification_source",
                ["id", "display_name", "email_address", "updated_at"], ["id"],
                [[902100001, "must-not-write", "must-not-write@example.test",
                  "2026-01-01T00:00:00+00:00"]], expected_database=expected_database,
                expected_system_identifier=mismatched_system_identifier)
        except RuntimeError as error:
            assert "different database or PostgreSQL cluster" in str(error), error
        else:
            raise AssertionError("source transaction accepted a mismatched PostgreSQL cluster ID")
        try:
            producer.refresh_transaction(psql_path, "mdm_refresh", "policy_qualification", "ALLOW",
                expected_database=expected_database,
                expected_system_identifier=mismatched_system_identifier)
        except RuntimeError as error:
            assert "different database or PostgreSQL cluster" in str(error), error
        else:
            raise AssertionError("refresh transaction accepted a mismatched PostgreSQL cluster ID")
        after = json.loads(sql(state_query))
        assert after == before, {"before": before, "after": after}
    finally:
        if prior_service_file is None:
            os.environ.pop("PGSERVICEFILE", None)
        else:
            os.environ["PGSERVICEFILE"] = prior_service_file
    return {"source_write_rejected_before_commit": True,
        "refresh_rejected_before_call": True, "database_state_unchanged": True}


def qualify_bounded_producer_split_cluster(command, primary_container, image, primary_port, root, output):
    container = "pgreact-producer-other-cluster-" + uuid.uuid4().hex[:12]
    platform_args = ["--platform", "linux/" + command(
        "docker", "image", "inspect", image, "--format", "{{.Architecture}}").strip()]
    try:
        command("docker", "run", *platform_args, "--detach", "--name", container, "--network", "bridge",
            "--publish", "127.0.0.1::5432", "--env", "POSTGRES_HOST_AUTH_METHOD=trust", image)
        for _ in range(60):
            ready = subprocess.run(["docker", "exec", container, "pg_isready", "-U", "postgres"],
                capture_output=True, timeout=15)
            if ready.returncode == 0 and "PostgreSQL init process complete" in command(
                    "docker", "logs", container):
                break
            time.sleep(0.5)
        else:
            raise AssertionError("second PostgreSQL cluster did not become ready")
        command("docker", "exec", container, "createdb", "-U", "postgres", "s1_idle")
        command("docker", "exec", container, "psql", "-XAtq", "-U", "postgres", "-d", "s1_idle",
            "-v", "ON_ERROR_STOP=1", "-c",
            "CREATE TABLE public.policy_qualification_source (id bigint PRIMARY KEY, "
            "display_name text NOT NULL, email_address text NOT NULL, updated_at timestamptz NOT NULL); "
            "CREATE ROLE mdm_legacy_login LOGIN; CREATE ROLE mdm_legacy_administrator NOLOGIN; "
            "GRANT mdm_legacy_administrator TO mdm_legacy_login; "
            "GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO mdm_legacy_administrator; "
            "CREATE SCHEMA mdm; CREATE TABLE public.refresh_sentinel (calls integer NOT NULL DEFAULT 0); "
            "INSERT INTO public.refresh_sentinel DEFAULT VALUES; "
            "CREATE FUNCTION mdm.refresh(text,text) RETURNS jsonb LANGUAGE plpgsql AS $fn$ "
            "BEGIN UPDATE public.refresh_sentinel SET calls=calls+1; RETURN '{\"changed\":true}'::jsonb; "
            "END $fn$; GRANT CONNECT ON DATABASE s1_idle TO mdm_legacy_login; "
            "GRANT USAGE ON SCHEMA mdm TO mdm_legacy_administrator; "
            "GRANT EXECUTE ON FUNCTION mdm.refresh(text,text) TO mdm_legacy_administrator; "
            "GRANT SELECT,UPDATE ON public.refresh_sentinel TO mdm_legacy_administrator")
        other_port = int(command("docker", "port", container, "5432/tcp").strip().rsplit(":", 1)[1])
        service_file = output / "bounded-producer-split-cluster-services.conf"
        service_file.write_text(
            "[batch_source]\nhost=127.0.0.1\nport=" + str(primary_port) + "\ndbname=s1_idle\n"
            "user=mdm_batch_source_writer\nconnect_timeout=10\n\n"
            "[mdm_refresh]\nhost=127.0.0.1\nport=" + str(other_port) + "\ndbname=s1_idle\n"
            "user=mdm_legacy_login\noptions=-c role=mdm_legacy_administrator\nconnect_timeout=10\n")
        service_file.chmod(0o600)
        identity_query = (
            "SELECT current_database() || '|' || system_identifier::text "
            "FROM pg_catalog.pg_control_system()")
        primary_identity = command("docker", "exec", primary_container, "psql", "-XAtq", "-U", "postgres",
            "-p", "5432", "-d", "s1_idle", "-v", "ON_ERROR_STOP=1", "-c", identity_query).strip()
        other_identity = command("docker", "exec", container, "psql", "-XAtq", "-U", "postgres",
            "-d", "s1_idle", "-v", "ON_ERROR_STOP=1", "-c", identity_query).strip()
        primary_database, primary_system_id = primary_identity.split("|", 1)
        other_database, other_system_id = other_identity.split("|", 1)
        assert primary_database == other_database == "s1_idle", (primary_identity, other_identity)
        assert primary_system_id != other_system_id, (primary_identity, other_identity)
        record_id = 919001
        before_primary = command("docker", "exec", primary_container, "psql", "-XAtq", "-U", "postgres",
            "-p", "5432", "-d", "s1_idle", "-c",
            "SELECT count(*) FROM public.policy_qualification_source WHERE id=" + str(record_id)).strip()
        assert before_primary == "0", before_primary
        input_path = output / "bounded-producer-split-cluster-admissions.jsonl"
        input_path.write_text(json.dumps({"id": record_id, "display_name": "must-not-write",
            "email_address": "split-cluster@example.test", "updated_at":
            "2026-01-01T00:00:00+00:00"}) + "\n", encoding="utf-8")
        environment = os.environ.copy()
        environment["PGSERVICEFILE"] = str(service_file)
        result = subprocess.run([sys.executable, str(root / "integrations/pg-mdm/bounded_refresh_producer.py"),
            "--source-service", "batch_source", "--refresh-service", "mdm_refresh",
            "--table", "public.policy_qualification_source",
            "--columns", "id,display_name,email_address,updated_at", "--key-columns", "id",
            "--entity", "policy_qualification", "--policy", "ALLOW", "--input", str(input_path),
            "--batch-size", "1", "--rate-per-minute", "0"], cwd=root, env=environment,
            capture_output=True, text=True, timeout=60)
        assert result.returncode == 2, (result.returncode, result.stdout, result.stderr)
        assert "different database or PostgreSQL cluster" in result.stderr, result.stderr
        assert result.stdout == "", result.stdout
        after_primary = command("docker", "exec", primary_container, "psql", "-XAtq", "-U", "postgres",
            "-p", "5432", "-d", "s1_idle", "-c",
            "SELECT count(*) FROM public.policy_qualification_source WHERE id=" + str(record_id)).strip()
        refresh_calls = command("docker", "exec", container, "psql", "-XAtq", "-U", "postgres",
            "-d", "s1_idle", "-c", "SELECT calls FROM public.refresh_sentinel").strip()
        assert after_primary == before_primary == "0", (before_primary, after_primary)
        assert refresh_calls == "0", refresh_calls
        return {"same_database_name": primary_database, "source_system_identifier": primary_system_id,
            "refresh_system_identifier": other_system_id, "producer_exit_code": result.returncode,
            "producer_error": result.stderr.strip(), "primary_source_row_before_after": [before_primary, after_primary],
            "refresh_sentinel_calls": refresh_calls, "state_unchanged": True}
    finally:
        subprocess.run(["docker", "rm", "--force", container], capture_output=True,
            text=True, timeout=30, check=False)


def qualify_bounded_producer_connection_retry(root):
    producer_path = root / "integrations/pg-mdm/bounded_refresh_producer.py"
    spec = importlib.util.spec_from_file_location("bounded_refresh_producer_retry_audit", producer_path)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load bounded producer from " + str(producer_path))
    producer = importlib.util.module_from_spec(spec)
    previous_bytecode_setting = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        spec.loader.exec_module(producer)
    finally:
        sys.dont_write_bytecode = previous_bytecode_setting
    producer.shutil = types.SimpleNamespace(which=lambda name: "/fake/psql")
    producer.database_identity = lambda *args, **kwargs: ("audit_db", "audit-cluster")
    original_run = producer.subprocess.run
    original_sleep = producer.time.sleep
    producer.time.sleep = lambda seconds: None
    source_calls = []
    refresh_calls = []

    def source_transaction(*args, **kwargs):
        source_calls.append(copy.deepcopy(args[-1]))
        if len(source_calls) == 1:
            raise producer.DatabaseConnectionLost("source commit outcome uncertain")
        return 1000 + len(source_calls), "source_role", "audit_db", "audit-cluster"

    def refresh_transaction(*args, **kwargs):
        refresh_calls.append(args[1:])
        if len(refresh_calls) == 1:
            raise producer.DatabaseConnectionLost("refresh commit outcome uncertain")
        return 2000 + len(refresh_calls), "refresh_role", "audit_db", "audit-cluster", '{"changed": true}'

    producer.source_transaction = source_transaction
    producer.refresh_transaction = refresh_transaction
    psql_calls = []

    def psql_connection_failure(command, **kwargs):
        psql_calls.append((command, kwargs))
        return types.SimpleNamespace(returncode=2, stdout="", stderr="connection refused")

    producer.subprocess.run = psql_connection_failure
    try:
        try:
            producer.psql("/fake/psql", "source", "SELECT 1")
        except producer.DatabaseConnectionLost as error:
            assert str(error) == "psql service source lost its database connection", error
        else:
            raise AssertionError("psql connection loss was not marked retryable")
        assert psql_calls == [([
            "/fake/psql", "-XAtqw", "--set=ON_ERROR_STOP=1", "--set=VERBOSITY=verbose",
            "--dbname=service=source connect_timeout=10", "--file=-"], {
                "input": "SELECT 1", "capture_output": True, "text": True,
                "timeout": 120, "check": False})], psql_calls
        try:
            producer.psql("/fake/psql", "source", "SELECT 1",
                deadline=producer.time.monotonic() + 0.5)
        except producer.DatabaseConnectionLost:
            pass
        else:
            raise AssertionError("psql connection loss with a deadline was not retryable")
        assert len(psql_calls) == 2 and 0 < psql_calls[1][1]["timeout"] <= 0.5, psql_calls
        try:
            producer.psql("/fake/psql", "source", "SELECT 1",
                deadline=producer.time.monotonic() - 1)
        except producer.DatabaseConnectionLost as error:
            assert str(error) == "psql service source exceeded the batch retry window", error
        else:
            raise AssertionError("psql ran after the connection retry deadline")
        assert len(psql_calls) == 2, psql_calls

        def psql_timeout(command, **kwargs):
            raise producer.subprocess.TimeoutExpired(command, kwargs["timeout"])

        producer.subprocess.run = psql_timeout
        try:
            producer.psql("/fake/psql", "source", "SELECT 1")
        except producer.DatabaseConnectionLost as error:
            assert str(error) == "psql service source timed out", error
        else:
            raise AssertionError("psql timeout was not marked retryable")
    finally:
        producer.subprocess.run = original_run
    records = [{"id": record_id} for record_id in range(1, 6)]
    output = io.StringIO()
    try:
        with tempfile.TemporaryDirectory(prefix="pg-mdm-producer-retry-") as temp_dir:
            input_path = Path(temp_dir) / "admissions.jsonl"
            input_path.write_text("".join(json.dumps(record) + "\n" for record in records))
            args = types.SimpleNamespace(source_service="source", refresh_service="refresh",
                entity="audit_entity", policy="ALLOW", batch_size=5, rate_per_minute=0,
                table="public.source", columns="id", key_columns="id", input=str(input_path),
                emit_admission_events=False)
            with contextlib.redirect_stdout(output):
                producer.run(args)
    finally:
        producer.time.sleep = original_sleep
        producer.subprocess.run = original_run

    events = [json.loads(line) for line in output.getvalue().splitlines() if line.strip()]
    assert [event["event"] for event in events] == [
        "connection_retry", "connection_retry", "batch_complete", "producer_complete"], events
    assert events[:2] == [
        {"event": "connection_retry", "batch": 1, "attempt": 1, "delay_seconds": 1},
        {"event": "connection_retry", "batch": 1, "attempt": 2, "delay_seconds": 1}], events
    batch = events[2]
    assert {key: batch[key] for key in (
        "event", "batch", "admissions", "source_rows", "transaction_retries",
        "source_txid", "source_role",
        "source_database", "refresh_txid", "refresh_role", "refresh_database", "refresh_result")} == {
            "event": "batch_complete", "batch": 1, "admissions": 5, "source_rows": 5,
            "transaction_retries": 0,
            "source_txid": 1003, "source_role": "source_role", "source_database": "audit_db",
            "refresh_txid": 2002, "refresh_role": "refresh_role", "refresh_database": "audit_db",
            "refresh_result": '{"changed": true}'}, batch
    summary = events[3]
    assert {key: summary[key] for key in (
        "event", "admissions", "source_rows", "offered_admissions", "batch_size_limit",
        "batches", "refresh_calls", "connection_retries", "transaction_retries")} == {
            "event": "producer_complete", "admissions": 5, "source_rows": 5,
            "offered_admissions": 5, "batch_size_limit": 5, "batches": 1,
            "refresh_calls": 1, "connection_retries": 2, "transaction_retries": 0}, summary
    expected_source_rows = [[record["id"]] for record in records]
    assert source_calls == [expected_source_rows] * 3, source_calls
    assert refresh_calls == [
        ("refresh", "audit_entity", "ALLOW"),
        ("refresh", "audit_entity", "ALLOW")], refresh_calls
    return {"ambiguous_source_commit_replayed": True,
        "ambiguous_refresh_commit_replayed": True,
        "exactly_one_batch_completion": True,
        "connection_retries": summary["connection_retries"]}


def qualify_bounded_producer_transaction_retry(root):
    producer_path = root / "integrations/pg-mdm/bounded_refresh_producer.py"
    spec = importlib.util.spec_from_file_location("bounded_refresh_producer_transaction_retry_audit",
        producer_path)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load bounded producer from " + str(producer_path))
    producer = importlib.util.module_from_spec(spec)
    previous_bytecode_setting = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        spec.loader.exec_module(producer)
    finally:
        sys.dont_write_bytecode = previous_bytecode_setting
    producer.shutil = types.SimpleNamespace(which=lambda name: "/fake/psql")
    producer.database_identity = lambda *args, **kwargs: ("audit_db", "audit-cluster")
    original_time = producer.time
    original_run = producer.subprocess.run
    original_sleep = producer.time.sleep
    original_retry_window = producer.MAX_BATCH_RETRY_SECONDS
    producer.time.sleep = lambda seconds: None
    psql_results = []
    try:
        for sqlstate, message in (("40P01", "deadlock detected"),
                                  ("40001", "could not serialize access")):
            result = types.SimpleNamespace(returncode=1, stdout="",
                stderr="ERROR:  " + sqlstate + ": " + message + "\n")
            producer.subprocess.run = lambda command, **kwargs: result
            try:
                producer.psql("/fake/psql", "source", "SELECT 1")
            except producer.DatabaseTransactionRetry as error:
                assert error.sqlstate == sqlstate, (sqlstate, error.sqlstate)
                assert str(error) == (
                    "psql service source failed with retryable SQLSTATE " + sqlstate), error
            else:
                raise AssertionError("psql did not expose retryable SQLSTATE " + sqlstate)
            psql_results.append({"sqlstate": sqlstate, "message": message})
    finally:
        producer.subprocess.run = original_run

    records = [{"id": record_id} for record_id in range(1, 6)]
    source_failures = []
    refresh_failures = []

    def execute_scenario(failure_phase, sqlstate):
        source_calls = []
        refresh_calls = []

        def source_transaction(*args, **kwargs):
            source_calls.append(copy.deepcopy(args[-1]))
            if failure_phase == "source" and len(source_calls) == 1:
                raise producer.DatabaseTransactionRetry("source", sqlstate)
            return 1000 + len(source_calls), "source_role", "audit_db", "audit-cluster"

        def refresh_transaction(*args, **kwargs):
            refresh_calls.append(args[1:])
            if failure_phase == "refresh" and len(refresh_calls) == 1:
                raise producer.DatabaseTransactionRetry("refresh", sqlstate)
            return 2000 + len(refresh_calls), "refresh_role", "audit_db", "audit-cluster", '{"changed": true}'

        producer.source_transaction = source_transaction
        producer.refresh_transaction = refresh_transaction
        output = io.StringIO()
        with tempfile.TemporaryDirectory(prefix="pg-mdm-producer-transaction-retry-") as temp_dir:
            input_path = Path(temp_dir) / "admissions.jsonl"
            input_path.write_text("".join(json.dumps(record) + "\n" for record in records))
            args = types.SimpleNamespace(source_service="source", refresh_service="refresh",
                entity="audit_entity", policy="ALLOW", batch_size=5, rate_per_minute=0,
                table="public.source", columns="id", key_columns="id", input=str(input_path),
                emit_admission_events=False)
            with contextlib.redirect_stdout(output):
                producer.run(args)
        events = [json.loads(line) for line in output.getvalue().splitlines() if line.strip()]
        assert [event["event"] for event in events] == [
            "transaction_retry", "batch_complete", "producer_complete"], events
        assert events[0] == {"event": "transaction_retry", "batch": 1,
            "attempt": 1, "sqlstate": sqlstate, "delay_seconds": 0.1}, events[0]
        batch = events[1]
        assert {key: batch[key] for key in (
            "event", "batch", "admissions", "source_rows", "transaction_retries",
            "source_txid", "refresh_txid", "refresh_result")} == {
                "event": "batch_complete", "batch": 1, "admissions": 5,
                "source_rows": 5, "transaction_retries": 1,
                "source_txid": 1002,
                "refresh_txid": 2001 if failure_phase == "source" else 2002,
                "refresh_result": '{"changed": true}'}, batch
        summary = events[2]
        assert {key: summary[key] for key in (
            "event", "admissions", "source_rows", "offered_admissions",
            "batch_size_limit", "batches", "refresh_calls", "connection_retries",
            "transaction_retries")} == {
                "event": "producer_complete", "admissions": 5, "source_rows": 5,
                "offered_admissions": 5, "batch_size_limit": 5, "batches": 1,
                "refresh_calls": 1, "connection_retries": 0,
                "transaction_retries": 1}, summary
        expected_rows = [[record["id"]] for record in records]
        assert source_calls == [expected_rows] * 2, source_calls
        expected_refresh_calls = 1 if failure_phase == "source" else 2
        assert refresh_calls == [("refresh", "audit_entity", "ALLOW")] * expected_refresh_calls, \
            refresh_calls
        return {"failure_phase": failure_phase, "sqlstate": sqlstate,
            "events": events, "source_replays": len(source_calls),
            "refresh_replays": len(refresh_calls)}

    try:
        source_result = execute_scenario("source", "40P01")
        refresh_result = execute_scenario("refresh", "40001")

        source_calls = []

        def always_deadlock_source(*args, **kwargs):
            source_calls.append(copy.deepcopy(args[-1]))
            raise producer.DatabaseTransactionRetry("source", "40P01")

        def unexpected_refresh(*args, **kwargs):
            raise AssertionError("refresh ran after every source transaction deadlocked")

        producer.source_transaction = always_deadlock_source
        producer.refresh_transaction = unexpected_refresh
        output = io.StringIO()
        with tempfile.TemporaryDirectory(prefix="pg-mdm-producer-deadlock-cap-") as temp_dir:
            input_path = Path(temp_dir) / "admissions.jsonl"
            input_path.write_text("".join(json.dumps(record) + "\n" for record in records))
            args = types.SimpleNamespace(source_service="source", refresh_service="refresh",
                entity="audit_entity", policy="ALLOW", batch_size=5, rate_per_minute=0,
                table="public.source", columns="id", key_columns="id", input=str(input_path),
                emit_admission_events=False)
            try:
                with contextlib.redirect_stdout(output):
                    producer.run(args)
            except producer.DatabaseTransactionRetry as error:
                assert str(error) == "psql service source failed with retryable SQLSTATE 40P01", error
            else:
                raise AssertionError("producer exceeded the deadlock retry cap")
        events = [json.loads(line) for line in output.getvalue().splitlines() if line.strip()]
        assert events == [{"event": "transaction_retry", "batch": 1,
            "attempt": attempt, "sqlstate": "40P01", "delay_seconds": delay}
            for attempt, delay in enumerate((0.1, 0.2, 0.4, 0.8), 1)], events
        assert len(source_calls) == producer.MAX_TRANSACTION_RETRIES + 1, source_calls

        clock = [0.0]
        producer.MAX_BATCH_RETRY_SECONDS = 0.25
        producer.time = types.SimpleNamespace(
            monotonic=lambda: clock[0],
            sleep=lambda seconds: clock.__setitem__(0, clock[0] + seconds))

        def deadline_database_identity(*args, deadline=None, **kwargs):
            if clock[0] >= deadline:
                raise producer.DatabaseConnectionLost(
                    "psql service refresh exceeded the batch retry window")
            return "audit_db", "audit-cluster"

        producer.database_identity = deadline_database_identity
        deadline_source_calls = []
        deadline_refresh_calls = []

        def deadline_source_transaction(*args, **kwargs):
            deadline_source_calls.append(copy.deepcopy(args[-1]))
            clock[0] = kwargs["deadline"] - 0.0625
            raise producer.DatabaseTransactionRetry("source", "40P01")

        def deadline_refresh_transaction(*args, **kwargs):
            deadline_refresh_calls.append(args)
            return (2001, "refresh_role", "audit_db", "audit-cluster", '{"changed": true}')

        producer.source_transaction = deadline_source_transaction
        producer.refresh_transaction = deadline_refresh_transaction
        output = io.StringIO()
        with tempfile.TemporaryDirectory(prefix="pg-mdm-producer-retry-deadline-") as temp_dir:
            input_path = Path(temp_dir) / "admissions.jsonl"
            input_path.write_text('{"id":1}\n')
            args = types.SimpleNamespace(source_service="source", refresh_service="refresh",
                entity="audit_entity", policy="ALLOW", batch_size=1, rate_per_minute=0,
                table="public.source", columns="id", key_columns="id", input=str(input_path),
                emit_admission_events=False)
            try:
                with contextlib.redirect_stdout(output):
                    producer.run(args)
            except producer.DatabaseConnectionLost as error:
                assert str(error) == (
                    "psql service refresh exceeded the batch retry window"), error
            else:
                raise AssertionError("transaction retry exceeded its batch retry deadline")
        deadline_events = [json.loads(line) for line in output.getvalue().splitlines() if line.strip()]
        assert deadline_events == [{"event": "transaction_retry", "batch": 1,
            "attempt": 1, "sqlstate": "40P01", "delay_seconds": 0.0625}], deadline_events
        assert clock[0] == producer.MAX_BATCH_RETRY_SECONDS, clock
        assert len(deadline_source_calls) == 1, deadline_source_calls
        assert deadline_refresh_calls == [], deadline_refresh_calls
        deadline_result = {"retry_sleep_capped_to_remaining_window": True,
            "elapsed_retry_window_seconds": clock[0], "refresh_called_after_deadline": False}
    finally:
        producer.time = original_time
        producer.MAX_BATCH_RETRY_SECONDS = original_retry_window
        original_time.sleep = original_sleep
        producer.subprocess.run = original_run
    return {"psql_sqlstates": psql_results, "source_transaction": source_result,
        "refresh_transaction": refresh_result,
        "retry_cap": producer.MAX_TRANSACTION_RETRIES,
        "retry_deadline": deadline_result,
        "exhaustion_stops_without_success_event": True}


def qualify_bounded_producer(sql, command, container, root, output, observations,
        installed_wheel=False, outage_only=False, wheel_file=None):
    wheel_temp = None
    observations["bounded_producer_admission_bounds"] = qualify_bounded_producer_admission_bounds(root)
    observations["checks"].append({"name": "bounded-producer-input-row-and-byte-limits", "result": "passed"})
    print("PASS: producer enforced 300-admission, total-file, per-refresh, row and payload-byte limits before database calls", flush=True)
    observations["bounded_producer_cluster_identity"] = qualify_bounded_producer_cluster_identity(root)
    observations["checks"].append({"name": "bounded-producer-cluster-identity", "result": "passed"})
    print("PASS: producer rejected same-name databases with different PostgreSQL cluster IDs", flush=True)
    observations["bounded_producer_backpressure_regression"] = qualify_bounded_producer_backpressure(root)
    observations["checks"].append({"name": "bounded-producer-telemetry-backpressure-order", "result": "passed"})
    print("PASS: telemetry preserved event order under a saturated admission queue", flush=True)
    observations["bounded_producer_connection_retry"] = qualify_bounded_producer_connection_retry(root)
    observations["checks"].append({"name": "bounded-producer-ambiguous-commit-retry", "result": "passed"})
    print("PASS: bounded producer replayed source and refresh transactions after connection loss", flush=True)
    observations["bounded_producer_transaction_retry"] = qualify_bounded_producer_transaction_retry(root)
    observations["checks"].append({"name": "bounded-producer-deadlock-and-serialization-retry", "result": "passed"})
    print("PASS: bounded producer safely retried deadlocked source and refresh transactions", flush=True)
    sql("CREATE ROLE mdm_batch_source_writer LOGIN NOSUPERUSER NOBYPASSRLS NOINHERIT; "
        "GRANT CONNECT, TEMPORARY ON DATABASE s1_idle TO mdm_batch_source_writer; "
        "GRANT USAGE ON SCHEMA public TO mdm_batch_source_writer; "
        "GRANT SELECT, INSERT ON public.policy_qualification_source TO mdm_batch_source_writer; "
        "CREATE TABLE public.policy_qualification_json_source (id bigint PRIMARY KEY, payload json NOT NULL); "
        "GRANT SELECT, INSERT ON public.policy_qualification_json_source TO mdm_batch_source_writer; "
        "GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() "
        "TO mdm_batch_source_writer, mdm_legacy_administrator")
    published = command("docker", "port", container, "5432/tcp").strip()
    port = int(published.rsplit(":", 1)[1])
    state_query = (
        "SELECT jsonb_build_object('source',(SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.id),'[]') "
        "FROM public.policy_qualification_source s), 'cases',(SELECT COALESCE(jsonb_agg(to_jsonb(c) "
        "ORDER BY c.case_key),'[]') FROM mdm_steward.policy_cases_v1 c "
        "WHERE c.entity_name='policy_qualification'), "
        "'receipts',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.binding_id,r.request_key),'[]') "
        "FROM mdm_steward.policy_receipts_v1 r), "
        "'requests',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.binding_id,r.request_key),'[]') "
        "FROM pgreact_mdm.intent_requests r), "
        "'attempts',(SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.episode_id,a.attempt_no),'[]') "
        "FROM pgreact_mdm.intent_attempts a), "
        "'reviews',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.review_id),'[]') "
        "FROM mdm_out.policy_qualification_review r WHERE r.review_id IN "
        "(SELECT c.review_id FROM mdm_steward.policy_cases_v1 c "
        "WHERE c.entity_name='policy_qualification')))" )
    before = json.loads(sql(state_query))
    admission_timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    first_id = 910001
    display_names = ["Aurora Meridian", "Boreal Summit", "Cedar Valley",
        "Delta Harbor", "Emerald River"]
    records = [{"id": first_id + index,
        "display_name": display_names[index],
        "email_address": "bounded-producer-" + str(index + 1) + "@example.test",
        "updated_at": admission_timestamp} for index in range(5)]
    input_path = output / "bounded-producer-admissions.jsonl"
    input_path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in records))
    with tempfile.TemporaryDirectory(prefix="pg-mdm-producer-audit-") as temp_dir:
        service_file = Path(temp_dir) / "pg_service.conf"
        service_file.write_text(
            "[batch_source]\n"
            "host=127.0.0.1\nport=" + str(port) + "\ndbname=s1_idle\n"
            "user=mdm_batch_source_writer\nconnect_timeout=10\n\n"
            "[mdm_refresh]\n"
            "host=127.0.0.1\nport=" + str(port) + "\ndbname=s1_idle\n"
            "user=mdm_legacy_login\noptions=-c role=mdm_legacy_administrator\nconnect_timeout=10\n")
        service_file.chmod(0o600)
        observations["bounded_producer_split_cluster"] = qualify_bounded_producer_split_cluster(
            command, container, observations["image"], port, root, output)
        observations["checks"].append({"name": "bounded-producer-same-name-two-real-clusters", "result": "passed"})
        print("PASS: same-name services on separate PostgreSQL clusters were rejected before writes or refresh", flush=True)
        observations["bounded_producer_live_cluster_guard"] = qualify_bounded_producer_live_cluster_guard(
            root, service_file, sql, state_query)
        observations["checks"].append({"name": "bounded-producer-live-cluster-guard", "result": "passed"})
        print("PASS: mismatched cluster ID stopped source writes and refresh before state changed", flush=True)
        environment = os.environ.copy()
        environment["PGSERVICEFILE"] = str(service_file)
        producer = root / "integrations/pg-mdm/bounded_refresh_producer.py"
        producer_command = [sys.executable, str(producer)]
        if installed_wheel:
            wheel_temp = tempfile.TemporaryDirectory(prefix="pg-mdm-producer-wheel-audit-")
            if wheel_file is None:
                wheel_dir = Path(wheel_temp.name) / "wheel"
                wheel_dir.mkdir()
                command(sys.executable, "-m", "pip", "wheel", "--no-deps",
                    "--wheel-dir", str(wheel_dir), str(root / "integrations/pg-mdm"))
                wheels = sorted(wheel_dir.glob("*.whl"))
                assert [wheel.name for wheel in wheels] == [
                    "pg_react_bounded_refresh_producer-0.49.0-py3-none-any.whl"], wheels
                wheel_path = wheels[0]
            else:
                wheel_path = Path(wheel_file).resolve()
                assert wheel_path.is_file(), wheel_path
                assert wheel_path.name == (
                    "pg_react_bounded_refresh_producer-0.49.0-py3-none-any.whl"), wheel_path
            with zipfile.ZipFile(wheel_path) as archive:
                metadata_path = next(name for name in archive.namelist()
                    if name.endswith(".dist-info/METADATA"))
                entry_points_path = next(name for name in archive.namelist()
                    if name.endswith(".dist-info/entry_points.txt"))
                metadata = archive.read(metadata_path).decode("utf-8")
                entry_points = archive.read(entry_points_path).decode("utf-8")
                packaged_source = archive.read("bounded_refresh_producer.py")
            source_sha256 = hashlib.sha256(producer.read_bytes()).hexdigest()
            assert packaged_source == producer.read_bytes(), "wheel does not contain the current producer source"
            assert "Name: pg-react-bounded-refresh-producer\n" in metadata, metadata
            assert "Version: 0.49.0\n" in metadata, metadata
            assert "Requires-Python: >=3.10\n" in metadata, metadata
            assert entry_points == (
                "[console_scripts]\n"
                "pg-react-bounded-refresh-producer = bounded_refresh_producer:main\n"), entry_points
            wheel_sha256 = hashlib.sha256(wheel_path.read_bytes()).hexdigest()
            packaged_wheel = output / wheel_path.name
            packaged_wheel.write_bytes(wheel_path.read_bytes())
            venv_path = Path(wheel_temp.name) / "producer-venv"
            command(sys.executable, "-m", "venv", str(venv_path))
            venv_bin = venv_path / "bin"
            venv_python = str(venv_bin / "python")
            producer_cli = str(venv_bin / "pg-react-bounded-refresh-producer")
            command(venv_python, "-m", "pip", "install", "--no-deps", str(packaged_wheel))
            installed_module = command(venv_python, "-c",
                "import hashlib,pathlib,bounded_refresh_producer as module; "
                "path=pathlib.Path(module.__file__).resolve(); "
                "print(path); print(hashlib.sha256(path.read_bytes()).hexdigest())").splitlines()
            assert len(installed_module) == 2, installed_module
            assert Path(installed_module[0]).is_relative_to(venv_path.resolve()), installed_module
            assert installed_module[1] == source_sha256, installed_module
            help_text = command(producer_cli, "--help")
            assert "--source-service" in help_text and "--input" in help_text, help_text
            producer_command = [producer_cli]
            observations["bounded_producer_installed_wheel"] = {
                "wheel_file": packaged_wheel.name,
                "wheel_sha256": wheel_sha256,
                "wheel_origin": "provided_exact_artifact" if wheel_file else "built_from_current_source",
                "producer_source_sha256": source_sha256,
                "installed_module_sha256": installed_module[1],
                "installed_module_loaded_from_venv": True,
                "entry_point_help_passed": True,
            }
            json_payload = {"nested": [True, None, {"a": 2, "z": "x"}], "stable": 1}
            json_input = output / "bounded-producer-json-admission.jsonl"
            json_input.write_text(json.dumps({"id": 920001, "payload": json_payload},
                sort_keys=True, separators=(",", ":")) + "\n")

            def json_source_probe(input_path, conflict=False):
                probe = (
                    "import json,shutil,bounded_refresh_producer as producer; "
                    "psql=shutil.which('psql'); "
                    "admissions=producer.load_admissions(" + repr(str(input_path)) + ", "
                    "['id','payload'], ['id']); "
                    "database,system_identifier=producer.database_identity(psql, 'batch_source'); "
                )
                transaction = (
                    "producer.source_transaction(psql, 'batch_source', "
                    "'public.policy_qualification_json_source', ['id','payload'], ['id'], "
                    "admissions[0], expected_database=database, "
                    "expected_system_identifier=system_identifier)"
                )
                if conflict:
                    probe += (
                        "\ntry:\n    " + transaction + "\n"
                        "except RuntimeError as error:\n    print(json.dumps({'error': str(error)}))\n"
                        "else:\n    raise SystemExit('expected conflicting JSON replay to fail')\n"
                    )
                else:
                    probe += "print(json.dumps(" + transaction + "))"
                result = subprocess.run([venv_python, "-c", probe], cwd=root,
                    env=environment, capture_output=True, text=True, timeout=30)
                if result.returncode:
                    raise RuntimeError("JSON source probe failed: " + result.stdout + result.stderr)
                return result.stdout.strip()

            json_runs = [json.loads(json_source_probe(json_input)) for _ in range(2)]
            assert len(json_runs) == 2 and all(len(result) == 4 for result in json_runs), json_runs
            expected_json_cluster = sql(
                "SELECT system_identifier::text FROM pg_catalog.pg_control_system()")
            assert all(result[1:] == ["mdm_batch_source_writer", "s1_idle", expected_json_cluster]
                for result in json_runs), json_runs
            assert json_runs[0][0] != json_runs[1][0], json_runs
            expected_json_row = "920001|" + json.dumps(json_payload, sort_keys=True,
                separators=(",", ":"))
            assert sql("SELECT id::text || '|' || payload::text "
                "FROM public.policy_qualification_json_source WHERE id=920001") == expected_json_row
            conflict_payload = {"nested": [True, None, {"a": 2, "z": "x"}], "stable": 2}
            conflict_input = output / "bounded-producer-json-conflict.jsonl"
            conflict_input.write_text(json.dumps({"id": 920001, "payload": conflict_payload},
                sort_keys=True, separators=(",", ":")) + "\n")
            conflict_result = json.loads(json_source_probe(conflict_input, conflict=True))
            assert "23505" in conflict_result["error"] and \
                "source replay conflicts with existing row" in conflict_result["error"], conflict_result
            assert sql("SELECT id::text || '|' || payload::text "
                "FROM public.policy_qualification_json_source WHERE id=920001") == expected_json_row
            observations["bounded_producer_json_replay"] = {
                "column_type": "json",
                "source_results": json_runs,
                "identical_replay_preserved_exact_row": expected_json_row,
                "conflicting_replay_error": conflict_result["error"],
                "conflict_preserved_exact_row": True,
            }
            observations["checks"].append({
                "name": "bounded-producer-json-column-exact-replay-and-conflict",
                "result": "passed"})
            print("PASS: installed wheel replayed exact JSON-column values and rejected conflicting JSON", flush=True)
        command_args = producer_command + [
            "--source-service", "batch_source", "--refresh-service", "mdm_refresh",
            "--table", "public.policy_qualification_source",
            "--columns", "id,display_name,email_address,updated_at",
            "--key-columns", "id", "--entity", "policy_qualification",
            "--policy", "ALLOW", "--input", str(input_path),
            "--batch-size", "5", "--rate-per-minute", "60"]
        runs = []
        states = []
        for run_number in (1, 2):
            result = subprocess.run(command_args, cwd=root, env=environment,
                capture_output=True, text=True, timeout=90)
            (output / ("bounded-producer-run-" + str(run_number) + ".log")).write_text(
                result.stdout + result.stderr)
            assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
            events = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
            assert len(events) == 2, events
            batch, summary = events
            assert batch["event"] == "batch_complete", batch
            assert batch["batch"] == 1 and batch["admissions"] == 5, batch
            assert batch["source_rows"] == 5, batch
            assert batch["source_role"] == "mdm_batch_source_writer", batch
            assert batch["refresh_role"] == "mdm_legacy_administrator", batch
            assert batch["source_database"] == batch["refresh_database"] == "s1_idle", batch
            assert batch["source_txid"] != batch["refresh_txid"], batch
            assert summary["event"] == "producer_complete", summary
            assert (summary["admissions"], summary["batch_size_limit"],
                summary["source_rows"], summary["batches"], summary["refresh_calls"],
                summary["transaction_retries"]) == (5, 5, 5, 1, 1, 0), summary
            assert summary["offered_admissions"] == 5, summary
            assert 4.8 <= summary["offered_seconds"] <= 5.2, summary
            assert 59 <= summary["offered_admissions_per_minute"] <= 61, summary
            runs.append(events)
            states.append(json.loads(sql(state_query)))
    assert len(states[0]["source"]) == len(before["source"]) + 5, states[0]
    first_refresh = json.loads(runs[0][0]["refresh_result"])
    replay_refresh = json.loads(runs[1][0]["refresh_result"])
    assert first_refresh["changed"] is True, first_refresh
    assert first_refresh["identities"] == 7 and first_refresh["delta_lag"] == 0, first_refresh
    assert max(node["rows_inserted"] for node in first_refresh["node_results"].values()) == 5, first_refresh
    assert replay_refresh["identities"] == 7, replay_refresh
    for collection in ("receipts", "requests", "attempts"):
        assert states[0][collection] == before[collection], collection
    assert states[1]["source"] == states[0]["source"], (states[0]["source"], states[1]["source"])
    for collection in ("receipts", "requests", "attempts"):
        assert states[1][collection] == states[0][collection], collection
    assert len(states[1]["cases"]) == len(states[0]["cases"]), states[1]["cases"]
    for first_case, replay_case in zip(states[0]["cases"], states[1]["cases"]):
        assert {key: value for key, value in replay_case.items() if key != "last_observed_at"} == {
            key: value for key, value in first_case.items() if key != "last_observed_at"}, (first_case, replay_case)
        assert replay_case["last_observed_at"] >= first_case["last_observed_at"], (first_case, replay_case)
    actual_rows = [dict(row) for row in states[0]["source"] if row["id"] >= first_id]
    expected_rows = [{"id": row["id"], "display_name": row["display_name"],
        "email_address": row["email_address"], "updated_at": admission_timestamp} for row in records]
    for row in actual_rows + expected_rows:
        row["updated_at"] = timestamp(row["updated_at"]).isoformat()
    assert actual_rows == expected_rows, states[0]["source"]
    if installed_wheel:
        observations["checks"].append({
            "name": "bounded-producer-current-source-installed-wheel-runtime",
            "result": "passed"})
        print("PASS: current-source wheel entry point committed, refreshed, and idempotently replayed live admissions",
            flush=True)
    observations["bounded_producer"] = {"before": before, "after_first_run": states[0],
        "after_idempotent_replay": states[1], "runs": runs,
        "first_refresh_result": first_refresh, "replay_refresh_result": replay_refresh,
        "source_and_refresh_use_distinct_roles": True,
        "source_commit_precedes_refresh_in_distinct_transactions": True,
        "replay_preserved_requests_receipts_and_attempts": True,
        "replay_only_advanced_case_observation_time": True}
    observations["checks"].append({"name": "five-source-row-producer-commit-refresh-replay", "result": "passed"})
    print("PASS: five-source-row producer committed before refresh; replay preserved control state", flush=True)

    outage_first_id = 915001
    outage_timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    outage_records = [{"id": outage_first_id + index,
        "display_name": "Restart Intake " + str(index + 1),
        "email_address": "bounded-restart-" + str(index + 1) + "@example.test",
        "updated_at": outage_timestamp} for index in range(5)]
    outage_input = output / "bounded-producer-restart-admissions.jsonl"
    outage_input.write_text("".join(json.dumps(row, sort_keys=True) + "\n"
        for row in outage_records))
    outage_before = json.loads(sql(state_query))
    outage_args = command_args.copy()
    input_index = outage_args.index("--input") + 1
    outage_args[input_index] = str(outage_input)
    restart_service_temp = tempfile.TemporaryDirectory(prefix="pg-mdm-producer-restart-")
    restart_service_file = Path(restart_service_temp.name) / "pg_service.conf"
    restart_service_file.write_text(
        "[batch_source]\n"
        "host=127.0.0.1\nport=" + str(port) + "\ndbname=s1_idle\n"
        "user=mdm_batch_source_writer\nconnect_timeout=10\n\n"
        "[mdm_refresh]\n"
        "host=127.0.0.1\nport=" + str(port) + "\ndbname=s1_idle\n"
        "user=mdm_legacy_login\noptions=-c role=mdm_legacy_administrator\nconnect_timeout=10\n")
    restart_service_file.chmod(0o600)
    restart_environment = os.environ.copy()
    restart_environment["PGSERVICEFILE"] = str(restart_service_file)
    retry_process = None
    original_port = port
    try:
        command("docker", "stop", container)
        outage_started = time.monotonic()
        retry_process = subprocess.Popen(outage_args, cwd=root, env=restart_environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        readable, _, _ = select.select([retry_process.stdout], [], [], 15)
        assert readable, "producer did not report a connection retry while PostgreSQL was stopped"
        first_retry_line = retry_process.stdout.readline()
        first_retry = json.loads(first_retry_line)
        assert first_retry == {"event": "connection_retry", "batch": 1,
            "attempt": 1, "delay_seconds": 1}, first_retry
        time.sleep(max(0.0, outage_started + 110 - time.monotonic()))
        command("docker", "start", container)
        restarted_published = command("docker", "port", container, "5432/tcp").strip()
        restarted_port = int(restarted_published.rsplit(":", 1)[1])
        old_port = "port=" + str(port) + "\n"
        port = restarted_port
        service_text = restart_service_file.read_text(encoding="utf-8")
        assert service_text.count(old_port) == 2, service_text
        restart_service_file.write_text(
            service_text.replace(old_port, "port=" + str(restarted_port) + "\n"), encoding="utf-8")
        assert restart_service_file.stat().st_mode & 0o777 == 0o600, restart_service_file.stat()
        for _ in range(60):
            ready = subprocess.run(["docker", "exec", container, "pg_isready", "-U", "postgres"],
                capture_output=True, text=True, timeout=15)
            if ready.returncode == 0:
                break
            time.sleep(0.5)
        else:
            raise AssertionError("PostgreSQL did not recover after the supported producer outage")
        outage_seconds = time.monotonic() - outage_started
        assert 110 <= outage_seconds <= 120, outage_seconds
        retry_stdout, retry_stderr = retry_process.communicate(timeout=180)
        assert retry_process.returncode == 0, (retry_process.returncode, retry_stdout, retry_stderr)
    finally:
        if command("docker", "inspect", "--format", "{{.State.Running}}", container).strip() != "true":
            command("docker", "start", container)
        if retry_process is not None and retry_process.poll() is None:
            retry_process.terminate()
            try:
                retry_process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                retry_process.kill()
                retry_process.communicate()
        restart_service_temp.cleanup()
    (output / "bounded-producer-restart-run.log").write_text(
        first_retry_line + retry_stdout + retry_stderr)
    outage_events = [first_retry] + [json.loads(line) for line in retry_stdout.splitlines() if line.strip()]
    outage_retries = [event for event in outage_events if event["event"] == "connection_retry"]
    outage_batches = [event for event in outage_events if event["event"] == "batch_complete"]
    outage_summaries = [event for event in outage_events if event["event"] == "producer_complete"]
    assert outage_retries == [{"event": "connection_retry", "batch": 1,
        "attempt": attempt, "delay_seconds": 1}
        for attempt in range(1, len(outage_retries) + 1)], outage_retries
    assert len(outage_retries) >= 100, outage_retries
    assert len(outage_batches) == len(outage_summaries) == 1, outage_events
    outage_batch = outage_batches[0]
    outage_summary = outage_summaries[0]
    assert (outage_batch["batch"], outage_batch["admissions"], outage_batch["source_rows"],
        outage_batch["source_role"], outage_batch["refresh_role"],
        outage_batch["source_database"], outage_batch["refresh_database"]) == (
            1, 5, 5, "mdm_batch_source_writer", "mdm_legacy_administrator", "s1_idle", "s1_idle"), outage_batch
    assert outage_batch["source_txid"] != outage_batch["refresh_txid"], outage_batch
    assert (outage_summary["admissions"], outage_summary["source_rows"],
        outage_summary["batches"], outage_summary["refresh_calls"],
        outage_summary["connection_retries"]) == (
            5, 5, 1, 1, len(outage_retries)), outage_summary
    outage_after = json.loads(sql(state_query))
    expected_outage_rows = [dict(row) for row in outage_records]
    actual_outage_rows = [dict(row) for row in outage_after["source"]
        if outage_first_id <= row["id"] < outage_first_id + 5]
    for row in actual_outage_rows + expected_outage_rows:
        row["updated_at"] = timestamp(row["updated_at"]).isoformat()
    assert actual_outage_rows == expected_outage_rows, actual_outage_rows
    assert len(outage_after["source"]) == len(outage_before["source"]) + 5, outage_after["source"]
    for collection in ("receipts", "requests", "attempts"):
        assert outage_after[collection] == outage_before[collection], collection
    observations["bounded_producer_real_outage"] = {
        "first_connection_retry": first_retry, "connection_retries": len(outage_retries),
        "outage_seconds": round(outage_seconds, 3),
        "published_port_before_restart": original_port, "published_port_after_restart": restarted_port,
        "batch_complete": outage_batch, "producer_complete": outage_summary,
        "source_rows": actual_outage_rows, "preserved_requests_receipts_and_attempts": True}
    observations["checks"].append({"name": "bounded-producer-reconnect-after-live-postgres-restart", "result": "passed"})
    print("PASS: bounded producer held its batch through a live PostgreSQL stop/start", flush=True)
    if outage_only:
        observations["entry_decision"] = "PRODUCER_OUTAGE_ONLY"
        return

    bulk_first_id = 920001
    bulk_timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    bulk_admissions = []
    bulk_source_rows = []
    for index in range(300):
        batch = index + 1
        suffix = chr(65 + index // 26) + chr(65 + index % 26)
        source_id = bulk_first_id + 4 * index
        alpha = "Issue 8 Churn " + suffix + " Alpha"
        beta = "Issue 8 Churn " + suffix + " Beta"
        pair_email = "issue8-churn-" + str(batch) + "-pair@example.test"
        rows = [
            {"id": source_id, "display_name": alpha,
             "email_address": "issue8-churn-" + str(batch) + "-one@example.test",
             "updated_at": bulk_timestamp},
            {"id": source_id + 1, "display_name": alpha,
             "email_address": pair_email, "updated_at": bulk_timestamp},
            {"id": source_id + 2, "display_name": beta,
             "email_address": "issue8-churn-" + str(batch) + "-two@example.test",
             "updated_at": bulk_timestamp},
            {"id": source_id + 3, "display_name": beta,
             "email_address": pair_email, "updated_at": bulk_timestamp},
        ]
        bulk_admissions.append({"rows": rows})
        bulk_source_rows.extend(rows)
    bulk_input = output / "bounded-producer-300-admissions.jsonl"
    bulk_input.write_text("".join(json.dumps(admission, sort_keys=True) + "\n"
        for admission in bulk_admissions))
    bulk_before = json.loads(sql(state_query))
    with tempfile.TemporaryDirectory(prefix="pg-mdm-producer-load-audit-") as temp_dir:
        service_file = Path(temp_dir) / "pg_service.conf"
        service_file.write_text(
            "[batch_source]\n"
            "host=127.0.0.1\nport=" + str(port) + "\ndbname=s1_idle\n"
            "user=mdm_batch_source_writer\nconnect_timeout=10\n\n"
            "[mdm_refresh]\n"
            "host=127.0.0.1\nport=" + str(port) + "\ndbname=s1_idle\n"
            "user=mdm_legacy_login\noptions=-c role=mdm_legacy_administrator\nconnect_timeout=10\n")
        service_file.chmod(0o600)
        environment = os.environ.copy()
        environment["PGSERVICEFILE"] = str(service_file)
        bulk_args = producer_command + [
            "--source-service", "batch_source", "--refresh-service", "mdm_refresh",
            "--table", "public.policy_qualification_source",
            "--columns", "id,display_name,email_address,updated_at",
            "--key-columns", "id", "--entity", "policy_qualification",
            "--policy", "ALLOW", "--input", str(bulk_input),
            "--batch-size", "5", "--rate-per-minute", "60"]
        result = subprocess.run(bulk_args, cwd=root, env=environment,
            capture_output=True, text=True, timeout=420)
        (output / "bounded-producer-300-run.log").write_text(result.stdout + result.stderr)
        assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    assert len(events) == 61, len(events)
    batches, summary = events[:-1], events[-1]
    assert summary["event"] == "producer_complete", summary
    assert (summary["admissions"], summary["source_rows"], summary["offered_admissions"],
        summary["batch_size_limit"], summary["batches"], summary["refresh_calls"],
        summary["transaction_retries"]) == (300, 1200, 300, 5, 60, 60, 0), summary
    assert 298 <= summary["offered_seconds"] <= 302, summary
    assert 59 <= summary["offered_admissions_per_minute"] <= 61, summary
    assert summary["admissions_per_minute"] >= 40, summary
    batch_receipts = []
    for expected_batch, batch in enumerate(batches, 1):
        assert batch["event"] == "batch_complete", batch
        assert (batch["batch"], batch["admissions"], batch["source_rows"]) == (
            expected_batch, 5, 20), batch
        assert batch["transaction_retries"] == 0, batch
        assert batch["source_role"] == "mdm_batch_source_writer", batch
        assert batch["refresh_role"] == "mdm_legacy_administrator", batch
        assert batch["source_database"] == batch["refresh_database"] == "s1_idle", batch
        assert batch["source_txid"] != batch["refresh_txid"], batch
        refresh_result = json.loads(batch["refresh_result"])
        assert refresh_result["changed"] is True and refresh_result["delta_lag"] == 0, refresh_result
        batch_receipts.append({"batch": expected_batch, "source_txid": batch["source_txid"],
            "refresh_txid": batch["refresh_txid"], "refresh_seconds": batch["refresh_seconds"],
            "changed": refresh_result["changed"], "delta_lag": refresh_result["delta_lag"]})
    bulk_after = json.loads(sql(state_query))
    actual_bulk = [dict(row) for row in bulk_after["source"] if row["id"] >= bulk_first_id]
    expected_bulk = [dict(row) for row in bulk_source_rows]
    for row in actual_bulk + expected_bulk:
        row["updated_at"] = timestamp(row["updated_at"]).isoformat()
    assert len(bulk_after["source"]) == len(bulk_before["source"]) + 1200, bulk_after["source"]
    assert actual_bulk == expected_bulk, {"actual_count": len(actual_bulk), "expected_count": 1200}
    bulk_cases = [case for case in bulk_after["cases"]
        if case["case_key"] not in {row["case_key"] for row in bulk_before["cases"]}]
    assert len(bulk_cases) == 300, {"case_count": len(bulk_cases), "cases": bulk_cases}
    before_review_ids = {review["review_id"] for review in bulk_before["reviews"]}
    bulk_reviews = [review for review in bulk_after["reviews"]
        if review["review_id"] not in before_review_ids]
    assert len(bulk_reviews) == 300, {"review_count": len(bulk_reviews), "reviews": bulk_reviews}
    assert {case["review_id"] for case in bulk_cases} == {
        review["review_id"] for review in bulk_reviews}, bulk_cases
    assert all(review["reason_code"] == "ESTABLISHED_NEEDS_TWO_STRONG_CONNECTIONS"
        for review in bulk_reviews), bulk_reviews
    for case in bulk_cases:
        assert case["entity_name"] == "policy_qualification", case
        assert case["status"] == "open" and case["escalation_level"] == 0, case
        assert not case["pending_stewardship"] and not case["manual_assignment_protected"], case
        assert "ESCALATE" in case["permitted_actions"], case
    for collection in ("receipts", "requests", "attempts"):
        assert bulk_after[collection] == bulk_before[collection], collection
    observations["bounded_producer_300"] = {"summary": summary,
        "batch_receipts": batch_receipts, "before": bulk_before, "after": bulk_after,
        "source_rows_inserted": len(actual_bulk), "cases_opened": len(bulk_cases),
        "reviews_opened": len(bulk_reviews), "preserved_requests_receipts_and_attempts": True}
    if installed_wheel:
        observations["bounded_producer_300"]["producer_artifact"] = {
            "type": "installed_wheel",
            "wheel_sha256": observations["bounded_producer_installed_wheel"]["wheel_sha256"]}
    observations["entry_decision"] = "FOCUSED_BOUNDED_CASE_PRODUCER_300_QUALIFIED"
    observations["checks"].append({"name": "300-case-producer-offer-commit-refresh", "result": "passed"})
    print("PASS: 300 case admissions / 1,200 source rows offered at 60/minute through five-case refreshes", flush=True)


def expected_history_guard_health(event_trigger_healthy, policy_function_healthy=True):
    guard_names = [
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
        "role/mdm_retention_guard_owner",
        "function/pgreact_mdm.guard_policy_history_retention()",
        "function/pgreact_mdm.guard_intent_retention_markers()",
        "function/pgreact_mdm.enforce_history_guard_ddl()",
        "function/pgreact_mdm.reject_intent_record_mutation()"]
    guard_names.sort()
    return {
        "all_healthy": event_trigger_healthy and policy_function_healthy,
        "guards": [
            {"guard": name,
             "healthy": (event_trigger_healthy if name == guard_names[0]
                         else policy_function_healthy
                         if name == "function/pgreact_mdm.guard_policy_history_retention()"
                         else True)}
            for name in guard_names]}


def run_retention_guard_monitor_contract(root, report, expected_status, expected_stderr):
    with tempfile.TemporaryDirectory(prefix="pgreact-retention-monitor-") as temp_name:
        temp_dir = Path(temp_name)
        report_path = temp_dir / "report.json"
        report_path.write_text(json.dumps(report, sort_keys=True) + "\n")
        psql_path = temp_dir / "psql"
        psql_path.write_text(
            "#!/usr/bin/env python3\n"
            "import os\n"
            "from pathlib import Path\n"
            "print(Path(os.environ['PGREACT_MONITOR_REPORT_FILE']).read_text(), end='')\n")
        psql_path.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = temp_name + os.pathsep + env.get("PATH", "")
        env["PGSERVICE"] = "retention_monitor_contract"
        env["PGREACT_MONITOR_REPORT_FILE"] = str(report_path)
        result = subprocess.run(
            [sys.executable, str(root / "integrations/pg-mdm/retention_guard_monitor.py")],
            capture_output=True, text=True, timeout=35, env=env)
        expected_stdout = json.dumps(report, sort_keys=True) + "\n"
        assert result.returncode == expected_status, (result.returncode, result.stdout, result.stderr)
        assert result.stdout == expected_stdout, result.stdout
        assert result.stderr == expected_stderr, result.stderr
        return {"exit_code": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "psql": "fixture-backed executable stub"}


def qualify_role_membership_matrix(sql):
    roles = json.loads(sql(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object("
        "'name',role_row.rolname,'login',role_row.rolcanlogin,"
        "'superuser',role_row.rolsuper,'bypass_rls',role_row.rolbypassrls,"
        "'inherit',role_row.rolinherit,'createdb',role_row.rolcreatedb,"
        "'createrole',role_row.rolcreaterole,'replication',role_row.rolreplication,"
        "'memberships',(SELECT COALESCE(jsonb_agg(jsonb_build_object("
        "'role',parent.rolname,'set',membership.set_option,"
        "'inherit',membership.inherit_option,'admin',membership.admin_option) "
        "ORDER BY parent.rolname),'[]') FROM pg_catalog.pg_auth_members membership "
        "JOIN pg_catalog.pg_roles parent ON parent.oid=membership.roleid "
        "WHERE membership.member=role_row.oid)) ORDER BY role_row.rolname),'[]') "
        "FROM pg_catalog.pg_roles role_row WHERE role_row.rolname=ANY(ARRAY["
        "'mdm_s1_runner','mdm_s1_runtime','pgreact_mdm_worker','s1_recovery_operator'])"))
    restricted_paths = json.loads(sql(
        "WITH RECURSIVE role_paths(member_oid,role_oid) AS ("
        "SELECT member,roleid FROM pg_catalog.pg_auth_members UNION "
        "SELECT role_paths.member_oid,membership.roleid FROM role_paths "
        "JOIN pg_catalog.pg_auth_members membership ON membership.member=role_paths.role_oid) "
        "SELECT COALESCE(jsonb_agg(jsonb_build_array(member.rolname,target.rolname) "
        "ORDER BY member.rolname,target.rolname),'[]') FROM role_paths "
        "JOIN pg_catalog.pg_roles member ON member.oid=role_paths.member_oid "
        "JOIN pg_catalog.pg_roles target ON target.oid=role_paths.role_oid "
        "WHERE member.rolname=ANY(ARRAY['mdm_s1_runner','pgreact_mdm_worker']) "
        "AND target.rolname=ANY(ARRAY['mdm_helper_owner','mdm_s1_runtime',"
        "'mdm_legacy_administrator','s1_operator'])"))
    result = {"roles": roles, "restricted_membership_paths": restricted_paths}
    expected = {
        "roles": [
            {"name": "mdm_s1_runner", "login": True, "superuser": False,
             "bypass_rls": False, "inherit": False, "createdb": False,
             "createrole": False, "replication": False,
             "memberships": [{"role": "pgreact_mdm_worker", "set": True,
                              "inherit": False, "admin": False}]},
            {"name": "mdm_s1_runtime", "login": True, "superuser": False,
             "bypass_rls": False, "inherit": True, "createdb": False,
             "createrole": False, "replication": False,
             "memberships": [{"role": "pgreact_mdm_worker", "set": True,
                              "inherit": True, "admin": False}]},
            {"name": "pgreact_mdm_worker", "login": False, "superuser": False,
             "bypass_rls": False, "inherit": False, "createdb": False,
             "createrole": False, "replication": False, "memberships": []},
            {"name": "s1_recovery_operator", "login": True, "superuser": False,
             "bypass_rls": False, "inherit": True, "createdb": False,
             "createrole": False, "replication": False,
             "memberships": [
                 {"role": "pgreact_admin", "set": True, "inherit": True, "admin": False},
                 {"role": "s1_operator", "set": True, "inherit": False, "admin": False}]},
        ],
        "restricted_membership_paths": [],
    }
    assert result == expected, {"actual": result, "expected": expected}
    return result


def main():
    image, output = sys.argv[1:3]
    bounded_producer_wheel_file = None
    if sys.argv[3:4] == ["--bounded-producer-wheel-file"]:
        if len(sys.argv[3:]) != 2:
            raise ValueError("--bounded-producer-wheel-file requires a wheel path")
        bounded_producer_wheel_file = Path(sys.argv[4]).resolve()
        if not bounded_producer_wheel_file.is_file():
            raise FileNotFoundError(bounded_producer_wheel_file)
    maintenance = sys.argv[3:] == ["--maintenance"]
    compatibility_only = sys.argv[3:] == ["--compatibility"]
    outage_mode = sys.argv[3:] == ["--outage"]
    multi_outage = sys.argv[3:] == ["--multi-outage"]
    pending_recovery = sys.argv[3:] == ["--pending-recovery"]
    logical_restore_react_only = sys.argv[3:] == ["--logical-restore-react-only"]
    logical_restore = sys.argv[3:] == ["--logical-restore"] or logical_restore_react_only
    clean_clone = sys.argv[3:] == ["--clean-clone"]
    direct_clone = sys.argv[3:] == ["--clean-clone-direct"]
    autonomous_recurrence = sys.argv[3:] == ["--autonomous-recurrence"]
    claimed_work_crash = sys.argv[3:] == ["--claimed-work-crash"]
    claimed_work_transport_loss = sys.argv[3:] == ["--claimed-work-transport-loss"]
    producer_outage_only = sys.argv[3:] == ["--producer-outage-wheel"]
    bounded_producer_wheel = (sys.argv[3:] == ["--bounded-producer-wheel"]
                              or producer_outage_only
                              or bounded_producer_wheel_file is not None)
    bounded_producer = sys.argv[3:] == ["--bounded-producer"] or bounded_producer_wheel
    claimed_work = (sys.argv[3:] == ["--claimed-work"] or claimed_work_crash
                    or claimed_work_transport_loss)
    temporal_limit = sys.argv[3:] == ["--temporal-limit"]
    dispatcher_recovery = sys.argv[3:] == ["--dispatcher-recovery"]
    statement_time_retry = sys.argv[3:] == ["--statement-time-retry"]
    binding_ddl_lock = sys.argv[3:] == ["--binding-ddl-lock"]
    history_retention = sys.argv[3:] == ["--history-retention"]
    managed_admission_32 = sys.argv[3:] == ["--managed-admission-32"]
    managed_fairness = sys.argv[3:] == ["--managed-fairness"]
    if sys.argv[3:] and not (maintenance or compatibility_only or outage_mode or multi_outage or pending_recovery or logical_restore or clean_clone or direct_clone or autonomous_recurrence or claimed_work or bounded_producer or temporal_limit or dispatcher_recovery or statement_time_retry or binding_ddl_lock or history_retention or managed_admission_32 or managed_fairness):
        raise ValueError("unsupported audit mode after IMAGE OUTPUT")
    output = Path(output).resolve()
    root = Path(__file__).resolve().parents[4]
    adapter_sql = root / "integrations/pg-mdm/sql"
    required_adapter_sql = (
        "comparison.sql", "deadline-preview.sql", "intent-worker.sql",
        "policy-inputs.sql", "request-store.sql", "retention-guard-role.sql",
        "retention-guard-health.sql", "retention-guard.sql",
        "routing.sql", "typed-flow.sql")
    missing_adapter_sql = [name for name in required_adapter_sql if not (adapter_sql / name).is_file()]
    if missing_adapter_sql:
        raise FileNotFoundError("missing pg-mdm adapter SQL sources: " + ", ".join(missing_adapter_sql))
    disk_preflight = require_disk_reserve(output.parent, "bounded producer audit") if bounded_producer else None
    output.mkdir(parents=True, exist_ok=False)
    container = "pgreact-s1-" + uuid.uuid4().hex[:12]
    observations = {"image": image, "checks": [], "entry_decision": "INCOMPLETE", "release_qualified": False}
    if disk_preflight is not None:
        observations["disk_preflight"] = disk_preflight
    profile_path = root / "plans/v0.49-qualification-profile.json"
    profile = json.loads(profile_path.read_text())
    observations["qualification_profile"] = profile
    observations["qualification_profile_sha256"] = hashlib.sha256(profile_path.read_bytes()).hexdigest()
    configured_batch_size = (profile["max_claims_per_cycle"] if managed_admission_32
                             else profile["focused_safety_max_claims_per_cycle"])
    observations["tested_max_claims_per_cycle"] = configured_batch_size
    observations["qualification_scope"] = (
        "Provided exact installed producer wheel through live admission/replay, PostgreSQL restart retry, and 300-admission intake; release qualification is not implied."
        if bounded_producer_wheel_file is not None else
        "Current-source installed producer wheel through a live PostgreSQL restart after a 110-second outage; release qualification is not implied."
        if producer_outage_only else
        "Current-source installed producer wheel through live admission/replay, PostgreSQL restart retry, and 300-admission intake; release qualification is not implied."
        if bounded_producer_wheel else
        "Bounded producer source path through live admission/replay, PostgreSQL restart retry, and 300-admission intake; release qualification is not implied."
        if bounded_producer else
        "Managed-cycle scheduling fairness within and beyond the configured age window; release qualification is not implied."
        if managed_fairness else
        "Exact managed-cycle admission boundary at 32 claims per cycle; release qualification is not implied."
        if managed_admission_32 else
        "Focused safety/recovery at one claim per cycle; release workload capacity is not qualified.")
    created = False
    clone_volume = None

    def command(*args):
        result = subprocess.run(args, capture_output=True, text=True, timeout=300)
        if result.returncode:
            raise RuntimeError(" ".join(args) + "\n" + result.stdout + result.stderr)
        return result.stdout

    def sql(query, database="s1_idle", port=5432):
        return command("docker", "exec", container, "psql", "-XAtq", "-U",
                       "postgres", "-p", str(port), "-d", database,
                       "-v", "ON_ERROR_STOP=1", "-c", query).strip()

    def binding_lock_probe(database):
        sql("CREATE FUNCTION public.binding_lock_temp_probe() RETURNS text "
            "LANGUAGE plpgsql AS $probe$ BEGIN "
            "EXECUTE 'CREATE TEMP TABLE __pgt_recon_123456 (value integer)'; "
            "EXECUTE 'DROP TABLE IF EXISTS pg_temp.__pgt_recon_123456'; "
            "EXECUTE 'CREATE TEMP TABLE binding_lock_explicit (value integer)'; "
            "EXECUTE 'DROP TABLE IF EXISTS pg_temp.binding_lock_explicit'; "
            "RETURN 'TEMP_DDL_COMPLETE'; END $probe$", database)
        holder = subprocess.Popen(
            ["docker", "exec", "-i", container, "psql", "-XAtq", "-U", "postgres",
             "-d", database, "-v", "ON_ERROR_STOP=1"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1)
        holder_pid = None
        granted_lock = None
        try:
            holder.stdin.write("SELECT pg_backend_pid();\n")
            holder.stdin.flush()
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                ready, _, _ = select.select([holder.stdout], [], [], 0.2)
                if not ready:
                    if holder.poll() is not None:
                        raise AssertionError({"error": "coordinator-lock session exited before reporting its pid",
                                              "output": holder.stdout.read()})
                    continue
                line = holder.stdout.readline().strip()
                if line.isdigit():
                    holder_pid = int(line)
                    break
            else:
                raise AssertionError({"error": "lock-holder session did not report its pid"})

            holder.stdin.write("BEGIN;\n"
                               "SELECT pg_catalog.pg_advisory_xact_lock(5788046901200000);\n"
                               "SELECT pg_catalog.pg_sleep(15);\n")
            holder.stdin.flush()
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                lock_rows = json.loads(sql(
                    "SELECT COALESCE(jsonb_agg(jsonb_build_object("
                    "'locktype',locktype,'classid',classid::text,'objid',objid::text,"
                    "'objsubid',objsubid,'granted',granted) ORDER BY locktype,granted), '[]'::jsonb) "
                    "FROM pg_locks WHERE pid = {} AND locktype = 'advisory'".format(holder_pid),
                    database))
                granted_lock = next((row for row in lock_rows
                                     if row["classid"] == "1347634"
                                     and row["objid"] == "2944222336"
                                     and row["objsubid"] == 1 and row["granted"]), None)
                if granted_lock:
                    break
                if holder.poll() is not None:
                    raise AssertionError({"error": "lock-holder session exited before acquiring the coordinator lock",
                                          "pid": holder_pid, "locks": lock_rows})
                time.sleep(0.1)
            else:
                raise AssertionError({"error": "coordinator lock was not granted within 15 seconds",
                                      "pid": holder_pid, "locks": lock_rows})

            def raw_sql(query, timeout=10):
                return subprocess.run(
                    ["docker", "exec", container, "psql", "-XAtq", "-U", "postgres",
                     "-d", database, "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose",
                     "-c", query], capture_output=True, text=True, timeout=timeout)

            temp = raw_sql("SET statement_timeout = '2500ms'; "
                           "SELECT public.binding_lock_temp_probe()", timeout=8)
            assert temp.returncode == 0, {
                "exit_code": temp.returncode, "stdout": temp.stdout, "stderr": temp.stderr}
            assert temp.stdout.strip() == "TEMP_DDL_COMPLETE", temp.stdout
            assert "ERROR:" not in temp.stderr, temp.stderr

            persistent = raw_sql(
                "SET statement_timeout = '1000ms'; "
                "CREATE FUNCTION public.binding_lock_persistent() RETURNS integer "
                "LANGUAGE SQL AS 'SELECT 1'", timeout=8)
            expected_timeout = "ERROR:  57014: canceling statement due to statement timeout"
            assert persistent.returncode == 1, {
                "exit_code": persistent.returncode, "stdout": persistent.stdout,
                "stderr": persistent.stderr}
            assert expected_timeout in persistent.stderr, persistent.stderr
            assert "pgreact_internal.binding_ddl_lock()" in persistent.stderr, persistent.stderr
            assert "pg_advisory_xact_lock(5788046901200000)" in persistent.stderr, persistent.stderr

            persistent_table = raw_sql(
                "SET statement_timeout = '1000ms'; "
                "CREATE TABLE public.binding_lock_persistent_table (value integer)", timeout=8)
            assert persistent_table.returncode == 1, {
                "exit_code": persistent_table.returncode, "stdout": persistent_table.stdout,
                "stderr": persistent_table.stderr}
            assert expected_timeout in persistent_table.stderr, persistent_table.stderr
            assert "pgreact_internal.binding_ddl_lock()" in persistent_table.stderr, persistent_table.stderr
            assert "pg_advisory_xact_lock(5788046901200000)" in persistent_table.stderr, persistent_table.stderr
        finally:
            if holder.poll() is None:
                if holder_pid is not None:
                    sql("SELECT pg_terminate_backend({})".format(holder_pid), database)
                try:
                    holder.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    holder.terminate()
                    holder.wait(timeout=5)
        after_release = sql(
            "CREATE TABLE public.binding_lock_persistent_table (value integer); "
            "CREATE FUNCTION public.binding_lock_persistent() RETURNS text "
            "LANGUAGE SQL AS 'SELECT ''PERSISTENT_DDL_COMPLETE''' ; "
            "SELECT CASE WHEN to_regclass('public.binding_lock_persistent_table') IS NOT NULL "
            "THEN 'TABLE_DDL_COMPLETE' ELSE 'TABLE_DDL_MISSING' END || ':' || "
            "public.binding_lock_persistent()", database)
        assert after_release == "TABLE_DDL_COMPLETE:PERSISTENT_DDL_COMPLETE", after_release
        return {
            "temp_relation_ddl_while_coordinator_locked": {
                "exit_code": temp.returncode, "stdout": temp.stdout.strip(), "stderr": temp.stderr.strip()},
            "persistent_function_ddl_while_coordinator_locked": {
                "exit_code": persistent.returncode, "sqlstate": "57014",
                "error": "canceling statement due to statement timeout",
                "coordinator_lock_context": "pgreact_internal.binding_ddl_lock()"},
            "persistent_table_ddl_while_coordinator_locked": {
                "exit_code": persistent_table.returncode, "sqlstate": "57014",
                "error": "canceling statement due to statement timeout",
                "coordinator_lock_context": "pgreact_internal.binding_ddl_lock()"},
            "persistent_ddl_after_coordinator_release": after_release,
            "coordinator_lock_holder_pid": holder_pid,
            "granted_coordinator_lock": granted_lock,
            "result": "passed",
        }

    def recovery_sql(query):
        return sql("SET SESSION AUTHORIZATION s1_recovery_operator; " + query, "s1_logical")

    assert timestamp("2026-10-27 14:15:28.957184+00") == datetime.datetime(
        2026, 10, 27, 14, 15, 28, 957184, tzinfo=datetime.timezone.utc)
    assert timestamp("2026-10-27T09:24:55.69977+00:00") == datetime.datetime(
        2026, 10, 27, 9, 24, 55, 699770, tzinfo=datetime.timezone.utc)

    def fixture(name, file, database="foundation", variables=()):
        started = time.monotonic()
        try:
            result = command("docker", "exec", container, "psql", "-XAtq", "-U",
                             "postgres", "-d", database, "-v", "ON_ERROR_STOP=1", *variables, "-f", file)
        except RuntimeError as error:
            (output / (name + ".log")).write_text(str(error))
            observations["checks"].append({"name": name, "result": "failed"})
            raise
        (output / (name + ".log")).write_text(result)
        observations["checks"].append({"name": name, "result": "passed",
                                       "seconds": time.monotonic() - started})
        print("PASS: " + name, flush=True)
        return result

    def current_mdm_bootstrap_fixture():
        original = command("docker", "exec", container, "cat", "/tests/e2e.sql")
        original_sha256 = command(
            "docker", "exec", container, "sha256sum", "/tests/e2e.sql").split()[0]
        old_pin = "CREATE EXTENSION pg_trickle VERSION '0.108.3';"
        if original.count(old_pin) != 1:
            raise AssertionError(
                "pinned pg-mdm e2e.sql must contain exactly one pg_trickle 0.108.3 install")
        adapted = original.replace(old_pin, "CREATE EXTENSION pg_trickle;", 1)
        target = "/tests/e2e-current-pgtrickle.sql"
        adapted_path = output / "mdm-e2e-current-pgtrickle.sql"
        adapted_path.write_text(adapted)
        command("docker", "cp", str(adapted_path), container + ":" + target)
        adapted_sha256 = hashlib.sha256(adapted_path.read_bytes()).hexdigest()
        candidate_version = sql(
            "SELECT default_version FROM pg_available_extensions WHERE name='pg_trickle'",
            "postgres")
        observations["mdm_e2e_bootstrap_fixture"] = {
            "source_path": "/tests/e2e.sql",
            "source_sha256": original_sha256,
            "adapted_path": target,
            "adapted_sha256": adapted_sha256,
            "candidate_pg_trickle_version": candidate_version,
            "change": "replace the upstream 0.108.3 pin with the candidate image default",
        }
        return target

    def cases():
        return json.loads(sql("SELECT jsonb_agg(to_jsonb(c) ORDER BY c.case_key) "
                              "FROM mdm_steward.policy_cases_v1 c"))

    def qualify_recovery(state_query, pending=False):
        before = json.loads(sql(state_query))
        source_oid = int(sql("SELECT oid FROM pg_database WHERE datname=current_database()"))
        assert sql(
            "SELECT r.state='active' AND r.database_oid=" + str(source_oid) +
            " FROM pgreact_mdm.policy_intent_bindings b "
            "JOIN mdm_internal.policy_binding_runtime r USING(binding_id) "
            "WHERE b.policy_revision='s1-idle-feasibility' AND b.enabled") == "t"
        sql("ALTER DATABASE s1_idle ALLOW_CONNECTIONS false", "postgres")
        sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='s1_idle'", "postgres")
        try:
            command("docker", "exec", container, "createdb", "-U", "postgres",
                    "--template=s1_idle", "s1_clone")
        finally:
            sql("ALTER DATABASE s1_idle ALLOW_CONNECTIONS true", "postgres")
        assert int(sql("SELECT oid FROM pg_database WHERE datname=current_database()",
                       "s1_clone")) != source_oid
        assert json.loads(sql(state_query, "s1_clone")) == before
        fixture("active-template-clone-guard",
                "/work/tests/integrations/pg-mdm/time/recovery.sql", "s1_clone",
                ("-v", "pending=" + str(pending).lower()))
        assert json.loads(sql(state_query, "s1_clone")) == before
        observations["active_template_clone"] = {
            "source_database_oid": source_oid,
            "clone_database_oid": int(sql(
                "SELECT oid FROM pg_database WHERE datname=current_database()", "s1_clone")),
            "complete_state": before, "unchanged_before_activation": True,
        }
        if pending:
            sql("SELECT pgtrickle.recover_capture_instance()", "s1_clone")
            fixture("template-clone-pending-reconcile",
                    "/work/tests/integrations/pg-mdm/time/recovery.sql", "s1_clone",
                    ("-v", "pending=true", "-v", "activate=true"))
            assert json.loads(sql(state_query, "s1_clone")) == before
            # Capture adoption deliberately suspends copied streams until the operator resumes them.
            sql("SELECT pgtrickle.resume_stream_table(format('%I.%I',pgt_schema,pgt_name)) "
                "FROM pgtrickle.pgt_stream_tables WHERE status='SUSPENDED' ORDER BY pgt_id", "s1_clone")
            drain_restored_pending(state_query, before, "s1_clone")
            assert json.loads(sql(state_query)) == before, "clone recovery changed the source"

        # Pause through the entity authority before taking a coherent backup.
        binding = json.loads(sql(
            "SELECT jsonb_build_object('id',b.binding_id,'version',r.runtime_version) "
            "FROM pgreact_mdm.policy_intent_bindings b "
            "JOIN mdm_internal.policy_binding_runtime r USING(binding_id) "
            "WHERE b.policy_revision='s1-idle-feasibility' AND b.enabled"))
        sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
            "SELECT pgreact_mdm.pause_intent_binding('" + str(uuid.UUID(binding["id"])) +
            "'::uuid," + str(int(binding["version"])) + ")")
        assert json.loads(sql(state_query)) == before
        started = time.monotonic()
        wal_before = sql("SELECT pg_current_wal_insert_lsn()")
        resource_before = json.loads(command(
            "docker", "stats", "--no-stream", "--format", "{{json .}}", container))
        backup_started = time.monotonic()
        command("docker", "exec", "--user", "postgres", container,
                "pg_basebackup", "-U", "postgres", "-D", "/tmp/s1-recovered",
                "--wal-method=stream", "--checkpoint=fast")
        backup_seconds = time.monotonic() - backup_started
        restore_started = time.monotonic()
        command("docker", "exec", "--user", "postgres", container,
                "pg_ctl", "-D", "/tmp/s1-recovered", "-l", "/tmp/s1-recovered.log",
                "-o", "-p 55432 -k /var/run/postgresql -c max_worker_processes=64 "
                "-c pg_react.databases=s1_idle -c pg_react.worker_role=mdm_s1_runtime -c pg_react.batch_size=1 "
                "-c shared_preload_libraries=pg_trickle,pg_mdm,pg_react "
                "-c pg_react.poll_interval_ms=1000 -c pg_trickle.enabled=off "
                "-c pg_trickle.cdc_mode=trigger -c pg_trickle.differential_max_change_ratio=1.0 "
                "-c default_transaction_isolation='read committed'", "-w", "start")
        startup_seconds = time.monotonic() - restore_started
        try:
            assert sql("SELECT current_setting('pg_react.databases')", port=55432) == "s1_idle"
            assert int(sql("SELECT oid FROM pg_database WHERE datname=current_database()",
                           port=55432)) == source_oid
            assert json.loads(sql(state_query, port=55432)) == before
            for name, activate in (("physical-restore-guard", False),
                                   ("physical-restore-reconcile-replay", True)):
                result = command("docker", "exec", container, "psql", "-XAtq",
                                 "-U", "postgres", "-p", "55432", "-d", "s1_idle",
                                 "-v", "ON_ERROR_STOP=1", "-v", "activate=" + str(activate).lower(),
                                 "-v", "pending=" + str(pending).lower(),
                                 "-f", "/work/tests/integrations/pg-mdm/time/recovery.sql")
                (output / (name + ".log")).write_text(result)
                recovery_state = json.loads(sql(state_query, port=55432))
                if pending and activate:
                    # The configured worker may complete the remaining item
                    # as soon as explicit MDM reconciliation succeeds.
                    observations["physical_recovery_activation_state"] = recovery_state
                else:
                    assert recovery_state == before
                observations["checks"].append({"name": name, "result": "passed"})
                print("PASS: " + name, flush=True)
            observations["physical_recovery"] = {
                "same_database_oid": source_oid,
                "postmaster_start": sql("SELECT pg_postmaster_start_time()", port=55432),
                "seconds": time.monotonic() - started,
                "backup_seconds": backup_seconds,
                "restore_startup_seconds": startup_seconds,
                "source_database_bytes": int(sql("SELECT pg_database_size(current_database())")),
                "source_wal_bytes_during_recovery": int(sql(
                    "SELECT pg_wal_lsn_diff(pg_current_wal_insert_lsn(),'" + wal_before + "')::bigint")),
                "container_resources_before_backup": resource_before,
                "container_resources_with_restored_server": json.loads(command(
                    "docker", "stats", "--no-stream", "--format", "{{json .}}", container)),
                "measurement_scope": "Disposable recovery drill; shared-container resource samples, not workload capacity or process-memory limits.",
                "managed_worker_configured_on_restore_startup": True,
                "delivery_blocked_until_mdm_reconciliation": True,
                "complete_state": before,
                "unchanged_before_and_after_explicit_reconciliation": True,
            }
            if pending:
                drain_restored_pending(state_query, before, "s1_idle", 55432,
                                       automatic=True, already_running=True)
            observations["physical_recovery"]["seconds"] = time.monotonic() - started
            assert observations["physical_recovery"]["seconds"] <= profile["recovery_max_seconds"]
        finally:
            command("docker", "exec", "--user", "postgres", container,
                    "pg_ctl", "-D", "/tmp/s1-recovered", "-m", "fast", "-w", "stop")
        assert json.loads(sql(state_query)) == before, "recovery test changed the source effects"

    def drain_restored_pending(state_query, before, database, port=5432, automatic=False, already_running=False):
        pending_work = [w for w in before["work"] if w["state"] == "PENDING"]
        assert len(pending_work) == 1 and pending_work[0]["claimable"], pending_work
        pending_id = pending_work[0]["work_id"]
        context = json.loads(sql(
            "SELECT jsonb_build_object('case_key',(new_bindings->>'case_key')::bigint,"
            "'activation_id',activation_id,'rule_version_id',rule_version_id,"
            "'generation',activation_generation,'revision',activation_revision) "
            "FROM pgreact_internal.agenda WHERE episode_id=" + str(int(pending_id)), database, port))
        case = next(c for c in before["cases"] if c["case_key"] == context["case_key"])
        binding = json.loads(sql(
            "SELECT to_jsonb(b) FROM pgreact_mdm.policy_intent_bindings b "
            "WHERE b.enabled AND b.policy_revision='s1-idle-feasibility'", database, port))
        body = {
            "action": "ESCALATE", "arguments": {"level": 2}, "case_key": case["case_key"],
            "binding_id": binding["binding_id"], "policy_revision": "s1-idle-feasibility",
            "expected_policy_digest": binding["policy_digest"][2:],
            "expected_evidence_basis_digest": case["evidence_basis_digest"][2:],
            "evaluation_ref": "pgreact:" + context["activation_id"],
            "work_ref": "pgreact:" + context["rule_version_id"] + ":" + pending_id,
            **{"expected_" + name: case[name] for name in ("review_version", "definition_version",
                "publication_revision", "stewardship_epoch", "action_revision")}}
        key = sql("SELECT encode(pgreact_mdm.intent_request_key('{}'::uuid,"
            "'s1-idle-feasibility',{},{},{},'escalate_level_2',2),'hex')".format(
                binding["binding_id"], case["case_key"], context["generation"], case["action_revision"]), database, port)
        digest = sql("SELECT encode(pgreact_mdm.intent_request_digest('" +
            json.dumps(body).replace("'", "''") + "'::jsonb),'hex')", database, port)
        started = time.monotonic()
        if automatic:
            if not already_running:
                command("docker", "exec", "--user", "postgres", container,
                        "pg_ctl", "-D", "/tmp/s1-recovered", "-l", "/tmp/s1-recovered.log", "-m", "fast", "-w", "restart",
                        "-o", "-p 55432 -k /var/run/postgresql -c max_worker_processes=64 "
                        "-c pg_react.databases=s1_idle "
                        "-c pg_react.worker_role=mdm_s1_runtime -c pg_react.batch_size=1 "
                        "-c pg_react.poll_interval_ms=1000 -c pg_trickle.enabled=off "
                        "-c pg_trickle.cdc_mode=trigger -c pg_trickle.differential_max_change_ratio=1.0 "
                        "-c default_transaction_isolation='read committed'")
            end = started + profile["recovery_max_seconds"]
            while time.monotonic() < end:
                if sql("SELECT state FROM pgreact.work WHERE work_id='" + pending_id + "'", database, port) == "COMPLETED":
                    # Read the worker after completion commits; a prior poll can still contain the copied PID.
                    status = json.loads(sql("SELECT pgreact_api.managed_status()", database, port))
                    observations["restored_pending_worker_status"] = status
                    break
                time.sleep(0.2)
            else:
                timeout_state = {
                    "managed_status": json.loads(sql("SELECT pgreact_api.managed_status()", database, port)),
                    "work": json.loads(sql("SELECT jsonb_agg(to_jsonb(w) ORDER BY work_id) "
                                           "FROM pgreact.work w WHERE name='s1-future-idle'", database, port)),
                    "background_workers": json.loads(sql(
                        "SELECT COALESCE(jsonb_agg(jsonb_build_object('application_name',application_name,"
                        "'backend_type',backend_type,'usename',usename,'state',state) ORDER BY pid),'[]') "
                        "FROM pg_stat_activity WHERE backend_type='background worker'", database, port)),
                    "max_worker_processes": int(sql("SELECT current_setting('max_worker_processes')", database, port)),
                }
                observations["restored_pending_timeout"] = timeout_state
                raise AssertionError("restored background worker did not drain pending escalation: " +
                                     json.dumps(timeout_state, sort_keys=True))
            cycle = {"pid": status["process"]["pid"]}
            assert sql("SELECT usename FROM pg_stat_activity WHERE pid=" + str(int(cycle["pid"])), database, port) == "mdm_s1_runtime"
        else:
            cycle = json.loads(sql("SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "
                                   "SELECT jsonb_build_object('result',pgreact_api.managed_cycle(),"
                                   "'pid',pg_backend_pid())", database, port))
            result = cycle["result"]
            assert result["state"] == "ready" and result["processed_jobs"] == 1, result
        after = json.loads(sql(state_query, database, port))
        expected_cases = copy.deepcopy(before["cases"])
        expected_case = next(c for c in expected_cases if c["case_key"] == case["case_key"])
        expected_case["escalation_level"] = 2
        expected_case["action_revision"] += 1
        assert after["cases"] == expected_cases
        assert after["business"] == before["business"] and after["technical"] == before["technical"]
        assert after["identities"] == before["identities"]
        assert after["identity_sequence"] == before["identity_sequence"]
        assert after["holds"] == before["holds"]
        new_receipts = [r for r in after["receipts"] if r not in before["receipts"]]
        assert len(new_receipts) == 1, new_receipts
        receipt = new_receipts[0]
        uuid.UUID(receipt["receipt_id"])
        assert datetime.datetime.fromisoformat(receipt["publication_tracking_started_at"]) <= datetime.datetime.fromisoformat(receipt["created_at"]), receipt
        expected_receipt = {
            "receipt_id": receipt["receipt_id"], "created_at": receipt["created_at"],
            "publication_tracking_started_at": receipt["publication_tracking_started_at"],
            "actor": "pgreact_mdm_worker", "selected_role_name": "pgreact_mdm_worker",
            "session_role_name": "mdm_s1_runtime", "action": "ESCALATE", "outcome": "APPLIED_CONTROL",
            "reason_code": "CONTROL_APPLIED", "case_key": case["case_key"],
            "binding_id": binding["binding_id"], "binding_version": binding["binding_version"],
            "action_revision": expected_case["action_revision"], "resulting_publication_revision": None,
            "request_body": body, "request_key": "\\x" + key, "request_digest": "\\x" + digest,
            "control": {k: expected_case[k] for k in
                        ("assigned_queue", "due_at", "escalation_level", "manual_assignment_protected")}}
        expected_receipt["control"]["due_at"] = sql(
            "SELECT due_at::text FROM mdm_steward.policy_cases_v1 WHERE case_key=" + str(case["case_key"]), database, port)
        assert new_receipts == [expected_receipt], {"expected": expected_receipt, "actual": new_receipts}
        assert after["receipts"] == before["receipts"] + [expected_receipt]
        new_requests = [r for r in after["requests"] if r not in before["requests"]]
        new_intent_attempts = [a for a in after["intent_attempts"] if a not in before["intent_attempts"]]
        assert len(new_requests) == len(new_intent_attempts) == 1
        request = new_requests[0]
        intent_attempt = new_intent_attempts[0]
        assert new_requests == [{
            "binding_id": binding["binding_id"], "request_key": "\\x" + key,
            "request_digest": "\\x" + digest, "request_body": body, "work_ref": body["work_ref"],
            "policy_revision": "s1-idle-feasibility", "case_key": case["case_key"],
            "lifecycle_generation": context["generation"], "action_revision": case["action_revision"],
            "consequence_identity": "escalate_level_2", "escalation_level": 2,
            "first_episode_id": int(pending_id), "created_at": request["created_at"]}], new_requests
        assert new_intent_attempts == [{
            "episode_id": int(pending_id), "attempt_no": 1,
            **{k: expected_receipt[k] for k in ("binding_id", "request_key", "request_digest",
                "request_body", "receipt_id", "outcome", "reason_code", "case_key", "action_revision",
                "control", "resulting_publication_revision")},
            "work_ref": body["work_ref"], "attempted_at": intent_attempt["attempted_at"]}], new_intent_attempts
        assert [r for r in after["requests"] if r not in new_requests] == before["requests"]
        assert [a for a in after["intent_attempts"] if a not in new_intent_attempts] == before["intent_attempts"]
        expected_work = copy.deepcopy(before["work"])
        restored_work = next(w for w in after["work"] if w["work_id"] == pending_id)
        expected_pending = next(w for w in expected_work if w["work_id"] == pending_id)
        expected_pending.update(state="COMPLETED", claimable=False, updated_at=restored_work["updated_at"])
        assert after["work"] == expected_work
        assert [a for a in after["attempts"] if str(a["episode_id"]) != pending_id] == before["attempts"]
        new_attempts = [a for a in after["attempts"] if str(a["episode_id"]) == pending_id]
        assert len(new_attempts) == 1, new_attempts
        attempt = new_attempts[0]
        assert new_attempts == [{
            "execution_id": attempt["execution_id"], "episode_id": int(pending_id), "attempt_no": 1,
            "worker_id": "pg-react-managed/" + database + "/" + str(cycle["pid"]),
            "status": "COMPLETED", "error_message": None, "error_code": None,
            "started_at": attempt["started_at"], "finished_at": attempt["finished_at"],
            "event_kind": "ACTIVATE", "name": "s1-future-idle"}], new_attempts
        assert timestamp(case["due_at"]) <= timestamp(attempt["started_at"]) <= timestamp(request["created_at"])
        # MDM receipts use statement_timestamp(); adapter audit rows use clock_timestamp().
        assert timestamp(case["due_at"]) <= timestamp(receipt["created_at"]) <= timestamp(attempt["finished_at"])
        assert timestamp(request["created_at"]) <= timestamp(intent_attempt["attempted_at"])
        assert timestamp(intent_attempt["attempted_at"]) <= timestamp(attempt["finished_at"])
        assert timestamp(attempt["finished_at"]) <= timestamp(restored_work["updated_at"])
        name = "pending-recovery-" + database + "-" + str(port)
        observations[name] = {"before": before, "expected_cases": expected_cases,
                              "expected_receipt": expected_receipt, "after": after,
                              "background_worker": automatic, "no_replay": False}
        if automatic and status["process"]["state"] == "error":
            observations["checks"].append({"name": name, "result": "failed", "actual": status})
            raise AssertionError("restored worker delivered pending work but evaluation is blocked: " + str(status))
        if automatic:
            first = timestamp(status["process"]["heartbeat_at"])
            end = started + profile["recovery_max_seconds"]
            while time.monotonic() < end:
                status = json.loads(sql("SELECT pgreact_api.managed_status()", database, port))
                observations["restored_later_worker_status"] = status
                if status["process"]["state"] == "ready" and timestamp(status["process"]["heartbeat_at"]) > first + datetime.timedelta(seconds=3):
                    break
                time.sleep(0.2)
            else:
                raise AssertionError("restored background worker did not complete later cycles: " + str(status))
        else:
            for _ in range(2):
                result = json.loads(sql("SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "
                                        "SELECT pgreact_api.managed_cycle()", database, port))
                assert result["state"] == "ready" and result["processed_jobs"] == 0, result
        final_state = json.loads(sql(state_query, database, port))
        clock_fields = {"clock_frontier", "clock_history", "clock_history_sequence"}
        prior_temporal_history = after["temporal_history"]
        final_temporal_history = final_state["temporal_history"]
        assert final_temporal_history[:len(prior_temporal_history)] == prior_temporal_history, \
            "temporal history was rewritten"
        new_temporal_observations = final_temporal_history[len(prior_temporal_history):]
        prior_temporal_sequence = after["temporal_history_sequence"]
        assert final_state["temporal_history_sequence"] == prior_temporal_sequence + len(new_temporal_observations)
        temporal_states = {
            (state["rule_version_id"], state["semantic_key"]): state
            for state in final_state["temporal_state"]
        }
        for offset, event in enumerate(new_temporal_observations, start=1):
            state = temporal_states[(event["rule_version_id"], event["semantic_key"])]
            assert event["temporal_event_id"] == prior_temporal_sequence + offset, event
            assert event["event_kind"] == "OBSERVE" and event["lifecycle_event_id"] is None, event
            assert event["primitive_state"] == state["state"]
            assert event["input_true"] == state["input_true"]
            assert event["recovery_true"] == state["recovery_true"]
            assert event["bindings"] == state["last_bindings"]
            assert event["pending_deadline"] == state["pending_deadline"]
            assert event["continuous_since"] == state["continuous_since"]
            assert event["cooldown_until"] == state["cooldown_until"]
        final_state_without_frontier = copy.deepcopy(final_state)
        after_without_frontier = copy.deepcopy(after)
        for state in (final_state_without_frontier, after_without_frontier):
            state.pop("temporal_history")
            state.pop("temporal_history_sequence")
            for temporal_state in state.get("temporal_state", []):
                temporal_state.pop("last_frontier", None)
                temporal_state.pop("updated_at", None)
        actual = {key: value for key, value in final_state_without_frontier.items() if key not in clock_fields}
        expected = {key: value for key, value in after_without_frontier.items() if key not in clock_fields}
        if actual != expected:
            differences = []

            def record_differences(left, right, path):
                if len(differences) >= 30 or left == right:
                    return
                if isinstance(left, dict) and isinstance(right, dict):
                    for key in sorted(set(left) | set(right)):
                        record_differences(left.get(key), right.get(key), path + "." + key)
                elif isinstance(left, list) and isinstance(right, list):
                    if len(left) != len(right):
                        differences.append({"path": path, "before_count": len(right), "after_count": len(left)})
                    else:
                        for index, (old, new) in enumerate(zip(right, left)):
                            record_differences(new, old, path + "[" + str(index) + "]")
                else:
                    differences.append({"path": path, "before": right, "after": left})

            record_differences(actual, expected, "state")
            raise AssertionError({"error": "restored work replayed", "differences": differences})
        prior_events = after["clock_history"]
        clock_events = final_state["clock_history"]
        assert clock_events[:len(prior_events)] == prior_events, "clock history was rewritten"
        new_clock_events = clock_events[len(prior_events):]
        previous_frontier = after["clock_frontier"]["frontier"]
        previous_event_id = after["clock_history_sequence"]
        for event in new_clock_events:
            assert event["clock_event_id"] == previous_event_id + 1, event
            assert event["previous_frontier"] == previous_frontier, event
            assert timestamp(event["frontier"]) > timestamp(previous_frontier), event
            assert event["affected_keys"] == event["affected_rules"] == 0, event
            previous_frontier = event["frontier"]
            previous_event_id = event["clock_event_id"]
        assert final_state["clock_history_sequence"] == previous_event_id
        assert final_state["clock_frontier"]["frontier"] == previous_frontier
        if new_clock_events:
            assert final_state["clock_frontier"]["last_sampled_time"] == new_clock_events[-1]["sampled_time"]
        observations[name]["zero_effect_clock_events"] = new_clock_events
        assert sql("SELECT has_table_privilege('pgreact_mdm_worker',"
                   "'pgtrickle.pgt_dependencies','SELECT')", database, port) == "f"
        elapsed = time.monotonic() - started
        assert elapsed <= profile["backlog_drain_max_seconds"]
        observations[name].update(drain_seconds=elapsed, no_replay=True)
        observations["checks"].append({"name": name, "result": "passed"})
        print("PASS: " + name, flush=True)

    def qualify_pending_recovery():
        sql("SELECT pgreact_api.pause_rule('s1-callback-failure')")
        end = time.monotonic() + 60
        while sql("SELECT bool_and(deadline <= clock_timestamp()) FROM s1_audit.source") != "t":
            assert time.monotonic() < end, "pending recovery setup did not reach both deadlines"
            time.sleep(0.2)
        # Fixture setup queues work; delivery below uses the restricted runtime login.
        sql("SELECT pgreact_api.run()")
        work = json.loads(sql("SELECT jsonb_agg(to_jsonb(w) ORDER BY work_id) "
                              "FROM pgreact.work w WHERE name='s1-future-idle'"))
        assert [{k: w[k] for k in ("state", "claimable")} for w in work] == [
            {"state": "PENDING", "claimable": True}, {"state": "PENDING", "claimable": True}], work
        result = json.loads(sql("SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "
                                "SELECT pgreact_api.managed_cycle()"))
        assert result["state"] == "ready" and result["processed_jobs"] == 1, result
        if logical_restore:
            paused_version = sql("SELECT version.rule_version_id FROM pgreact_internal.rule_versions version "
                "JOIN pgreact_internal.rules rule USING (rule_id) "
                "WHERE rule.rule_name='s1-callback-failure' AND version.state='PAUSED'")
            uuid.UUID(paused_version)
            sql("SELECT pgreact.begin_reconciliation('" + paused_version + "'::uuid)")
            repaired = sql("SELECT pgreact.reconcile_rule('" + paused_version + "'::uuid,'STATE_ONLY')")
            assert repaired == "2", {"rule_version_id": paused_version, "rows_repaired": repaired}
        state_query = (
            "SELECT jsonb_build_object("
            "'mdm_entity',(SELECT to_jsonb(e) FROM mdm_internal.entities e "
            "WHERE e.entity_name='policy_qualification'),"
            "'mdm_policy_bindings',(SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY b.binding_id),'[]') "
            "FROM mdm_steward.policy_bindings_v1 b JOIN mdm_internal.entities e USING (entity_id) "
            "WHERE e.entity_name='policy_qualification'),"
            "'mdm_adapter_bindings',(SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY b.binding_id),'[]') "
            "FROM pgreact_mdm.policy_intent_bindings b WHERE b.entity_name='policy_qualification'),"
            "'cases',(SELECT jsonb_agg(to_jsonb(c) ORDER BY case_key) FROM mdm_steward.policy_cases_v1 c),"
            "'receipts',(SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id) FROM mdm_steward.policy_receipts_v1 r),"
            "'requests',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id,request_key),'[]') FROM pgreact_mdm.intent_requests r),"
            "'intent_attempts',(SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY episode_id,attempt_no),'[]') FROM pgreact_mdm.intent_attempts a),"
            "'holds',(SELECT COALESCE(jsonb_agg(to_jsonb(h) ORDER BY binding_id,case_key,policy_revision,expected_action_revision),'[]') FROM pgreact_mdm.intent_holds h),"
            "'identities',(SELECT COALESCE(jsonb_agg(to_jsonb(i) ORDER BY case_identity),'[]') FROM pgreact_mdm.intent_case_identities i),"
            "'identity_sequence',(SELECT jsonb_build_object('last_value',last_value,'is_called',is_called) FROM pgreact_mdm.intent_case_identities_case_identity_seq),"
            "'work',(SELECT jsonb_agg(to_jsonb(w) ORDER BY work_id) FROM pgreact.work w WHERE name='s1-future-idle'),"
            "'attempts',(SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY execution_id),'[]') FROM pgreact.attempts a WHERE name='s1-future-idle'),"
            "'business',(SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM public.policy_qualification_source s),"
            "'technical',(SELECT jsonb_agg(to_jsonb(s) ORDER BY case_key) FROM s1_audit.source s))")
        if logical_restore or pending_recovery or clean_clone or direct_clone:
            state_query = state_query[:-1] + (
                ",'rules',(SELECT COALESCE(jsonb_agg((to_jsonb(r)-'owner_oid') || "
                "jsonb_build_object('owner_actual',pg_get_userbyid(r.owner_oid)) ORDER BY rule_id),'[]') FROM pgreact_internal.rules r),"
                "'rule_versions',(SELECT COALESCE(jsonb_agg((to_jsonb(v)-ARRAY['owner_oid','source_view_oid','match_relid','consequence_oid','dispatcher_oid']) || "
                "jsonb_build_object('owner_actual',pg_get_userbyid(v.owner_oid),"
                "'owner_name',(SELECT r.owner_name FROM pgreact_internal.rules r WHERE r.rule_id=v.rule_id),"
                "'source_identity',CASE WHEN v.state='REMOVED' THEN v.source_view_name "
                "ELSE v.source_view_oid::regclass::text END,"
                "'match_identity',v.match_relid::regclass::text,'consequence_actual',v.consequence_oid::regprocedure::text,"
                "'dispatcher_actual',v.dispatcher_oid::regprocedure::text) ORDER BY rule_version_id),'[]') FROM pgreact_internal.rule_versions v),"
                "'activations',(SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY rule_version_id,activation_id),'[]') FROM pgreact_internal.activation_state a),"
                "'events',(SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY event_id),'[]') FROM pgreact_internal.lifecycle_events e),"
                "'application_roles',(SELECT COALESCE(jsonb_agg(jsonb_build_object('role_kind',role_kind,"
                "'role_name',pg_get_userbyid(role_oid)) ORDER BY role_kind),'[]') FROM pgreact_internal.application_roles))")
            state_query = state_query[:-1] + (
                ",'bindings',(SELECT COALESCE(jsonb_agg((to_jsonb(b)-ARRAY['function_oid','dispatcher_oid']) || "
                "jsonb_build_object('function_actual',b.function_oid::regprocedure::text,"
                "'dispatcher_actual',b.dispatcher_oid::regprocedure::text) ORDER BY rule_version_id,event_kind),'[]') "
                "FROM pgreact_internal.consequence_bindings b),"
                "'barriers',(SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY rule_version_id),'[]') FROM pgreact_internal.rule_barriers b),"
                "'agenda',(SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY episode_id),'[]') FROM pgreact_internal.agenda a),"
                "'executions',(SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY execution_id),'[]') FROM pgreact_internal.executions e),"
                "'react_sequences',jsonb_build_object("
                "'lifecycle_events',pg_sequence_last_value(pg_get_serial_sequence('pgreact_internal.lifecycle_events','event_id')::regclass),"
                "'agenda',pg_sequence_last_value(pg_get_serial_sequence('pgreact_internal.agenda','episode_id')::regclass),"
                "'executions',pg_sequence_last_value(pg_get_serial_sequence('pgreact_internal.executions','execution_id')::regclass)))")
            # Recovery rebuilds this diagnostic timestamp from the clock-history log.
            state_query = state_query[:-1] + (
                ",'deadline_rules',(SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY d.rule_version_id),'[]') "
                "FROM pgreact_internal.deadline_rules d),"
                "'deadline_lifecycle',(SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY d.event_id),'[]') "
                "FROM pgreact_internal.deadline_lifecycle d),"
                "'clock_frontier',(SELECT to_jsonb(c)-'last_advanced_at' "
                "FROM pgreact_internal.clock_frontier c WHERE c.singleton),"
                "'clock_history',(SELECT COALESCE(jsonb_agg(to_jsonb(h) ORDER BY h.clock_event_id),'[]') "
                "FROM pgreact_internal.clock_history h),"
                "'clock_history_sequence',pg_sequence_last_value(pg_get_serial_sequence("
                "'pgreact_internal.clock_history','clock_event_id')::regclass),"
                "'temporal_rules',(SELECT COALESCE(jsonb_agg(to_jsonb(t)-'recovery_condition_oid' "
                "ORDER BY t.rule_version_id),'[]') "
                "FROM pgreact_internal.temporal_rules t),"
                "'temporal_state',(SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.rule_version_id,t.semantic_key),'[]') "
                "FROM pgreact_internal.temporal_state t),"
                "'temporal_history',(SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.temporal_event_id),'[]') "
                "FROM pgreact_internal.temporal_history t),"
                "'temporal_history_sequence',COALESCE(pg_sequence_last_value(pg_get_serial_sequence("
                "'pgreact_internal.temporal_history','temporal_event_id')::regclass),0),"
                "'agenda_group_limits',(SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.agenda_group),'[]') "
                "FROM pgreact_internal.agenda_group_limits l),"
                "'operational_settings',(SELECT to_jsonb(s)-ARRAY['updated_at','updated_by'] "
                "FROM pgreact_internal.operational_settings s "
                "WHERE s.singleton),"
                "'operational_settings_snapshot',(SELECT s.settings-ARRAY['updated_at','updated_by'] "
                "FROM pgreact_internal.operational_settings_snapshot s WHERE s.singleton))")
        if logical_restore:
            sql("SELECT pgreact.configure_operations(100, 3599, interval '30 seconds', 10000)")
            seeded = fixture("logical-restore-temporal-probe-seed",
                "/work/tests/integrations/pg-mdm/time/temporal-restore-seed.sql", "s1_idle")
            assert seeded == "logical_restore_temporal_probe_seeded\n", seeded
        before = json.loads(sql(state_query))
        observations["pending_setup"] = {"cycle": result, "state": before}
        assert sorted(w["state"] for w in before["work"]) == ["COMPLETED", "PENDING"], observations["pending_setup"]
        if logical_restore:
            qualify_logical_restore(state_query, before)
            return
        if clean_clone or direct_clone:
            qualify_clean_clone(state_query, before)
            return
        qualify_recovery(state_query, pending=True)
        observations["entry_decision"] = "FOCUSED_PENDING_RECOVERY_QUALIFIED"

    def qualify_logical_restore(state_query, before):
        observations["logical_restore"] = {}
        expected_retention_triggers = [
            {"name": name, "enabled": "O"} for name in (
                "intent_bindings_no_truncate", "intent_bindings_retained",
                "intent_case_identities_no_truncate", "intent_case_identities_retained",
                "pgreact_mdm_cases_no_truncate", "pgreact_mdm_cases_retention",
                "pgreact_mdm_receipts_no_truncate", "pgreact_mdm_receipts_retention")]
        expected_retention_ddl_guard = [
            {"name": "pgre_mdm_history_guard_ddl", "enabled": "O"}]
        expected_guard_function_owner = {
            "owner": "mdm_retention_guard_owner", "can_login": False,
            "superuser": False, "has_direct_schema_create_or_ownership": False,
            "has_role_memberships": False,
            "marker_function_owner": "mdm_retention_guard_owner"}

        def retention_triggers(database):
            query = ("SELECT COALESCE(jsonb_agg(jsonb_build_object('name',t.tgname,'enabled',t.tgenabled) "
                "ORDER BY t.tgname),'[]') FROM pg_catalog.pg_trigger t "
                "WHERE t.tgrelid IN ('mdm_steward.policy_cases_v1'::regclass, "
                "'mdm_steward.policy_receipts_v1'::regclass, "
                "'pgreact_mdm.policy_intent_bindings'::regclass, "
                "'pgreact_mdm.intent_case_identities'::regclass) AND NOT t.tgisinternal "
                "AND t.tgname IN ('intent_bindings_no_truncate','intent_bindings_retained', "
                "'intent_case_identities_no_truncate','intent_case_identities_retained', "
                "'pgreact_mdm_cases_no_truncate','pgreact_mdm_cases_retention', "
                "'pgreact_mdm_receipts_no_truncate','pgreact_mdm_receipts_retention')")
            return json.loads(sql(query, database))

        def retention_ddl_guard(database):
            query = ("SELECT COALESCE(jsonb_agg(jsonb_build_object('name',evtname,'enabled',evtenabled) "
                "ORDER BY evtname),'[]') FROM pg_catalog.pg_event_trigger "
                "WHERE evtname='pgre_mdm_history_guard_ddl'")
            return json.loads(sql(query, database))

        def retention_guard_function_owner(database, port=5432):
            query = ("SELECT jsonb_build_object('owner',owner_row.rolname,"
                "'can_login',owner_row.rolcanlogin,'superuser',owner_row.rolsuper,"
                "'has_direct_schema_create_or_ownership',EXISTS (SELECT 1 FROM pg_catalog.pg_namespace schema_row "
                "WHERE schema_row.nspowner=owner_row.oid OR EXISTS (SELECT 1 FROM pg_catalog.aclexplode(COALESCE("
                "schema_row.nspacl,pg_catalog.acldefault('n',schema_row.nspowner))) schema_acl "
                "WHERE schema_acl.grantee=owner_row.oid AND schema_acl.privilege_type='CREATE')),"
                "'has_role_memberships',EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members membership_row "
                "WHERE membership_row.roleid=owner_row.oid OR membership_row.member=owner_row.oid),"
                "'marker_function_owner',(SELECT marker_owner.rolname "
                "FROM pg_catalog.pg_proc marker_function JOIN pg_catalog.pg_roles marker_owner "
                "ON marker_owner.oid=marker_function.proowner "
                "WHERE marker_function.oid='pgreact_mdm.guard_intent_retention_markers()'::regprocedure)) "
                "FROM pg_catalog.pg_proc function_row "
                "JOIN pg_catalog.pg_roles owner_row ON owner_row.oid=function_row.proowner "
                "WHERE function_row.oid='pgreact_mdm.enforce_history_guard_ddl()'::regprocedure")
            return json.loads(sql(query, database, port))

        def reinstall_mdm_adapter(database, log_name):
            before = json.loads(sql(state_query, database))
            triggers_before = retention_triggers(database)
            ddl_guard_before = retention_ddl_guard(database)
            guard_owner_before = retention_guard_function_owner(database)
            assert guard_owner_before == expected_guard_function_owner, guard_owner_before
            sql("DROP EVENT TRIGGER IF EXISTS pgre_mdm_history_guard_ddl", database)
            helper_config = command("docker", "exec", container, "psql", "-XAtq", "-U", "postgres",
                "-d", database, "-v", "ON_ERROR_STOP=1", "-v", "helper_owner=mdm_helper_owner",
                "-f", "/workspace/tests/integrations/pg-mdm/pg-mdm-configure-helper.sql")
            install_output = fixture(log_name,
                "/work/integrations/pg-mdm/sql/restore-adapter.sql", database)
            assert install_output == "PASS: MDM adapter SQL reapplied after restore\n", install_output
            after = json.loads(sql(state_query, database))
            assert after == before, {
                "error": "reapplying adapter SQL changed restored durable state",
                "changed_fields": [key for key in before if before[key] != after[key]]}
            triggers_after = retention_triggers(database)
            assert triggers_after == expected_retention_triggers, {
                "before": triggers_before, "after": triggers_after,
                "expected": expected_retention_triggers}
            ddl_guard_after = retention_ddl_guard(database)
            assert ddl_guard_after == expected_retention_ddl_guard, {
                "before": ddl_guard_before, "after": ddl_guard_after,
                "expected": expected_retention_ddl_guard}
            guard_owner_after = retention_guard_function_owner(database)
            assert guard_owner_after == expected_guard_function_owner, guard_owner_after
            sql_hashes = command("docker", "exec", container, "sha256sum",
                "/work/integrations/pg-mdm/sql/restore-adapter.sql",
                "/work/integrations/pg-mdm/sql/request-store.sql",
                "/work/integrations/pg-mdm/sql/intent-worker.sql",
                "/work/integrations/pg-mdm/sql/retention-guard-role.sql",
                "/work/integrations/pg-mdm/sql/retention-guard.sql").splitlines()
            return {"triggers_before_reinstall": triggers_before,
                "triggers_after_reinstall": triggers_after,
                "ddl_guard_before_reinstall": ddl_guard_before,
                "ddl_guard_after_reinstall": ddl_guard_after,
                "guard_function_owner_before_reinstall": guard_owner_before,
                "guard_function_owner_after_reinstall": guard_owner_after,
                "durable_state_preserved": True, "helper_config": helper_config,
                "sql_sha256": sql_hashes}

        config_query = ("SELECT COALESCE(jsonb_agg(c.oid::regclass::text ORDER BY c.oid::regclass::text),'[]') "
                        "FROM pg_extension e CROSS JOIN LATERAL unnest(e.extconfig) object_oid "
                        "JOIN pg_class c ON c.oid=object_oid WHERE e.extname='pg_react'")
        observations["react_dump_config"] = json.loads(sql(config_query))
        expected_config = [
            "pgreact_internal.activation_state", "pgreact_internal.agenda",
            "pgreact_internal.agenda_episode_id_seq", "pgreact_internal.agenda_group_limits",
            "pgreact_internal.clock_history",
            "pgreact_internal.clock_history_clock_event_id_seq", "pgreact_internal.consequence_bindings",
            "pgreact_internal.deadline_lifecycle", "pgreact_internal.deadline_rules",
            "pgreact_internal.executions", "pgreact_internal.executions_execution_id_seq",
            "pgreact_internal.lifecycle_events", "pgreact_internal.lifecycle_events_event_id_seq",
            "pgreact_internal.metadata_rebuild_audits",
            "pgreact_internal.metadata_rebuild_audits_metadata_rebuild_id_seq",
            "pgreact_internal.operational_settings_snapshot",
            "pgreact_internal.rule_barriers", "pgreact_internal.rules",
            "pgreact_internal.rule_versions", "pgreact_internal.temporal_history",
            "pgreact_internal.temporal_history_temporal_event_id_seq",
            "pgreact_internal.temporal_rules", "pgreact_internal.temporal_state"]
        assert observations["react_dump_config"] == expected_config, observations["react_dump_config"]
        observations["checks"].append({"name": "logical-restore-dump-config", "result": "passed"})
        print("PASS: logical-restore extension dump configuration", flush=True)
        active_temporal_state_query = (
            "SELECT jsonb_build_object('semantic_key', temporal.semantic_key, "
            "'rule_state', version.state, 'primitive', spec.primitive, "
            "'state', temporal.state, 'active', temporal.active, "
            "'input_true', temporal.input_true, 'recovery_true', temporal.recovery_true, "
            "'generation', temporal.generation, 'pending_deadline', temporal.pending_deadline) "
            "FROM pgreact_internal.rules rule "
            "JOIN pgreact_internal.rule_versions version USING (rule_id) "
            "JOIN pgreact_internal.temporal_rules spec USING (rule_version_id) "
            "JOIN pgreact_internal.temporal_state temporal USING (rule_version_id) "
            "WHERE rule.rule_name='s1-logical-restore-active-temporal' "
            "AND temporal.semantic_key=9002")
        active_temporal_before = json.loads(sql(active_temporal_state_query))
        expected_active_temporal = {
            "semantic_key": 9002, "rule_state": "ACTIVE", "primitive": "HYSTERESIS",
            "state": "ACTIVE", "active": True, "input_true": True,
            "recovery_true": False, "generation": 1, "pending_deadline": None}
        assert active_temporal_before == expected_active_temporal, active_temporal_before
        observations["checks"].append({
            "name": "logical-restore-active-temporal-state-seeded", "result": "passed"})
        active_duration_state_query = (
            "SELECT jsonb_build_object('semantic_key', temporal.semantic_key, "
            "'rule_state', version.state, 'primitive', spec.primitive, "
            "'state', temporal.state, 'active', temporal.active, "
            "'input_true', temporal.input_true, 'recovery_true', temporal.recovery_true, "
            "'generation', temporal.generation, 'continuous_since', temporal.continuous_since, "
            "'pending_deadline', temporal.pending_deadline) "
            "FROM pgreact_internal.rules rule "
            "JOIN pgreact_internal.rule_versions version USING (rule_id) "
            "JOIN pgreact_internal.temporal_rules spec USING (rule_version_id) "
            "JOIN pgreact_internal.temporal_state temporal USING (rule_version_id) "
            "WHERE rule.rule_name='s1-logical-restore-active-duration' "
            "AND temporal.semantic_key=9101")
        active_duration_before = json.loads(sql(active_duration_state_query))
        assert {key: active_duration_before[key] for key in (
            "semantic_key", "rule_state", "primitive", "state", "active", "input_true",
            "recovery_true", "generation")} == {
                "semantic_key": 9101, "rule_state": "ACTIVE", "primitive": "DURATION",
                "state": "PENDING", "active": False, "input_true": True,
                "recovery_true": False, "generation": 0}, active_duration_before
        assert sql("SELECT temporal.pending_deadline = temporal.continuous_since + interval '1 hour' "
                   "FROM pgreact_internal.temporal_state temporal "
                   "JOIN pgreact_internal.rule_versions version USING (rule_version_id) "
                   "JOIN pgreact_internal.rules rule USING (rule_id) "
                   "WHERE rule.rule_name='s1-logical-restore-active-duration' "
                   "AND temporal.semantic_key=9101") == "t", active_duration_before
        observations["logical_restore"]["active_duration_before_dump"] = active_duration_before
        observations["checks"].append({
            "name": "logical-restore-active-duration-state-seeded", "result": "passed"})
        delta_stream_name = "public.logical_restore_delta_st"
        delta_consumer_id = None
        delta_stream_pgt_id = None
        delta_fixture_query = None
        delta_pending_token = None
        delta_first_token = None
        delta_fixture_before = None

        def assert_recovered_state_preserved(before_state, recovered_state, temporal_results):
            temporal_ids = {row["rule_version_id"] for row in temporal_results}
            prior_history = before_state["temporal_history"]
            restored_history = recovered_state["temporal_history"]
            assert restored_history[:len(prior_history)] == prior_history, \
                "temporal recovery rewrote existing history"
            new_events = restored_history[len(prior_history):]
            temporal_states = {
                (state["rule_version_id"], state["semantic_key"]): state
                for state in before_state["temporal_state"]
                if state["rule_version_id"] in temporal_ids
            }
            assert len(new_events) == len(temporal_states), new_events
            for offset, event in enumerate(new_events, start=1):
                state = temporal_states[(event["rule_version_id"], event["semantic_key"])]
                assert event["temporal_event_id"] == \
                    before_state["temporal_history_sequence"] + offset, event
                assert event["event_kind"] == "OBSERVE" and \
                    event["lifecycle_event_id"] is None, event
                assert event["primitive_state"] == state["state"]
                assert event["input_true"] == state["input_true"]
                assert event["recovery_true"] == state["recovery_true"]
                assert event["bindings"] == state["last_bindings"]
                assert event["pending_deadline"] == state["pending_deadline"]
                assert event["continuous_since"] == state["continuous_since"]
                assert event["cooldown_until"] == state["cooldown_until"]
                assert event["clock_frontier"] == state["last_frontier"]

            prior = copy.deepcopy(before_state)
            restored = copy.deepcopy(recovered_state)
            for state_snapshot in (prior, restored):
                state_snapshot.pop("temporal_history")
                state_snapshot.pop("temporal_history_sequence")
                for state in state_snapshot["temporal_state"]:
                    if state["rule_version_id"] in temporal_ids:
                        state.pop("updated_at", None)
            assert restored == prior, {
                "error": "logical recovery changed durable state",
                "changed_fields": [key for key in prior if prior[key] != restored.get(key)]}
            return new_events

        if not logical_restore_react_only:
            sql("CREATE TABLE public.logical_restore_delta_source "
                "(id integer PRIMARY KEY, val text)")
            sql("INSERT INTO public.logical_restore_delta_source VALUES (1, 'one'), (2, 'two')")
            sql("SELECT pgtrickle.create_stream_table("
                "name => 'logical_restore_delta_st', "
                "query => 'SELECT id, val FROM public.logical_restore_delta_source', "
                "schedule => '1m', refresh_mode => 'DIFFERENTIAL', initialize => false, "
                "orchestration_mode => 'EXTERNAL')")
            delta_refresh = (
                "SELECT * FROM pgtrickle.refresh_graph_strict("
                "ARRAY['public.logical_restore_delta_st'::regclass], "
                "(SELECT graph_digest FROM pgtrickle.graph_contract("
                "ARRAY['public.logical_restore_delta_st'::regclass])), 'ALLOW')")
            sql(delta_refresh)
            delta_stream_pgt_id = int(sql(
                "SELECT pgt_id FROM pgtrickle.pgt_stream_tables "
                "WHERE pgt_relid='public.logical_restore_delta_st'::regclass"))
            delta_consumer_id = str(uuid.UUID(sql(
                "SELECT consumer_id::text FROM pgtrickle.register_output_delta_consumer("
                "'public.logical_restore_delta_st'::regclass, 'logical-restore-cursor', "
                "(SELECT contract_digest FROM pgtrickle.stream_table_contract("
                "'public.logical_restore_delta_st'::regclass)), 'RESNAPSHOT_REQUIRED')")))
            baseline = json.loads(sql(
                "SELECT row_to_json(snapshot)::text "
                "FROM pgtrickle.begin_output_delta_resnapshot('" + delta_consumer_id + "'::uuid) snapshot"))
            assert baseline["log_head"] == 0, baseline
            baseline_token = str(uuid.UUID(baseline["resnapshot_token"]))
            baseline_state = sql(
                "SELECT pgtrickle.ack_output_delta_resnapshot('" + delta_consumer_id + "'::uuid, '" +
                baseline_token + "'::uuid)")
            assert baseline_state == "ACTIVE", baseline_state
            sql("INSERT INTO public.logical_restore_delta_source VALUES (3, 'three')")
            sql(delta_refresh)
            delta_first_token = int(sql(
                "SELECT l.log_head FROM pgtrickle.pgt_output_delta_logs l "
                "WHERE l.pgt_id=" + str(delta_stream_pgt_id)))
            assert delta_first_token == baseline["log_head"] + 1, delta_first_token
            first_ack = sql(
                "SELECT pgtrickle.ack_output_delta('" + delta_consumer_id + "'::uuid, " +
                str(delta_first_token) + ", 'APPLIED')")
            assert first_ack == "APPLIED", first_ack
            sql("INSERT INTO public.logical_restore_delta_source VALUES (4, 'four')")
            sql(delta_refresh)
            delta_pending_token = int(sql(
                "SELECT l.log_head FROM pgtrickle.pgt_output_delta_logs l "
                "WHERE l.pgt_id=" + str(delta_stream_pgt_id)))
            assert delta_pending_token == delta_first_token + 1, delta_pending_token
            delta_payload_relation = "pgtrickle_changes.output_delta_" + str(delta_stream_pgt_id)
            delta_fixture_query = (
                "SELECT jsonb_build_object("
                "'log',(SELECT to_jsonb(l) FROM pgtrickle.pgt_output_delta_logs l "
                "WHERE l.pgt_id=" + str(delta_stream_pgt_id) + "),"
                "'consumer',(SELECT to_jsonb(c) FROM pgtrickle.pgt_output_delta_consumers c "
                "WHERE c.consumer_id='" + delta_consumer_id + "'::uuid),"
                "'batches',(SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY b.batch_token),'[]') "
                "FROM pgtrickle.pgt_output_delta_batches b WHERE b.pgt_id=" +
                str(delta_stream_pgt_id) + "),"
                "'pending_payload',(SELECT COALESCE(jsonb_agg(jsonb_build_array("
                "p.batch_token,p.action,p.id,p.val,p.ordinal) ORDER BY p.ordinal),'[]') "
                "FROM " + delta_payload_relation + " p WHERE p.batch_token=" +
                str(delta_pending_token) + "))")
            delta_fixture_before = json.loads(sql(delta_fixture_query))
            assert delta_fixture_before["log"]["log_head"] == delta_pending_token, delta_fixture_before
            assert delta_fixture_before["consumer"]["state"] == "ACTIVE", delta_fixture_before
            assert delta_fixture_before["consumer"]["acknowledged_batch_token"] == delta_first_token, \
                delta_fixture_before
            assert [int(batch["batch_token"]) for batch in delta_fixture_before["batches"]] == [
                delta_pending_token], delta_fixture_before
            pending_batch = delta_fixture_before["batches"][-1]
            assert (pending_batch["mode"], pending_batch["row_count"]) == ("EXACT", 1), pending_batch
            assert delta_fixture_before["pending_payload"] == [[
                delta_pending_token, "INSERT", 4, "four", 0]], delta_fixture_before
            observations["logical_restore"]["output_delta_fixture"] = {
                "stream": delta_stream_name, "pgt_id": delta_stream_pgt_id,
                "consumer_id": delta_consumer_id, "baseline_head": baseline["log_head"],
                "acknowledged_batch_token": delta_first_token,
                "pending_batch_token": delta_pending_token,
                "pending_batch": pending_batch,
                "pending_payload": delta_fixture_before["pending_payload"]}
            observations["checks"].append({
                "name": "logical-restore-output-delta-fixture-seeded", "result": "passed"})
            print("PASS: logical-restore seeded an acknowledged cursor and pending output batch", flush=True)
        stream_definitions_query = (
            "WITH RECURSIVE edges AS ("
            "SELECT d.pgt_id AS downstream_id, upstream.pgt_id AS upstream_id "
            "FROM pgtrickle.pgt_dependencies d "
            "JOIN pgtrickle.pgt_stream_tables upstream ON upstream.pgt_relid = d.source_relid "
            "WHERE d.source_type = 'STREAM_TABLE'), "
            "walk(pgt_id, depth) AS ("
            "SELECT st.pgt_id, 0 FROM pgtrickle.pgt_stream_tables st "
            "WHERE NOT EXISTS (SELECT 1 FROM edges e WHERE e.downstream_id = st.pgt_id) "
            "UNION ALL SELECT e.downstream_id, w.depth + 1 FROM walk w "
            "JOIN edges e ON e.upstream_id = w.pgt_id), "
            "ordered AS (SELECT pgt_id, max(depth) AS depth FROM walk GROUP BY pgt_id) "
            "SELECT COALESCE(jsonb_agg(jsonb_build_object("
            "'pgt_id', st.pgt_id, 'name', format('%I.%I', st.pgt_schema, st.pgt_name), "
            "'depth', ordered.depth, 'orchestration_mode', st.orchestration_mode, "
            "'owner_name', pg_get_userbyid(c.relowner), "
            "'mdm_runtime_maintain', has_table_privilege('mdm_s1_runtime', st.pgt_relid, 'MAINTAIN'), "
            "'worker_maintain', has_table_privilege('pgreact_mdm_worker', st.pgt_relid, 'MAINTAIN'), "
            "'ddl', pgtrickle.export_definition(format('%I.%I', st.pgt_schema, st.pgt_name))) "
            "ORDER BY ordered.depth, st.pgt_id), '[]') "
            "FROM ordered JOIN pgtrickle.pgt_stream_tables st USING (pgt_id) "
            "JOIN pg_catalog.pg_class c ON c.oid = st.pgt_relid")
        stream_definitions = json.loads(sql(stream_definitions_query))
        stream_table_count = int(sql("SELECT count(*) FROM pgtrickle.pgt_stream_tables"))
        assert len(stream_definitions) == stream_table_count > 0, stream_definitions
        assert all(item["ddl"].startswith("DROP STREAM TABLE IF EXISTS ")
                   for item in stream_definitions), stream_definitions
        definitions_path = output / "logical-restore-stream-definitions.json"
        definitions_path.write_text(json.dumps(stream_definitions, indent=2) + "\n")
        observations["logical_restore_stream_export"] = {
            "count": stream_table_count,
            "dependency_order": [{key: item[key] for key in ("pgt_id", "name", "depth")}
                                 for item in stream_definitions],
            "definition_file": definitions_path.name,
            "sha256": hashlib.sha256(definitions_path.read_bytes()).hexdigest(),
            "saved_before_dump": True,
        }
        capture_state_query = (
            "SELECT jsonb_build_object("
            "'capture_instance',(SELECT to_jsonb(i) FROM pgtrickle.pgt_capture_instance i WHERE singleton),"
            "'output_delta_logs',(SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY pgt_id),'[]') "
            "FROM pgtrickle.pgt_output_delta_logs l),"
            "'output_delta_stream_relations',(SELECT COALESCE(jsonb_agg(jsonb_build_object("
            "'pgt_id',st.pgt_id,'schema',st.pgt_schema,'name',st.pgt_name,"
            "'stored_oid',st.pgt_relid,'named_oid',"
            "to_regclass(format('%I.%I',st.pgt_schema,st.pgt_name))::oid,"
            "'stored_delta_oid',l.delta_relid,'named_delta_oid',"
            "to_regclass(format('%I.%I','pgtrickle_changes','output_delta_'||st.pgt_id::text))::oid) "
            "ORDER BY st.pgt_id),'[]') "
            "FROM pgtrickle.pgt_output_delta_logs l "
            "JOIN pgtrickle.pgt_stream_tables st USING (pgt_id)),"
            "'output_delta_batches',(SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY pgt_id,batch_token),'[]') "
            "FROM pgtrickle.pgt_output_delta_batches b),"
            "'output_delta_consumers',(SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY consumer_id),'[]') "
            "FROM pgtrickle.pgt_output_delta_consumers c))")
        capture_state_source = json.loads(sql(capture_state_query))
        if delta_fixture_before is not None:
            assert any(int(stream["pgt_id"]) == delta_stream_pgt_id
                       for stream in capture_state_source["output_delta_stream_relations"]), capture_state_source
        command("docker", "exec", container, "pg_dump", "-Fc", "-U", "postgres", "-d", "s1_idle",
                "-f", "/tmp/s1-logical.dump")
        if logical_restore_react_only:
            command("docker", "exec", container, "createdb", "-U", "postgres", "s1_logical")
        else:
            source_guard_owner = retention_guard_function_owner("s1_idle")
            assert source_guard_owner == expected_guard_function_owner, source_guard_owner
            target_data = "/tmp/pgreact-logical-target-" + container
            command("docker", "exec", "-u", "postgres", container, "pg_basebackup",
                    "-h", "127.0.0.1", "-p", "5432", "-U", "postgres", "-D", target_data,
                    "-X", "stream", "-c", "fast")
            command("docker", "exec", "-u", "postgres", container, "pg_ctl", "-D", target_data,
                    "-o", "-p 5433 -c listen_addresses=127.0.0.1 "
                    "-c shared_preload_libraries=pg_trickle,pg_mdm,pg_react "
                    "-c pg_trickle.enabled=off -c pg_trickle.cdc_mode=trigger "
                    "-c pg_trickle.differential_max_change_ratio=1.0", "-w", "start")
            sql("ALTER FUNCTION pgreact_mdm.enforce_history_guard_ddl() OWNER TO postgres; "
                "ALTER FUNCTION pgreact_mdm.guard_intent_retention_markers() OWNER TO postgres; "
                "REVOKE USAGE ON SCHEMA mdm_steward, pgreact_mdm FROM mdm_retention_guard_owner",
                "s1_idle", 5433)
            sql("DROP ROLE mdm_retention_guard_owner", "postgres", 5433)
            assert sql("SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_roles "
                       "WHERE rolname='mdm_retention_guard_owner')", "postgres", 5433) == "f"
            command("docker", "exec", container, "createdb", "-p", "5433", "-U", "postgres",
                    "s1_logical_preflight")
            try:
                command("docker", "exec", container, "pg_restore", "--exit-on-error", "-U", "postgres",
                        "-p", "5433", "-d", "s1_logical_preflight", "/tmp/s1-logical.dump")
            except RuntimeError as error:
                missing_owner_restore_error = str(error)
                assert 'role "mdm_retention_guard_owner" does not exist' in missing_owner_restore_error, \
                    missing_owner_restore_error
                (output / "logical-restore-missing-guard-owner.log").write_text(
                    missing_owner_restore_error)
            else:
                raise AssertionError(
                    "owner-preserving cross-cluster restore succeeded without the guard-owner role")

            sql("SELECT pg_terminate_backend(pid) FROM pg_catalog.pg_stat_activity "
                "WHERE datname='s1_logical_preflight' AND pid <> pg_backend_pid()", "postgres", 5433)
            command("docker", "exec", container, "dropdb", "-p", "5433", "-U", "postgres",
                    "s1_logical_preflight")
            command("docker", "exec", container, "createdb", "-p", "5433", "-U", "postgres",
                    "s1_logical_preflight")
            role_bootstrap_output = command(
                "docker", "exec", container, "psql", "-XAtq", "-p", "5433", "-U", "postgres",
                "-d", "postgres",
                "-v", "ON_ERROR_STOP=1", "-f",
                "/work/integrations/pg-mdm/sql/retention-guard-role.sql").strip()
            assert role_bootstrap_output == "", role_bootstrap_output
            guard_owner_role = json.loads(sql(
                "SELECT jsonb_build_object('role',rolname,'can_login',rolcanlogin,"
                "'superuser',rolsuper,'createdb',rolcreatedb,'createrole',rolcreaterole,"
                "'inherit',rolinherit,'replication',rolreplication,'bypass_rls',rolbypassrls,"
                "'has_role_memberships',EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members "
                "WHERE roleid=guard_owner.oid OR member=guard_owner.oid),"
                "'has_direct_schema_create_or_ownership',EXISTS (SELECT 1 FROM pg_catalog.pg_namespace schema_row "
                "WHERE schema_row.nspowner=guard_owner.oid OR EXISTS (SELECT 1 FROM pg_catalog.aclexplode(COALESCE("
                "schema_row.nspacl,pg_catalog.acldefault('n',schema_row.nspowner))) schema_acl "
                "WHERE schema_acl.grantee=guard_owner.oid AND schema_acl.privilege_type='CREATE'))) "
                "FROM pg_catalog.pg_roles guard_owner "
                "WHERE rolname='mdm_retention_guard_owner'", "postgres", 5433))
            expected_guard_owner_role = {
                "role": "mdm_retention_guard_owner", "can_login": False,
                "superuser": False, "createdb": False, "createrole": False,
                "inherit": False, "replication": False, "bypass_rls": False,
                "has_role_memberships": False, "has_direct_schema_create_or_ownership": False}

            assert guard_owner_role == expected_guard_owner_role, guard_owner_role

            preflight_restore_output = command(
                "docker", "exec", container, "pg_restore", "--exit-on-error", "-U", "postgres",
                "-p", "5433", "-d", "s1_logical_preflight", "/tmp/s1-logical.dump")
            (output / "logical-restore-preflight.log").write_text(preflight_restore_output)
            target_guard_owner = retention_guard_function_owner("s1_logical_preflight", 5433)
            assert target_guard_owner == expected_guard_function_owner, target_guard_owner
            target_state_after_restore = json.loads(sql(state_query, "s1_logical_preflight", 5433))
            (output / "cross-cluster-state-before.json").write_text(json.dumps(before, indent=2) + "\n")
            (output / "cross-cluster-state-after.json").write_text(
                json.dumps(target_state_after_restore, indent=2) + "\n")
            target_transient_fields = sorted(
                key for key in before if before[key] != target_state_after_restore.get(key))
            expected_target_transient_fields = [
                "application_roles", "bindings", "clock_frontier", "operational_settings",
                "rule_versions"]
            assert target_transient_fields == expected_target_transient_fields, {
                "error": "cross-cluster restore changed data outside the recovery rebuild set",
                "changed_fields": target_transient_fields}
            target_active_temporal_after = json.loads(
                sql(active_temporal_state_query, "s1_logical_preflight", 5433))
            assert target_active_temporal_after == active_temporal_before, target_active_temporal_after

            sql("SELECT pgreact_api.configure_roles('mdm_s1_runner','s1_operator',"
                "'pgreact_mdm_worker','s1_reader','s1_advanced_reader')",
                "s1_logical_preflight", 5433)
            target_prepared_barriers = int(sql(
                "SELECT pgreact.prepare_recovery()", "s1_logical_preflight", 5433))
            target_rebuilt = json.loads(sql(
                "SELECT row_to_json(r) FROM pgreact.rebuild_transient_metadata() r",
                "s1_logical_preflight", 5433))
            expected_target_rebuilt = sum(
                version["state"] != "REMOVED" for version in before["rule_versions"])
            assert target_rebuilt == {
                "rebuilt_rules": expected_target_rebuilt, "blocked_rules": 0}, target_rebuilt
            target_reconciled = json.loads(sql(
                "SELECT COALESCE(jsonb_agg(jsonb_build_object("
                "'rule_version_id',rule_version_id,'rows_repaired',"
                "pgreact.reconcile_rule(rule_version_id,'STATE_ONLY')) ORDER BY rule_version_id),'[]') "
                "FROM pgreact_internal.rule_barriers WHERE reason='RECONCILING'",
                "s1_logical_preflight", 5433))
            expected_target_reconciled = [
                {"rule_version_id": version["rule_version_id"], "rows_repaired": 0}
                for version in sorted(before["rule_versions"],
                                      key=lambda value: value["rule_version_id"])
                if version["state"] in ("ACTIVE", "DRAINING", "PAUSED")]
            assert target_reconciled == expected_target_reconciled, target_reconciled
            assert sql("SELECT count(*) FROM pgreact_internal.rule_barriers",
                       "s1_logical_preflight", 5433) == "0"
            target_recovered_state = json.loads(
                sql(state_query, "s1_logical_preflight", 5433))
            (output / "cross-cluster-state-after-recovery.json").write_text(
                json.dumps(target_recovered_state, indent=2) + "\n")
            target_temporal_ids = {
                spec["rule_version_id"] for spec in before["temporal_rules"]}
            target_temporal_reconciled = [
                row for row in target_reconciled
                if row["rule_version_id"] in target_temporal_ids]
            target_temporal_observations = assert_recovered_state_preserved(
                before, target_recovered_state, target_temporal_reconciled)
            assert sql("SELECT pgreact_mdm.policy_runtime_ready()",
                       "s1_logical_preflight", 5433) == "f"
            target_pending_jobs = int(sql(
                "SELECT count(*) FROM pgreact_internal.agenda "
                "WHERE state IN ('PENDING','LEASED','RETRY_WAIT')",
                "s1_logical_preflight", 5433))
            target_blocked_cycle = json.loads(sql(
                "SET SESSION AUTHORIZATION mdm_s1_runtime; "
                "SELECT pgreact_api.managed_cycle()",
                "s1_logical_preflight", 5433))
            assert target_blocked_cycle == {
                "state": "blocked", "pending_jobs": target_pending_jobs,
                "processed_jobs": 0, "reason": "MDM activation required"}, target_blocked_cycle
            assert json.loads(sql(state_query, "s1_logical_preflight", 5433)) == \
                target_recovered_state
            command("docker", "exec", "-u", "postgres", container, "pg_ctl", "-D", target_data,
                    "-m", "fast", "-w", "stop")
            assert sql("SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_database "
                       "WHERE datname='s1_logical')", "postgres", 5432) == "f"
            sql("CREATE DATABASE s1_logical", "postgres", 5432)
            assert sql("SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_database "
                       "WHERE datname='s1_logical')", "postgres", 5432) == "t"

        try:
            result = command("docker", "exec", container, "pg_restore", "--exit-on-error", "-p", "5432",
                             "-U", "postgres", "-d", "s1_logical", "/tmp/s1-logical.dump")
        except RuntimeError as error:
            (output / "logical-restore.log").write_text(str(error))
            observations["checks"].append({"name": "logical-restore", "result": "failed"})
            raise
        (output / "logical-restore.log").write_text(result)
        if not logical_restore_react_only:
            observations["logical_restore"]["guard_owner_pre_restore"] = {
                "source_owner_before_dump": source_guard_owner,
                "missing_role_restore_rejected": True,
                "preprovisioned_role": guard_owner_role,
                "target_cluster": True,
                "target_owner_after_restore": target_guard_owner,
                "transient_fields_rebuilt": target_transient_fields,
                "prepare_recovery_barriers": target_prepared_barriers,
                "transient_rebuild": target_rebuilt,
                "barriers_reconciled": target_reconciled,
                "temporal_observations": target_temporal_observations,
                "target_durable_state_preserved": True,
                "target_active_temporal_state_preserved": True,
                "target_blocked_cycle_before_mdm_activation": target_blocked_cycle,
                "owner_preserving_restore_succeeded": True}
            observations["checks"].append({
                "name": "logical-restore-cross-cluster-guard-role-preflight",
                "result": "passed"})
            observations["checks"].append({
                "name": "logical-restore-cross-cluster-durable-state-recovered",
                "result": "passed"})
            observations["checks"].append({
                "name": "logical-restore-cross-cluster-effects-blocked-before-mdm-activation",
                "result": "passed"})
            print("PASS: cross-cluster owner-preserving restore requires guard-role preprovisioning",
                  flush=True)
        after = json.loads(sql(state_query, "s1_logical"))
        active_temporal_after = json.loads(sql(active_temporal_state_query, "s1_logical"))
        assert active_temporal_after == active_temporal_before, active_temporal_after
        observations["logical_restore"].update({"before": before, "after": after,
            "source_database_oid": sql("SELECT oid FROM pg_database WHERE datname=current_database()"),
            "restored_database_oid": sql("SELECT oid FROM pg_database WHERE datname=current_database()", "s1_logical")})
        observations["logical_restore"]["active_temporal_state"] = {
            "before_dump": active_temporal_before, "after_restore": active_temporal_after,
            "preserved_at_restore": True}
        observations["checks"].append({
            "name": "logical-restore-active-temporal-state-preserved", "result": "passed"})
        active_duration_after_restore = json.loads(
            sql(active_duration_state_query, "s1_logical"))
        assert active_duration_after_restore == active_duration_before, active_duration_after_restore
        observations["logical_restore"]["active_duration_state"] = {
            "before_dump": active_duration_before,
            "after_restore": active_duration_after_restore,
            "preserved_at_restore": True}
        observations["checks"].append({
            "name": "logical-restore-active-duration-state-preserved", "result": "passed"})
        stale_temporal_oids = int(sql("SELECT count(*) FROM pgreact_internal.temporal_rules temporal "
            "JOIN pgreact_internal.rule_versions version USING (rule_version_id) "
            "JOIN pgreact_internal.rules rule USING (rule_id) "
            "WHERE rule.rule_name='s1-logical-restore-temporal-probe' "
            "AND temporal.recovery_condition_oid IS DISTINCT FROM "
            "to_regclass(temporal.recovery_condition_name)::oid", "s1_logical"))
        assert stale_temporal_oids == 1, stale_temporal_oids
        observations["logical_restore"]["temporal_recovery_oid_rebind"] = {
            "stale_rows_before_prepare": stale_temporal_oids,
            "scope": "internally seeded REMOVED HYSTERESIS OID probe"}
        stale_active_temporal_oids = int(sql("SELECT count(*) FROM pgreact_internal.temporal_rules temporal "
            "JOIN pgreact_internal.rule_versions version USING (rule_version_id) "
            "JOIN pgreact_internal.rules rule USING (rule_id) "
            "WHERE rule.rule_name='s1-logical-restore-active-temporal' "
            "AND temporal.recovery_condition_oid IS DISTINCT FROM "
            "to_regclass(temporal.recovery_condition_name)::oid", "s1_logical"))
        assert stale_active_temporal_oids == 1, stale_active_temporal_oids
        observations["logical_restore"]["active_temporal_recovery_oid_rebind"] = {
            "stale_rows_before_prepare": stale_active_temporal_oids}
        observations["checks"].append({
            "name": "logical-restore-active-temporal-oid-stale", "result": "passed"})
        history = ("cases", "receipts", "requests", "intent_attempts", "holds", "identities",
                   "identity_sequence", "business", "technical")
        assert {key: after[key] for key in history} == {key: before[key] for key in history}
        adapter_restore = reinstall_mdm_adapter("s1_logical", "logical-restore-adapter-reinstall")
        observations["logical_restore"]["adapter_restore"] = adapter_restore
        observations["checks"].append({
            "name": "logical-restore-mdm-adapter-retention-guards-reinstalled", "result": "passed"})
        assert sql("SELECT NOT pgreact_mdm.policy_runtime_ready()", "s1_logical") == "t"
        fixture("logical-restore-guard", "/work/tests/integrations/pg-mdm/time/recovery.sql",
                "s1_logical", ("-v", "pending=true"))
        pending = int(sql("SELECT count(*) FROM pgreact_internal.agenda "
                          "WHERE state IN ('PENDING','LEASED','RETRY_WAIT')", "s1_logical"))
        cycles = [json.loads(sql("SET SESSION AUTHORIZATION mdm_s1_runtime; "
                                 "SELECT pgreact_api.managed_cycle()", "s1_logical")) for _ in range(2)]
        observations["logical_restore"]["preactivation_cycles"] = cycles
        assert cycles == [{"state": "blocked", "pending_jobs": pending, "processed_jobs": 0,
                           "reason": "MDM activation required"}] * 2, cycles
        assert json.loads(sql(state_query, "s1_logical")) == after
        observations["checks"].append({"name": "logical-restore-blocked-cycles", "result": "passed"})
        assert sql("SELECT NOT EXISTS (SELECT 1 FROM pgreact_mdm.authorized_policy_cases_v1)", "s1_logical") == "t"
        observations["checks"].append({"name": "logical-restore-preactivation", "result": "passed"})

        sql("SELECT pgreact_api.configure_roles('mdm_s1_runner','s1_operator',"
            "'pgreact_mdm_worker','s1_reader','s1_advanced_reader')", "s1_logical")
        observations["logical_restore"]["react_role_rebind"] = {"result": "passed"}
        observations["checks"].append({"name": "logical-restore-application-role-rebind", "result": "passed"})

        sql("UPDATE pgreact_internal.rules r SET owner_oid = ("
            "SELECT p.oid FROM pg_catalog.pg_roles p WHERE p.rolname <> r.owner_name ORDER BY p.rolname LIMIT 1); "
            "UPDATE pgreact_internal.rule_versions v SET owner_oid = ("
            "SELECT p.oid FROM pg_catalog.pg_roles p JOIN pgreact_internal.rules r ON r.rule_id=v.rule_id "
            "WHERE r.rule_id=v.rule_id AND p.rolname <> r.owner_name ORDER BY p.rolname LIMIT 1)",
            "s1_logical")
        stale_owner_oids = int(sql("SELECT (SELECT count(*) FROM pgreact_internal.rules "
            "WHERE pg_get_userbyid(owner_oid) IS DISTINCT FROM owner_name) + "
            "(SELECT count(*) FROM pgreact_internal.rule_versions v "
            "JOIN pgreact_internal.rules r USING (rule_id) "
            "WHERE pg_get_userbyid(v.owner_oid) IS DISTINCT FROM r.owner_name)", "s1_logical"))
        expected_owner_rows = len(before["rules"]) + len(before["rule_versions"])
        assert stale_owner_oids == expected_owner_rows > 0, stale_owner_oids
        observations["logical_restore"]["owner_oid_repair_probe"] = {
            "stale_rows": stale_owner_oids, "repaired_from_stored_role_names": True}
        try:
            command("docker", "exec", container, "psql", "-XAtq", "-U", "postgres", "-d", "s1_logical",
                    "-v", "ON_ERROR_STOP=1", "-c",
                    "BEGIN; UPDATE pgreact_internal.rules SET owner_name='pgreact_missing_restore_role' "
                    "WHERE rule_id=(SELECT rule_id FROM pgreact_internal.rules ORDER BY rule_id LIMIT 1); "
                    "SET SESSION AUTHORIZATION s1_recovery_operator; "
                    "SELECT * FROM pgreact.rebuild_transient_metadata(); COMMIT")
        except RuntimeError as error:
            assert "cannot rebuild transient metadata: a stored rule owner is missing" in str(error), error
        else:
            raise AssertionError("logical restore recovery accepted a missing stored owner")
        assert int(sql("SELECT count(*) FROM pgreact_internal.rules "
            "WHERE owner_name='pgreact_missing_restore_role'", "s1_logical")) == 0
        observations["logical_restore"]["missing_owner_rejected"] = True

        state_before_changed_recovery = json.loads(sql(state_query, "s1_logical"))
        recovery_error = "cannot prepare recovery: a temporal recovery condition is missing or changed"
        try:
            command("docker", "exec", container, "psql", "-XAtq", "-U", "postgres", "-d", "s1_logical",
                    "-v", "ON_ERROR_STOP=1", "-c",
                    "BEGIN; CREATE OR REPLACE VIEW logical_restore_temporal_probe.recovery AS "
                    "SELECT semantic_key FROM logical_restore_temporal_probe.conditions "
                    "WHERE recovery_condition AND semantic_key <> 0; "
                    "SET SESSION AUTHORIZATION s1_recovery_operator; "
                    "SELECT pgreact.prepare_recovery(); COMMIT")
        except RuntimeError as error:
            assert recovery_error in str(error), error
        else:
            raise AssertionError("logical restore accepted a changed temporal recovery view")
        assert json.loads(sql(state_query, "s1_logical")) == state_before_changed_recovery
        assert sql("SELECT temporal.recovery_condition_oid = '0'::oid "
            "FROM pgreact_internal.temporal_rules temporal "
            "JOIN pgreact_internal.rule_versions version USING (rule_version_id) "
            "JOIN pgreact_internal.rules rule USING (rule_id) "
            "WHERE rule.rule_name='s1-logical-restore-temporal-probe'", "s1_logical") == "t"
        assert sql("SELECT pg_get_viewdef(to_regclass(temporal.recovery_condition_name),true) "
            "= temporal.recovery_condition_definition "
            "FROM pgreact_internal.temporal_rules temporal "
            "JOIN pgreact_internal.rule_versions version USING (rule_version_id) "
            "JOIN pgreact_internal.rules rule USING (rule_id) "
            "WHERE rule.rule_name='s1-logical-restore-temporal-probe'", "s1_logical") == "t"
        observations["logical_restore"]["changed_temporal_recovery_source"] = {
            "rejected": True, "error": recovery_error, "state_unchanged": True,
            "stale_oid_unchanged": True, "saved_view_restored": True}
        observations["checks"].append({
            "name": "logical-restore-temporal-source-identity-rejection", "result": "passed"})

        recovery_identity = recovery_sql("SELECT session_user || ':' || current_user")
        assert recovery_identity == "s1_recovery_operator:s1_recovery_operator", recovery_identity
        recovery_acl = sql(
            "SELECT pg_has_role('s1_recovery_operator','pgreact_admin','MEMBER') "
            "AND (SELECT NOT rolsuper FROM pg_catalog.pg_roles "
            "WHERE rolname='s1_recovery_operator') "
            "AND has_schema_privilege('s1_recovery_operator','pgreact','USAGE') "
            "AND has_function_privilege('s1_recovery_operator','pgreact.prepare_recovery()','EXECUTE') "
            "AND has_function_privilege('s1_recovery_operator',"
            "'pgreact.rebuild_transient_metadata()','EXECUTE') "
            "AND NOT has_function_privilege('mdm_s1_runtime',"
            "'pgreact.prepare_recovery()','EXECUTE') "
            "AND NOT has_function_privilege('mdm_s1_runtime',"
            "'pgreact.rebuild_transient_metadata()','EXECUTE')", "s1_logical")
        assert recovery_acl == "t", recovery_acl
        observations["logical_restore"]["recovery_operator"] = {
            "session_identity": recovery_identity, "admin_role_and_acl": recovery_acl,
            "worker_recovery_execute": False}
        observations["checks"].append({
            "name": "logical-restore-restricted-recovery-role", "result": "passed"})
        recovery_sql("SELECT pgreact.prepare_recovery()")
        assert sql("SELECT temporal.recovery_condition_oid = "
            "to_regclass(temporal.recovery_condition_name)::oid "
            "FROM pgreact_internal.temporal_rules temporal "
            "JOIN pgreact_internal.rule_versions version USING (rule_version_id) "
            "JOIN pgreact_internal.rules rule USING (rule_id) "
            "WHERE rule.rule_name='s1-logical-restore-temporal-probe'", "s1_logical") == "t"
        observations["logical_restore"]["temporal_recovery_oid_rebind"]["rebound_after_prepare"] = True
        active_oid_rebound = sql("SELECT temporal.recovery_condition_oid = "
            "to_regclass(temporal.recovery_condition_name)::oid "
            "FROM pgreact_internal.temporal_rules temporal "
            "JOIN pgreact_internal.rule_versions version USING (rule_version_id) "
            "JOIN pgreact_internal.rules rule USING (rule_id) "
            "WHERE rule.rule_name='s1-logical-restore-active-temporal'", "s1_logical")
        assert active_oid_rebound == "t", active_oid_rebound
        observations["logical_restore"]["active_temporal_recovery_oid_rebind"]["rebound_after_prepare"] = True
        observations["checks"].append({
            "name": "logical-restore-active-temporal-oid-rebound", "result": "passed"})
        rebuilt = json.loads(recovery_sql(
            "SELECT row_to_json(r) FROM pgreact.rebuild_transient_metadata() r"))
        expected_rebuilt = sum(version["state"] != "REMOVED" for version in before["rule_versions"])
        assert rebuilt == {"rebuilt_rules": expected_rebuilt, "blocked_rules": 0}, rebuilt
        dispatcher_probe = json.loads(sql(
            "SELECT json_build_object('rule_version_id', binding.rule_version_id::text, "
            "'event_kind', binding.event_kind) "
            "FROM pgreact_internal.consequence_bindings binding "
            "JOIN pgreact_internal.rule_versions version USING (rule_version_id) "
            "WHERE version.state <> 'REMOVED' AND binding.consequence_kind = 'DATABASE_TYPED' "
            "AND binding.dispatcher_identity IS NOT NULL "
            "ORDER BY binding.rule_version_id, binding.event_kind LIMIT 1", "s1_logical"))
        assert dispatcher_probe is not None, "logical restore fixture has no typed dispatcher binding"
        version_selector = "rule_version_id='" + dispatcher_probe["rule_version_id"] + "'::uuid"
        binding_selector = ("rule_version_id='" + dispatcher_probe["rule_version_id"] + "'::uuid "
                            "AND event_kind='" + dispatcher_probe["event_kind"] + "'")
        sql("DELETE FROM pgreact_internal.rule_barriers WHERE " + version_selector, "s1_logical")
        sql("UPDATE pgreact_internal.consequence_bindings "
            "SET dispatcher_identity = replace(dispatcher_identity, '(', '_missing(') "
            "WHERE " + binding_selector, "s1_logical")
        assert sql("SELECT to_regprocedure(dispatcher_identity) IS NULL "
                   "FROM pgreact_internal.consequence_bindings WHERE " + binding_selector,
                   "s1_logical") == "t"
        blocked_rebuild = json.loads(recovery_sql(
            "SELECT row_to_json(r) FROM pgreact.rebuild_transient_metadata() r"))
        assert blocked_rebuild == {"rebuilt_rules": expected_rebuilt - 1, "blocked_rules": 1}, \
            blocked_rebuild
        assert sql("SELECT reason FROM pgreact_internal.rule_barriers WHERE " + version_selector,
                   "s1_logical") == "RECONCILING"
        sql("UPDATE pgreact_internal.consequence_bindings "
            "SET dispatcher_identity = replace(dispatcher_identity, '_missing(', '(') "
            "WHERE " + binding_selector, "s1_logical")
        repaired_rebuild = json.loads(recovery_sql(
            "SELECT row_to_json(r) FROM pgreact.rebuild_transient_metadata() r"))
        assert repaired_rebuild == {"rebuilt_rules": expected_rebuilt, "blocked_rules": 0}, \
            repaired_rebuild
        observations["logical_restore"]["missing_binding_dispatcher"] = {
            "rule_version_id": dispatcher_probe["rule_version_id"],
            "event_kind": dispatcher_probe["event_kind"],
            "unresolved_identity_blocked": blocked_rebuild,
            "barrier_reason": "RECONCILING",
            "resolved_identity_rebuilt": repaired_rebuild}
        observations["checks"].append({
            "name": "logical-restore-missing-binding-dispatcher", "result": "passed"})
        print("PASS: logical-restore missing binding dispatcher was blocked", flush=True)
        reconciled = json.loads(sql("SELECT COALESCE(jsonb_agg(jsonb_build_object("
            "'rule_version_id',rule_version_id,'rows_repaired',"
            "pgreact.reconcile_rule(rule_version_id,'STATE_ONLY')) ORDER BY rule_version_id),'[]') "
            "FROM pgreact_internal.rule_barriers WHERE reason='RECONCILING'", "s1_logical"))
        expected_reconciled = [
            {"rule_version_id": version["rule_version_id"], "rows_repaired": 0}
            for version in sorted(before["rule_versions"], key=lambda value: value["rule_version_id"])
            if version["state"] in ("ACTIVE", "DRAINING", "PAUSED")]
        assert reconciled == expected_reconciled, reconciled
        assert sql("SELECT count(*) FROM pgreact_internal.rule_barriers", "s1_logical") == "0"
        assert sql("SELECT count(*) FROM pgreact.health_check() "
                   "WHERE code='BARRIER' AND severity='ERROR'", "s1_logical") == "0"
        recovered_state = json.loads(sql(state_query, "s1_logical"))
        temporal_ids = {spec["rule_version_id"] for spec in before["temporal_rules"]}
        temporal_reconciled = [
            row for row in reconciled if row["rule_version_id"] in temporal_ids]
        temporal_observations = assert_recovered_state_preserved(
            before, recovered_state, temporal_reconciled)
        observations["logical_restore"]["temporal_recovery"] = {
            "rules_reconciled": temporal_reconciled,
            "appended_observations": temporal_observations}
        active_temporal_after_recovery = json.loads(sql(active_temporal_state_query, "s1_logical"))
        assert active_temporal_after_recovery == active_temporal_before, active_temporal_after_recovery
        observations["logical_restore"]["active_temporal_state"]["after_recovery"] = \
            active_temporal_after_recovery
        observations["logical_restore"]["active_temporal_state"]["preserved_after_recovery"] = True
        observations["checks"].append({
            "name": "logical-restore-active-temporal-state-recovered", "result": "passed"})
        active_duration_after_recovery = json.loads(
            sql(active_duration_state_query, "s1_logical"))
        assert active_duration_after_recovery == active_duration_before, active_duration_after_recovery
        observations["logical_restore"]["active_duration_state"].update({
            "after_recovery": active_duration_after_recovery,
            "preserved_after_recovery": True})
        observations["checks"].append({
            "name": "logical-restore-active-duration-state-recovered", "result": "passed"})
        observations["logical_restore"]["react_recovery"] = rebuilt
        observations["checks"].append({"name": "logical-restore-react-recovery", "result": "passed"})
        print("PASS: logical-restore React recovery preserved complete state", flush=True)
        if logical_restore_react_only:
            observations["entry_decision"] = "FOCUSED_REACT_LOGICAL_RESTORE_REGRESSION"
            return

        capture_state_before = json.loads(sql(capture_state_query, "s1_logical"))
        assert capture_state_before["output_delta_batches"] == capture_state_source["output_delta_batches"], {
            "batches_before_dump": capture_state_source["output_delta_batches"],
            "batches_after_restore": capture_state_before["output_delta_batches"]}
        if delta_fixture_before is not None:
            delta_fixture_after_restore = json.loads(sql(delta_fixture_query, "s1_logical"))
            assert delta_fixture_after_restore["log"]["log_head"] == delta_pending_token, \
                delta_fixture_after_restore
            assert delta_fixture_after_restore["consumer"]["acknowledged_batch_token"] == \
                delta_first_token, delta_fixture_after_restore
            assert delta_fixture_after_restore["consumer"]["state"] == "ACTIVE", \
                delta_fixture_after_restore
            assert delta_fixture_after_restore["batches"] == delta_fixture_before["batches"], \
                delta_fixture_after_restore
            assert delta_fixture_after_restore["pending_payload"] == \
                delta_fixture_before["pending_payload"], delta_fixture_after_restore
            observations["logical_restore"]["output_delta_fixture"]["after_restore_before_adoption"] = {
                "log_head": delta_fixture_after_restore["log"]["log_head"],
                "acknowledged_batch_token": delta_fixture_after_restore["consumer"][
                    "acknowledged_batch_token"],
                "consumer_state": delta_fixture_after_restore["consumer"]["state"],
                "pending_batch": delta_fixture_after_restore["batches"][-1],
                "pending_payload": delta_fixture_after_restore["pending_payload"]}
        capture_database_oid = capture_state_source["capture_instance"]["database_oid"]
        assert capture_database_oid == observations["logical_restore"]["source_database_oid"], capture_state_before
        assert capture_database_oid != observations["logical_restore"]["restored_database_oid"], capture_state_before
        assert any(stream["stored_oid"] != stream["named_oid"]
                   for stream in capture_state_before["output_delta_stream_relations"]), capture_state_before
        try:
            sql("SELECT pgtrickle.recover_capture_instance()", "s1_logical")
        except RuntimeError as error:
            if not all(fragment in str(error) for fragment in (
                    "PGT_EXT_GRAPH_INVALID: could not inspect stream-table relation:",
                    "PGT_EXT_GRAPH_INVALID: relation OID ", " does not exist")):
                raise
            (output / "logical-restore-pgtrickle-capture-recovery.log").write_text(str(error))
            detail = next((line.strip() for line in str(error).splitlines() if "ERROR:" in line),
                          "PGT_EXT_GRAPH_INVALID")
            capture_state_after = json.loads(sql(capture_state_query, "s1_logical"))
            react_state_after = json.loads(sql(state_query, "s1_logical"))
            assert capture_state_after == capture_state_before, {
                "capture_before": capture_state_before, "capture_after": capture_state_after}
            assert react_state_after == recovered_state, \
                "failed capture adoption changed React or MDM state"
            observations["logical_restore"]["capture_recovery"] = {
                "result": "blocked", "reason": "PGT_EXT_GRAPH_INVALID", "detail": detail,
                "failed_recovery_state_unchanged": True,
                "capture_state_before": capture_state_before, "capture_state_after": capture_state_after}
            observations["checks"].append({
                "name": "logical-restore-failed-capture-recovery-no-mutation", "result": "passed"})
            observations["checks"].append({
                "name": "logical-restore-pgtrickle-capture-recovery", "result": "blocked",
                "reason": "PGT_EXT_GRAPH_INVALID"})
            observations["entry_decision"] = "FOCUSED_REACT_LOGICAL_RESTORE_QUALIFIED"
            observations["remaining_gates"] = [
                "pg_trickle capture identity recovery after logical restore",
                "pending React work delivery after MDM reactivation"]
            print("BLOCKED: logical restore requires pg_trickle capture graph repair", flush=True)
            return
        recovery = json.loads(sql("SELECT pgtrickle.validate_recovery()", "s1_logical"))
        assert recovery["status"] in ("SAFE", "REINITIALIZATION_REQUIRED"), recovery
        capture_state_after = json.loads(sql(capture_state_query, "s1_logical"))
        assert capture_state_after["capture_instance"]["database_oid"] == \
            observations["logical_restore"]["restored_database_oid"], capture_state_after
        assert all(item["stored_oid"] == item["named_oid"]
                   for item in capture_state_after["output_delta_stream_relations"]), capture_state_after
        assert all(item["stored_delta_oid"] == item["named_delta_oid"]
                   for item in capture_state_after["output_delta_stream_relations"]), capture_state_after
        assert all(log["database_instance_id"] == capture_state_after["capture_instance"]["instance_id"]
                   for log in capture_state_after["output_delta_logs"]), capture_state_after
        stable_log_fields = ("pgt_id", "log_head", "output_contract_digest",
                             "row_identity_version", "created_at")
        assert [{key: log[key] for key in stable_log_fields}
                for log in capture_state_after["output_delta_logs"]] == [
                    {key: log[key] for key in stable_log_fields}
                    for log in capture_state_before["output_delta_logs"]], {
                        "logs_before": capture_state_before["output_delta_logs"],
                        "logs_after": capture_state_after["output_delta_logs"]}
        assert capture_state_after["output_delta_batches"] == capture_state_before["output_delta_batches"], {
            "batches_before": capture_state_before["output_delta_batches"],
            "batches_after": capture_state_after["output_delta_batches"]}
        stable_consumer_fields = (
            "consumer_id", "pgt_id", "database_instance_id", "owner_oid", "consumer_name",
            "expected_contract_digest", "output_contract_digest", "row_identity_version",
            "acknowledged_batch_token", "acknowledged_at", "created_at")
        consumers_before = capture_state_before["output_delta_consumers"]
        consumers_after = capture_state_after["output_delta_consumers"]
        assert [{key: consumer[key] for key in stable_consumer_fields}
                for consumer in consumers_after] == [
                    {key: consumer[key] for key in stable_consumer_fields}
                    for consumer in consumers_before], {
                        "consumers_before": consumers_before, "consumers_after": consumers_after}
        for before_consumer, after_consumer in zip(consumers_before, consumers_after):
            if before_consumer["state"] == "DROPPED":
                assert (after_consumer["state"], after_consumer["state_reason"]) == (
                    "DROPPED", before_consumer["state_reason"]), after_consumer
            else:
                assert (after_consumer["state"], after_consumer["state_reason"]) == (
                    "INVALIDATED", "DATABASE_INSTANCE_CHANGED"), after_consumer
        if delta_fixture_before is not None:
            delta_fixture_after_adoption = json.loads(sql(delta_fixture_query, "s1_logical"))
            assert delta_fixture_after_adoption["log"]["log_head"] == delta_pending_token, \
                delta_fixture_after_adoption
            assert delta_fixture_after_adoption["batches"] == delta_fixture_before["batches"], \
                delta_fixture_after_adoption
            assert delta_fixture_after_adoption["consumer"]["acknowledged_batch_token"] == \
                delta_first_token, delta_fixture_after_adoption
            assert (delta_fixture_after_adoption["consumer"]["state"],
                    delta_fixture_after_adoption["consumer"]["state_reason"]) == (
                        "INVALIDATED", "DATABASE_INSTANCE_CHANGED"), delta_fixture_after_adoption
            assert delta_fixture_after_adoption["pending_payload"] == \
                delta_fixture_before["pending_payload"], delta_fixture_after_adoption
            public_pending_batches = sql(
                "SELECT count(*) FROM pgtrickle.output_delta_batches('" +
                delta_consumer_id + "'::uuid, NULL)", "s1_logical")
            assert public_pending_batches == "0", public_pending_batches
            observations["logical_restore"]["output_delta_fixture"]["after_adoption"] = {
                "log_head": delta_fixture_after_adoption["log"]["log_head"],
                "acknowledged_batch_token": delta_fixture_after_adoption["consumer"][
                    "acknowledged_batch_token"],
                "consumer_state": delta_fixture_after_adoption["consumer"]["state"],
                "consumer_state_reason": delta_fixture_after_adoption["consumer"]["state_reason"],
                "pending_batch": delta_fixture_after_adoption["batches"][-1],
                "pending_payload": delta_fixture_after_adoption["pending_payload"],
                "public_pending_batch_count": int(public_pending_batches)}
            observations["checks"].append({
                "name": "logical-restore-output-delta-preserved-after-adoption", "result": "passed"})
        assert json.loads(sql(state_query, "s1_logical")) == recovered_state
        adoption_validation = recovery
        recovery_blocked = recovery["status"] != "SAFE"
        reinitialization = None
        if recovery_blocked:
            assert recovery["status"] == "REINITIALIZATION_REQUIRED", recovery
            observations["logical_restore"]["capture_adoption_validation"] = recovery
            drop_names = ",".join("'" + item["name"].replace("'", "''") + "'"
                                   for item in stream_definitions)
            sql("SELECT pgtrickle.bulk_drop_stream_tables(ARRAY[" + drop_names + "])", "s1_logical")
            for item in stream_definitions:
                mode = item["orchestration_mode"]
                assert mode in ("MANAGED", "EXTERNAL"), item
                drop_command, separator, ddl = item["ddl"].partition("\n")
                assert separator and drop_command.startswith("DROP STREAM TABLE IF EXISTS "), item
                closing = "\n);\n"
                assert ddl.endswith(closing), {"name": item["name"], "ddl": ddl[-100:]}
                ddl = (ddl[:-len(closing)] + ",\n  orchestration_mode => '" + mode + "'\n);\n")
                sql(ddl, "s1_logical")
                owner = '"' + item["owner_name"].replace('"', '""') + '"'
                sql("ALTER TABLE " + item["name"] + " OWNER TO " + owner, "s1_logical")
                if item["mdm_runtime_maintain"]:
                    sql("GRANT MAINTAIN ON TABLE " + item["name"] + " TO mdm_s1_runtime", "s1_logical")
                if item["worker_maintain"]:
                    worker_role = "pgreact_mdm_worker"
                    sql("GRANT MAINTAIN ON TABLE " + item["name"] + " TO " + worker_role, "s1_logical")
            sql("SELECT pgtrickle.rebuild_cdc_triggers()", "s1_logical")
            recreated_streams = json.loads(sql(
                "SELECT COALESCE(jsonb_agg(jsonb_build_object("
                "'name',format('%I.%I',st.pgt_schema,st.pgt_name),"
                "'owner_name',pg_get_userbyid(c.relowner),"
                "'orchestration_mode',st.orchestration_mode,"
                "'mdm_runtime_maintain',has_table_privilege('mdm_s1_runtime',st.pgt_relid,'MAINTAIN'),"
                "'worker_maintain',has_table_privilege('pgreact_mdm_worker',st.pgt_relid,'MAINTAIN')) "
                "ORDER BY st.pgt_id),'[]') "
                "FROM pgtrickle.pgt_stream_tables st "
                "JOIN pg_catalog.pg_class c ON c.oid=st.pgt_relid", "s1_logical"))
            expected_streams = [{key: item[key] for key in (
                "name", "owner_name", "orchestration_mode", "mdm_runtime_maintain", "worker_maintain")}
                                for item in stream_definitions]
            assert sorted(recreated_streams, key=lambda item: item["name"]) == \
                sorted(expected_streams, key=lambda item: item["name"]), {
                "expected": expected_streams, "actual": recreated_streams}
            recovery = json.loads(sql("SELECT pgtrickle.validate_recovery()", "s1_logical"))
            reinitialization = {
                "result": "passed" if recovery["status"] == "SAFE" else "blocked",
                "stream_count": len(recreated_streams),
                "owners_and_orchestration_modes_preserved": True,
                "runtime_maintain_privileges_preserved": True,
                "validation": recovery}
            observations["logical_restore"]["producer_reinitialization"] = reinitialization
            if recovery["status"] != "SAFE":
                observations["logical_restore"]["capture_recovery"] = {
                    "result": "blocked", "adoption_validation": adoption_validation,
                    "validation": recovery,
                    "output_delta_log_heads_and_contracts_preserved": True,
                    "output_delta_batches_unchanged_at_adoption": True,
                    "output_delta_consumer_cursors_preserved_and_invalidated": True}
                observations["logical_restore"]["pending_delivery"] = {
                    "result": "blocked", "reason": "PGT_CAPTURE_REINITIALIZATION_REQUIRED"}
                observations["checks"].append({
                    "name": "logical-restore-producer-reinitialization", "result": "blocked",
                    "reason": recovery["status"]})
                observations["checks"].append({
                    "name": "logical-restore-pending-delivery", "result": "blocked",
                    "reason": "PGT_CAPTURE_REINITIALIZATION_REQUIRED"})
                observations["entry_decision"] = "FOCUSED_REACT_LOGICAL_RESTORE_QUALIFIED"
                observations["remaining_gates"] = [
                    "repair restored pg_trickle CDC source bindings",
                    "pending React work delivery after producer reinitialization"]
                print("BLOCKED: reinitialized producer capture still requires recovery", flush=True)
                return
            observations["checks"].append({
                "name": "logical-restore-producer-reinitialization", "result": "passed"})
            print("PASS: logical-restore producer DAG and CDC bindings reinitialized", flush=True)
        observations["logical_restore"]["capture_recovery"] = {
            "result": "passed" if recovery["status"] == "SAFE" else "blocked",
            "validation": recovery,
            **({"adoption_validation": adoption_validation,
                "producer_reinitialization": reinitialization} if reinitialization else {}),
            "database_identity_rebound": True,
            "output_delta_stream_relation_oids_rebound": True,
            "output_delta_payload_relation_oids_rebound": True,
            "output_delta_log_heads_and_contracts_preserved": True,
            "output_delta_batches_unchanged_at_adoption": True,
            "output_delta_consumer_cursors_preserved_and_invalidated": True}
        observations["checks"].append({
            "name": "logical-restore-pgtrickle-capture-recovery",
            "result": "passed"})
        post_reinitialization_metadata = json.loads(recovery_sql(
            "SELECT row_to_json(r) FROM pgreact.rebuild_transient_metadata() r"))
        expected_rebuilt_after_reinitialization = sum(
            version["state"] != "REMOVED" for version in before["rule_versions"])
        assert post_reinitialization_metadata == {
            "rebuilt_rules": expected_rebuilt_after_reinitialization, "blocked_rules": 0}, \
            post_reinitialization_metadata
        assert sql("SELECT count(*) FROM pgreact_internal.rule_barriers", "s1_logical") == "0"
        post_reinitialization_state = json.loads(sql(state_query, "s1_logical"))
        observations["logical_restore"]["react_metadata_rebind_after_producer_reinitialization"] = {
            "result": "passed", "metadata_rebuild": post_reinitialization_metadata,
            "complete_state_preserved": post_reinitialization_state == recovered_state}
        assert post_reinitialization_state == recovered_state, \
            "React stream references were not rebound after producer DAG reinitialization"
        observations["checks"].append({
            "name": "logical-restore-react-metadata-rebind-after-producer-reinitialization",
            "result": "passed"})
        command("docker", "exec", container, "psql", "-XAtq", "-U", "postgres", "-d", "s1_logical",
                "-v", "ON_ERROR_STOP=1", "-v", "helper_owner=mdm_helper_owner",
                "-f", "/workspace/tests/integrations/pg-mdm/pg-mdm-configure-helper.sql")
        observations["checks"].append({"name": "logical-restore-mdm-helper-config", "result": "passed"})
        try:
            fixture("logical-restore-reconcile-replay", "/work/tests/integrations/pg-mdm/time/recovery.sql",
                    "s1_logical", ("-v", "pending=true", "-v", "activate=true"))
        except RuntimeError as error:
            if "MDM_HELPER_OWNER_UNSAFE" not in str(error):
                raise
            observations["checks"][-1] = {
                "name": "logical-restore-reconcile-replay", "result": "blocked",
                "reason": "MDM_HELPER_OWNER_UNSAFE"}
            observations["logical_restore"]["mdm_reactivation"] = {
                "result": "blocked", "reason": "MDM_HELPER_OWNER_UNSAFE"}
            observations["entry_decision"] = "FOCUSED_REACT_LOGICAL_RESTORE_QUALIFIED"
            observations["remaining_gates"] = [
                "MDM helper ownership after producer reinitialization",
                "pending React work delivery after MDM reactivation"]
            print("BLOCKED: logical-restore MDM reactivation requires a safe helper owner", flush=True)
            return
        reactivated_state = json.loads(sql(state_query, "s1_logical"))
        observations["logical_restore"]["after_mdm_reactivation"] = reactivated_state
        changed_vectors = {key: {"before_count": len(recovered_state[key]) if isinstance(recovered_state[key], list) else None,
                                 "after_count": len(reactivated_state[key]) if isinstance(reactivated_state[key], list) else None}
                           for key in recovered_state if recovered_state[key] != reactivated_state[key]}
        assert not changed_vectors, {"changed_vectors": changed_vectors}
        observations["logical_restore"]["mdm_reactivation"] = {"result": "passed"}
        suspended_streams = json.loads(sql(
            "SELECT COALESCE(jsonb_agg(format('%I.%I',pgt_schema,pgt_name) ORDER BY pgt_id),'[]') "
            "FROM pgtrickle.pgt_stream_tables WHERE status='SUSPENDED'", "s1_logical"))
        approved_streams = {item["name"] for item in stream_definitions}
        assert set(suspended_streams) <= approved_streams, suspended_streams
        sql(
            "SELECT pgtrickle.resume_stream_table(format('%I.%I',pgt_schema,pgt_name)) "
            "FROM pgtrickle.pgt_stream_tables WHERE status='SUSPENDED' ORDER BY pgt_id",
            "s1_logical")
        remaining_suspended = json.loads(sql(
            "SELECT COALESCE(jsonb_agg(format('%I.%I',pgt_schema,pgt_name) ORDER BY pgt_id),'[]') "
            "FROM pgtrickle.pgt_stream_tables WHERE status='SUSPENDED'", "s1_logical"))
        assert not remaining_suspended, remaining_suspended
        resume_validation = json.loads(sql("SELECT pgtrickle.validate_recovery()", "s1_logical"))
        assert resume_validation["status"] == "SAFE", resume_validation
        assert json.loads(sql(state_query, "s1_logical")) == recovered_state
        observations["logical_restore"]["stream_resumption_after_mdm_rebind"] = {
            "suspended_before_resume": suspended_streams,
            "resumed_stream_count": len(suspended_streams),
            "validation": resume_validation,
            "complete_state_preserved": True}
        observations["checks"].append({
            "name": "logical-restore-stream-resumption-after-mdm-rebind", "result": "passed"})
        try:
            drain_restored_pending(state_query, before, "s1_logical")
        except AssertionError as error:
            if "pg_trickle capture is quarantined because database identity changed" not in str(error):
                raise
            observations["logical_restore"]["pending_delivery"] = {
                "result": "blocked", "reason": "PGT_CAPTURE_QUARANTINED"}
            observations["checks"].append({
                "name": "logical-restore-pending-delivery", "result": "blocked",
                "reason": "PGT_CAPTURE_QUARANTINED"})
            observations["entry_decision"] = "FOCUSED_REACT_LOGICAL_RESTORE_QUALIFIED"
            observations["remaining_gates"] = [
                "pg_trickle capture remains quarantined after logical restore",
                "pending React work delivery after MDM reactivation"]
            print("BLOCKED: restored pending delivery remains blocked by pg_trickle capture quarantine", flush=True)
            return
        assert json.loads(sql(state_query)) == before, "logical restore recovery changed the source effects"
        observations["logical_restore"]["pending_delivery"] = {"result": "passed"}
        observations["checks"].append({"name": "logical-restore-pending-delivery", "result": "passed"})

        retention_target = json.loads(sql(
            "SELECT jsonb_build_object('case_key',r.case_key,'receipt_id',r.receipt_id::text) "
            "FROM mdm_steward.policy_receipts_v1 r "
            "JOIN mdm_steward.policy_bindings_v1 b USING (binding_id) "
            "JOIN mdm_internal.entities e USING (entity_id) "
            "WHERE e.entity_name='policy_qualification' AND r.outcome='APPLIED_CONTROL' "
            "ORDER BY r.created_at DESC,r.receipt_id LIMIT 1", "s1_idle"))
        assert retention_target is not None, "logical restore retention probe needs an applied MDM receipt"
        case_key = int(retention_target["case_key"])
        receipt_id = str(uuid.UUID(retention_target["receipt_id"]))
        sql("CREATE SCHEMA s1_retention; "
            "CREATE TABLE s1_retention.archive_target AS "
            "SELECT r.case_key,r.receipt_id,r.binding_id,r.request_key FROM mdm_steward.policy_receipts_v1 r "
            "WHERE r.receipt_id='" + receipt_id + "'::uuid; "
            "GRANT SELECT ON s1_retention.archive_target TO mdm_legacy_administrator; "
            "UPDATE mdm_steward.policy_cases_v1 SET status='resolved',permitted_actions='{}'::text[], "
            "resolved_at=clock_timestamp()-interval '91 days' WHERE case_key=" + str(case_key), "s1_idle")
        sql("UPDATE mdm_steward.policy_receipts_v1 SET created_at=clock_timestamp()-interval '89 days' "
            "WHERE receipt_id='" + receipt_id + "'::uuid", "s1_idle")
        retention_boundary = sql(
            "SELECT c.status='resolved' "
            "AND c.resolved_at<=clock_timestamp()-interval '90 days' "
            "AND r.created_at>clock_timestamp()-interval '90 days' "
            "FROM s1_retention.archive_target t "
            "JOIN mdm_steward.policy_cases_v1 c ON c.case_key=t.case_key "
            "JOIN mdm_steward.policy_receipts_v1 r ON r.receipt_id=t.receipt_id", "s1_idle")
        assert retention_boundary == "t", retention_boundary
        retention_fields = (
            "mdm_entity", "mdm_policy_bindings", "mdm_adapter_bindings", "cases", "receipts",
            "requests", "intent_attempts", "holds", "identities", "identity_sequence", "business")
        source_state = json.loads(sql(state_query, "s1_idle"))
        retention_archive_before = {key: source_state[key] for key in retention_fields}
        retention_archive_hash = hashlib.sha256(json.dumps(
            retention_archive_before, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        command("docker", "exec", container, "pg_dump", "-Fc", "-U", "postgres", "-d", "s1_idle",
                "-f", "/tmp/s1-retention-history.dump")
        retention_dump_sha256 = command(
            "docker", "exec", container, "sha256sum", "/tmp/s1-retention-history.dump").split()[0]
        command("docker", "exec", container, "createdb", "-U", "postgres", "s1_retention_restore")
        retention_restore_log = command("docker", "exec", container, "pg_restore", "--exit-on-error",
            "-U", "postgres", "-d", "s1_retention_restore", "/tmp/s1-retention-history.dump")
        (output / "logical-retention-restore.log").write_text(retention_restore_log)
        restored_state = json.loads(sql(state_query, "s1_retention_restore"))
        retention_archive_after = {key: restored_state[key] for key in retention_fields}
        retention_archive_changes = {
            key: {"before": retention_archive_before[key], "after": retention_archive_after[key]}
            for key in retention_fields if retention_archive_before[key] != retention_archive_after[key]}
        assert not retention_archive_changes, {
            "before_sha256": retention_archive_hash, "changed_fields": retention_archive_changes}
        restored_boundary = sql(
            "SELECT c.status='resolved' "
            "AND c.resolved_at<=clock_timestamp()-interval '90 days' "
            "AND r.created_at>clock_timestamp()-interval '90 days' "
            "FROM s1_retention.archive_target t "
            "JOIN mdm_steward.policy_cases_v1 c ON c.case_key=t.case_key "
            "JOIN mdm_steward.policy_receipts_v1 r ON r.receipt_id=t.receipt_id",
            "s1_retention_restore")
        assert restored_boundary == "t", restored_boundary
        retention_adapter_restore = reinstall_mdm_adapter(
            "s1_retention_restore", "retention-archive-adapter-reinstall")
        retention_reactivation = fixture("retention-archive-reconcile-replay",
            "/work/tests/integrations/pg-mdm/time/recovery.sql", "s1_retention_restore",
            ("-v", "pending=true", "-v", "activate=true"))
        assert retention_reactivation == (
            '{"entity_name": "policy_qualification", "desired_version": 1, "rebound_sources": 1}\n'
            "1\nrecovery vectors and activation barrier passed\n"), retention_reactivation
        reactivated_retention_state = json.loads(sql(state_query, "s1_retention_restore"))
        reactivated_retention_fields = {key: reactivated_retention_state[key] for key in retention_fields}
        assert reactivated_retention_fields == retention_archive_before, {
            "error": "reconciling restored MDM binding changed retained history",
            "changed_fields": [key for key in retention_fields
                if reactivated_retention_fields[key] != retention_archive_before[key]]}
        retention_result = fixture("history-retention-archive-restore",
            "/work/tests/integrations/pg-mdm/time/history-retention-archive-restore.sql",
            "s1_retention_restore", ("-v", "VERBOSITY=verbose"))
        retention_lines = retention_result.splitlines()
        assert len(retention_lines) == 7 and retention_lines[:5] == ["", "", "", "", ""], \
            retention_result
        restored_guard_health = json.loads(retention_lines[5])
        assert restored_guard_health == expected_history_guard_health(True), restored_guard_health
        assert retention_lines[6] == (
            "PASS: restored 89-day history stays protected; aged pruning preserves request keys and bindings"), \
            retention_lines[6]
        observations["logical_restore"]["retention_archive"] = {
            "database": "s1_idle to s1_retention_restore",
            "case_key": case_key,
            "receipt_id": receipt_id,
            "case_age_at_dump_days": 91,
            "receipt_age_at_dump_days": 89,
            "state_sha256_before_and_after_restore": retention_archive_hash,
            "dump_sha256": retention_dump_sha256,
            "exact_entity_binding_case_receipt_request_attempt_state_preserved": True,
            "adapter_restore": retention_adapter_restore,
            "post_restore_reconciliation": "passed",
            "post_restore_guard_health": restored_guard_health,
            "retention_blocks_and_aged_pruning_after_restore": "passed"}
        observations["checks"].append({
            "name": "logical-restore-near-horizon-retention-state", "result": "passed"})
        observations["checks"].append({
            "name": "logical-restore-retention-guard-health", "result": "passed"})
        observations["checks"].append({
            "name": "logical-restore-retention-guard-and-key-preservation", "result": "passed"})
        print("PASS: logical restore retained protected MDM history near the 90-day boundary",
              flush=True)
        active_duration_history_before = json.loads(sql(
            "SELECT pgreact_api.temporal_history('s1-logical-restore-active-duration')",
            "s1_logical"))
        active_duration_events_before = [event for event in active_duration_history_before
                                         if event["semantic_key"] == 9101]
        assert active_duration_events_before and all(
            event["primitive_state"] == "PENDING" and event["event_kind"] != "ACTIVATE"
            for event in active_duration_events_before), active_duration_events_before
        before_due_ready = sql(
            "SELECT (SELECT frontier FROM pgreact_internal.clock_frontier WHERE singleton) "
            "< temporal.pending_deadline - interval '1 microsecond' "
            "FROM pgreact_internal.temporal_state temporal "
            "JOIN pgreact_internal.rule_versions version USING (rule_version_id) "
            "JOIN pgreact_internal.rules rule USING (rule_id) "
            "WHERE rule.rule_name='s1-logical-restore-active-duration' "
            "AND temporal.semantic_key=9101", "s1_logical")
        assert before_due_ready == "t", before_due_ready
        early_run = json.loads(sql(
            "SELECT pgreact_api.run(temporal.pending_deadline - interval '1 microsecond') "
            "FROM pgreact_internal.temporal_state temporal "
            "JOIN pgreact_internal.rule_versions version USING (rule_version_id) "
            "JOIN pgreact_internal.rules rule USING (rule_id) "
            "WHERE rule.rule_name='s1-logical-restore-active-duration' "
            "AND temporal.semantic_key=9101", "s1_logical"))
        active_duration_before_deadline = json.loads(
            sql(active_duration_state_query, "s1_logical"))
        assert active_duration_before_deadline == active_duration_before, \
            active_duration_before_deadline
        early_frontier_exact = sql(
            "SELECT (SELECT frontier FROM pgreact_internal.clock_frontier WHERE singleton) "
            "= temporal.pending_deadline - interval '1 microsecond' "
            "FROM pgreact_internal.temporal_state temporal "
            "JOIN pgreact_internal.rule_versions version USING (rule_version_id) "
            "JOIN pgreact_internal.rules rule USING (rule_id) "
            "WHERE rule.rule_name='s1-logical-restore-active-duration' "
            "AND temporal.semantic_key=9101", "s1_logical")
        assert early_frontier_exact == "t", early_frontier_exact
        active_duration_history_before_due = json.loads(sql(
            "SELECT pgreact_api.temporal_history('s1-logical-restore-active-duration')",
            "s1_logical"))
        active_duration_events_before_due = [event for event in active_duration_history_before_due
                                             if event["semantic_key"] == 9101]
        expected_early_observation = {
            "rule": "s1-logical-restore-active-duration", "semantic_key": 9101,
            "event_kind": "OBSERVE", "primitive_state": "PENDING",
            "input_true": True, "recovery_true": False,
            "continuous_since": active_duration_before["continuous_since"],
            "pending_deadline": active_duration_before["pending_deadline"],
            "cooldown_until": None,
            "clock_frontier": json.loads(sql(
                "SELECT to_jsonb(temporal.pending_deadline - interval '1 microsecond') "
                "FROM pgreact_internal.temporal_state temporal "
                "JOIN pgreact_internal.rule_versions version USING (rule_version_id) "
                "JOIN pgreact_internal.rules rule USING (rule_id) "
                "WHERE rule.rule_name='s1-logical-restore-active-duration' "
                "AND temporal.semantic_key=9101", "s1_logical")),
            "lifecycle_event_id": None,
            "bindings": active_duration_events_before[-1]["bindings"]}
        assert active_duration_events_before_due == (
            active_duration_events_before + [expected_early_observation]), \
            active_duration_events_before_due
        observations["logical_restore"]["active_duration_before_deadline"] = {
            "run": early_run,
            "state": active_duration_before_deadline,
            "frontier_equals_deadline_minus_one_microsecond": True,
            "history_before": active_duration_events_before,
            "history_after": active_duration_events_before_due}
        observations["checks"].append({
            "name": "logical-restore-active-duration-not-early", "result": "passed"})
        state_before_duration_deadline = json.loads(sql(state_query, "s1_logical"))
        deadline_run = json.loads(sql(
            "SELECT pgreact_api.run(temporal.pending_deadline) "
            "FROM pgreact_internal.temporal_state temporal "
            "JOIN pgreact_internal.rule_versions version USING (rule_version_id) "
            "JOIN pgreact_internal.rules rule USING (rule_id) "
            "WHERE rule.rule_name='s1-logical-restore-active-duration' "
            "AND temporal.semantic_key=9101", "s1_logical"))
        active_duration_at_deadline = json.loads(sql(
            active_duration_state_query, "s1_logical"))
        expected_duration_at_deadline = dict(
            active_duration_before, state="ACTIVE", active=True, generation=1)
        assert active_duration_at_deadline == expected_duration_at_deadline, \
            active_duration_at_deadline
        deadline_frontier_exact = sql(
            "SELECT (SELECT frontier FROM pgreact_internal.clock_frontier WHERE singleton) "
            "= temporal.pending_deadline "
            "FROM pgreact_internal.temporal_state temporal "
            "JOIN pgreact_internal.rule_versions version USING (rule_version_id) "
            "JOIN pgreact_internal.rules rule USING (rule_id) "
            "WHERE rule.rule_name='s1-logical-restore-active-duration' "
            "AND temporal.semantic_key=9101", "s1_logical")
        assert deadline_frontier_exact == "t", deadline_frontier_exact
        active_duration_history_at_deadline = json.loads(sql(
            "SELECT pgreact_api.temporal_history('s1-logical-restore-active-duration')",
            "s1_logical"))
        active_duration_events_at_deadline = [event for event in active_duration_history_at_deadline
                                              if event["semantic_key"] == 9101]
        expected_duration_activation = {
            "rule": "s1-logical-restore-active-duration", "semantic_key": 9101,
            "event_kind": "ACTIVATE", "primitive_state": "ACTIVE",
            "input_true": True, "recovery_true": False,
            "continuous_since": active_duration_before["continuous_since"],
            "pending_deadline": active_duration_before["pending_deadline"],
            "cooldown_until": None,
            "clock_frontier": active_duration_before["pending_deadline"],
            "lifecycle_event_id": int(
                state_before_duration_deadline["react_sequences"]["lifecycle_events"]) + 1,
            "bindings": active_duration_events_before_due[-1]["bindings"]}
        assert active_duration_events_at_deadline == (
            active_duration_events_before_due + [expected_duration_activation]), \
            active_duration_events_at_deadline
        observations["logical_restore"]["active_duration_at_deadline"] = {
            "run": deadline_run,
            "state": active_duration_at_deadline,
            "frontier_equals_deadline": True,
            "history_before": active_duration_events_before_due,
            "history_after": active_duration_events_at_deadline}
        observations["checks"].append({
            "name": "logical-restore-active-duration-at-deadline", "result": "passed"})
        temporal_history_before = json.loads(sql(
            "SELECT pgreact_api.temporal_history('s1-logical-restore-active-temporal')",
            "s1_logical"))
        active_history_before = [event for event in temporal_history_before
                                 if event["semantic_key"] == 9002]
        assert active_history_before and active_history_before[0]["event_kind"] == "ACTIVATE", \
            active_history_before
        assert active_history_before[-1]["primitive_state"] == "ACTIVE" \
            and active_history_before[-1]["input_true"] \
            and not active_history_before[-1]["recovery_true"], active_history_before[-1]
        state_before_temporal_transition = json.loads(sql(state_query, "s1_logical"))
        updated_recovery_key = sql(
            "UPDATE logical_restore_temporal_probe.conditions SET recovery_condition=true "
            "WHERE semantic_key=9002 AND NOT recovery_condition RETURNING semantic_key",
            "s1_logical").strip()
        assert updated_recovery_key == "9002", updated_recovery_key
        transition_id = int(sql(
            "SELECT pgreact_api.reconcile_temporal_rule('s1-logical-restore-active-temporal')",
            "s1_logical"))
        active_temporal_after_transition = json.loads(sql(active_temporal_state_query, "s1_logical"))
        expected_temporal_after_transition = dict(
            expected_active_temporal, state="RECOVERED", active=False, recovery_true=True)
        assert active_temporal_after_transition == expected_temporal_after_transition, \
            active_temporal_after_transition
        expected_transition = {
            "rule": "s1-logical-restore-active-temporal", "semantic_key": 9002,
            "event_kind": "DEACTIVATE", "primitive_state": "RECOVERED",
            "input_true": True, "recovery_true": True,
            "continuous_since": None, "pending_deadline": None, "cooldown_until": None,
            "clock_frontier": active_history_before[-1]["clock_frontier"],
            "lifecycle_event_id": int(
                state_before_temporal_transition["react_sequences"]["lifecycle_events"]) + 1,
            "bindings": active_history_before[-1]["bindings"]}
        temporal_history_after = json.loads(sql(
            "SELECT pgreact_api.temporal_history('s1-logical-restore-active-temporal')",
            "s1_logical"))
        active_history_after = [event for event in temporal_history_after
                                if event["semantic_key"] == 9002]
        assert active_history_after == active_history_before + [expected_transition], \
            active_history_after
        assert transition_id == expected_transition["lifecycle_event_id"], transition_id
        observations["logical_restore"]["active_temporal_continuation"] = {
            "condition_key_updated": int(updated_recovery_key),
            "transition_id": transition_id,
            "state_after": active_temporal_after_transition,
            "history_before": active_history_before,
            "history_after": active_history_after}
        observations["checks"].append({
            "name": "logical-restore-active-temporal-transition-after-recovery",
            "result": "passed"})
        print("PASS: restored active temporal rule consumed its rebound recovery condition",
              flush=True)
        observations["entry_decision"] = "FOCUSED_REACT_LOGICAL_RESTORE_QUALIFIED"
        observations["remaining_gates"] = profile["remaining_measurements"]
        print("PASS: logical restore rebound capture OIDs and delivered pending work", flush=True)

    def qualify_clean_clone(state_query, before):
        nonlocal container, clone_volume
        original = container
        clone = original + "-clone"
        identity_query = (
            "SELECT jsonb_build_object('database_oid',(SELECT oid FROM pg_database WHERE datname=current_database()),"
            "'worker_oid',(SELECT oid FROM pg_roles WHERE rolname='pgreact_mdm_worker'),"
            "'bindings',(SELECT jsonb_agg(to_jsonb(b) ORDER BY binding_id) FROM pgreact_mdm.policy_intent_bindings b),"
            "'react_runtime',(SELECT jsonb_agg(to_jsonb(r) ORDER BY binding_id) FROM pgreact_mdm.policy_intent_runtime r),"
            "'mdm_runtime',(SELECT jsonb_agg(to_jsonb(r) ORDER BY binding_id) FROM mdm_internal.policy_binding_runtime r))")
        identity = json.loads(sql(identity_query))
        assert identity["react_runtime"] and identity["mdm_runtime"]
        has_epoch = sql("SELECT to_regprocedure('mdm_internal.policy_runtime_epoch()') IS NOT NULL") == "t"
        source_epoch = sql("SELECT encode(mdm_internal.policy_runtime_epoch(),'hex')") if has_epoch else None
        if has_epoch:
            assert len(source_epoch) == 64
        assert sql("SHOW data_directory") == "/var/lib/postgresql/18/docker"
        sql("ALTER SYSTEM SET pg_react.databases = " + ("''" if direct_clone else "'s1_idle'"))
        sql("ALTER SYSTEM SET pg_react.worker_role = 'mdm_s1_runtime'")
        command("docker", "stop", "-t", "60", original)
        try:
            clone_volume = clone + "-data"
            command("docker", "volume", "create", clone_volume)
            command("docker", "run", *platform_args, "--rm", "--network", "none", "--user", "0", "--volumes-from", original,
                    "--mount", "type=volume,source=" + clone_volume + ",destination=/clone",
                    "--entrypoint", "cp", image, "-a", "/var/lib/postgresql/.", "/clone/")
            command("docker", "create", *platform_args, "--name", clone, "--network", "none",
                    "--mount", "type=volume,source=" + clone_volume + ",destination=/var/lib/postgresql",
                    "--env", "POSTGRES_HOST_AUTH_METHOD=trust", "--volume", str(root) + ":/work:ro",
                    image, "postgres", "-c", "shared_preload_libraries=pg_trickle,pg_mdm,pg_react",
                    "-c", "pg_react.batch_size=1", "-c", "pg_react.poll_interval_ms=1000",
                    "-c", "pg_trickle.enabled=off", "-c", "pg_trickle.cdc_mode=trigger",
                    "-c", "pg_trickle.differential_max_change_ratio=1.0",
                    "-c", "default_transaction_isolation=read committed")
            container = clone
            command("docker", "start", clone)
            end = time.monotonic() + 60
            while time.monotonic() < end:
                ready = subprocess.run(["docker", "exec", clone, "pg_isready", "-U", "postgres"], capture_output=True)
                if not ready.returncode:
                    break
                time.sleep(0.2)
            else:
                raise AssertionError("clean clone did not start")
            actual_identity = json.loads(sql(identity_query))
            assert actual_identity == identity, {"expected": identity, "actual": actual_identity}
            if has_epoch:
                clone_epoch = sql("SELECT encode(mdm_internal.policy_runtime_epoch(),'hex')")
                assert len(clone_epoch) == 64 and clone_epoch != source_epoch
                observations["postmaster_epochs"] = {"source": source_epoch, "clone": clone_epoch}
            if direct_clone:
                assert json.loads(sql(state_query)) == before
                pending_id = next(w["work_id"] for w in before["work"] if w["state"] == "PENDING")
                case_key = int(sql("SELECT (new_bindings->>'case_key')::bigint FROM pgreact_internal.agenda "
                                   "WHERE episode_id=" + str(int(pending_id))))
                case = next(c for c in before["cases"] if c["case_key"] == case_key)
                binding = next(b for b in identity["bindings"] if b["enabled"])
                query = ("SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "
                         "SELECT to_jsonb(r) FROM mdm_steward.submit_policy_intent("
                         "'{}'::uuid,decode(repeat('f',64),'hex'),{},'ESCALATE','{{\"level\":2}}'::jsonb,"
                         "{},{},{},{},decode('{}','hex'),{},decode('{}','hex'),'{}','clone-direct','clone-direct') r")
                query = query.format(binding["binding_id"], case_key, case["review_version"],
                                     case["definition_version"], case["publication_revision"],
                                     case["stewardship_epoch"], case["evidence_basis_digest"][2:],
                                     case["action_revision"], binding["policy_digest"][2:], binding["policy_revision"])
                try:
                    response = {"result": json.loads(sql(query))}
                except RuntimeError as error:
                    response = {"error": str(error)}
                after = json.loads(sql(state_query))
                observations["clean_clone_direct"] = {"identity": actual_identity, "before": before,
                                                       "response": response, "after": after}
                assert "explicit policy activation is required for this postmaster" in response.get("error", ""), response
                assert after == before, "blocked MDM delivery changed durable recovery state"
                observations["checks"].append({"name": "clean-clone-direct-delivery-blocked", "result": "passed"})
                observations["entry_decision"] = "FOCUSED_CLEAN_CLONE_DIRECT_BLOCK_QUALIFIED"
                observations["remaining_gates"] = profile["remaining_measurements"]
                return
            postmaster_start = timestamp(json.loads(sql("SELECT to_json(pg_postmaster_start_time())")))
            end = time.monotonic() + 30
            while time.monotonic() < end:
                after = json.loads(sql(state_query))
                status = json.loads(sql("SELECT pgreact_api.managed_status()"))
                if after != before:
                    break
                process = status.get("process") or {}
                if (process.get("state") == "error" and process.get("detail") == "MDM activation required"
                        and process.get("heartbeat_at")
                        and timestamp(process["heartbeat_at"]) > postmaster_start + datetime.timedelta(seconds=4)):
                    break
                time.sleep(0.2)
            observations["clean_clone"] = {"identity": actual_identity, "before": before, "after": after,
                                           "managed_status": status}
            assert after == before, "clean physical clone changed durable work or controls before activation"
            assert process.get("state") == "error" and process.get("detail") == "MDM activation required" and process.get("heartbeat_at") and \
                timestamp(process["heartbeat_at"]) > postmaster_start + datetime.timedelta(seconds=4), status
            observations["checks"].append({"name": "clean-clone-preactivation", "result": "passed"})
            request = before["requests"][0]
            body = request["request_body"]
            old_attempt = next(a for a in before["intent_attempts"] if a["request_key"] == request["request_key"])
            quote = lambda value: str(value).replace("'", "''")
            replay = ("SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; "
                      "SELECT to_jsonb(r) FROM mdm_steward.submit_policy_intent("
                      "'{}'::uuid,decode('{}','hex'),{},'{}','{}'::jsonb,{},{},{},{},"
                      "decode('{}','hex'),{},decode('{}','hex'),'{}','{}','{}') r").format(
                          request["binding_id"], request["request_key"][2:], request["case_key"],
                          quote(body["action"]), quote(json.dumps(body["arguments"])),
                          body["expected_review_version"], body["expected_definition_version"],
                          body["expected_publication_revision"], body["expected_stewardship_epoch"],
                          body["expected_evidence_basis_digest"], body["expected_action_revision"],
                          body["expected_policy_digest"], quote(request["policy_revision"]),
                          quote(body["evaluation_ref"]), quote(request["work_ref"]))
            expected_receipt = {k: old_attempt[k] for k in ("receipt_id", "outcome", "reason_code", "case_key",
                                "action_revision", "control", "resulting_publication_revision")}
            assert json.loads(sql(replay)) == expected_receipt
            assert json.loads(sql(state_query)) == before
            binding = next(b for b in identity["bindings"] if b["enabled"])
            runtime = next(r for r in identity["mdm_runtime"] if r["binding_id"] == binding["binding_id"])
            activate = "SELECT pgreact_mdm.reconcile_intent_binding('{}'::uuid,{})".format(
                binding["binding_id"], runtime["runtime_version"])
            rejections = observations["activation_rejections"] = {}
            try:
                sql("SET SESSION AUTHORIZATION mdm_s1_runtime; SET ROLE pgreact_mdm_worker; " + activate)
                raise AssertionError("worker role unexpectedly activated the copied binding")
            except RuntimeError as error:
                rejections["unauthorized"] = str(error)
                assert "MDM_WORKER_ROLE_MEMBERSHIP" in str(error) or "MDM_BINDING_ACTOR" in str(error), str(error)
            assert json.loads(sql(state_query)) == before
            stale = "SELECT pgreact_mdm.reconcile_intent_binding('{}'::uuid,{})".format(
                binding["binding_id"], runtime["runtime_version"] - 1)
            try:
                sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; " + stale)
                raise AssertionError("stale runtime version unexpectedly activated the copied binding")
            except RuntimeError as error:
                rejections["stale_version"] = str(error)
                assert "runtime version is stale or binding is replaced" in str(error), str(error)
            sql("GRANT mdm_helper_owner TO pgreact_mdm_worker")
            try:
                try:
                    sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; " + activate)
                    raise AssertionError("unsafe worker membership unexpectedly activated the copied binding")
                except RuntimeError as error:
                    rejections["unsafe_worker_membership"] = str(error)
                    assert "MDM_WORKER_ROLE_MEMBERSHIP" in str(error), str(error)
            finally:
                sql("REVOKE mdm_helper_owner FROM pgreact_mdm_worker")
            try:
                sql("BEGIN; SET LOCAL pg_trickle.cdc_mode=wal; "
                    "SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; " + activate)
                raise AssertionError("unsupported producer settings unexpectedly activated the copied binding")
            except RuntimeError as error:
                rejections["unsupported_producer"] = str(error)
                assert "pg-react pg_trickle runtime is unsupported" in str(error), str(error)
            try:
                unexpected = sql("BEGIN; UPDATE pgreact_mdm.policy_intent_bindings SET max_escalation_level=1 "
                                 "WHERE binding_id='" + binding["binding_id"] + "'::uuid; "
                                 "SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; " + activate)
                rejections["binding_mismatch_unexpected_result"] = unexpected
                raise AssertionError("mismatched adapter binding unexpectedly activated")
            except RuntimeError as error:
                rejections["binding_mismatch"] = str(error)
                assert "MDM_RECOVERY_BINDING_MISMATCH" in str(error), str(error)
            assert json.loads(sql(state_query)) == before
            sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; " + activate)
            drain_restored_pending(state_query, before, "s1_idle", automatic=True, already_running=True)
            observations["entry_decision"] = "FOCUSED_CLEAN_CLONE_RECOVERY_QUALIFIED"
        finally:
            subprocess.run(["docker", "rm", "--force", "--volumes", original], capture_output=True)
            if container != clone:
                subprocess.run(["docker", "rm", "--force", "--volumes", clone], capture_output=True)

    def qualify_two_case_outage(before, source, temporal_source):
        # This bounded fixture intentionally exercises two distinct, real MDM
        # occurrence identities. It is not a numerical S1 performance result.
        selected = {row["case_key"]: timestamp(row["deadline"]) for row in temporal_source}
        assert len(selected) == len(temporal_source) == 2, temporal_source
        assert len({row["deadline"] for row in temporal_source}) == 2, temporal_source
        assert all(t > datetime.datetime.now(datetime.timezone.utc)
                   for t in selected.values()), temporal_source
        original = {row["case_key"]: row for row in before}
        assert set(selected) <= set(original)
        expected = copy.deepcopy(before)
        for row in expected:
            if row["case_key"] in selected:
                assert row["status"] == "open" and not row["pending_stewardship"], row
                assert row["escalation_level"] == 1 and "ESCALATE" in row["permitted_actions"], row
                assert timestamp(row["due_at"]) == selected[row["case_key"]], row
                row["escalation_level"] = 2
                row["action_revision"] += 1

        state_query = (
            "SELECT jsonb_build_object("
            "'cases',(SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY case_key),'[]') FROM mdm_steward.policy_cases_v1 c),"
            "'mdm_receipts',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id),'[]') FROM mdm_steward.policy_receipts_v1 r),"
            "'intent_requests',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id,request_key),'[]') FROM pgreact_mdm.intent_requests r),"
            "'intent_attempts',(SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY episode_id,attempt_no),'[]') FROM pgreact_mdm.intent_attempts a),"
            "'rule_work',(SELECT COALESCE(jsonb_agg(to_jsonb(w) ORDER BY work_id),'[]') FROM pgreact.work w WHERE name='s1-future-idle'),"
            "'rule_attempts',(SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY execution_id),'[]') FROM pgreact.attempts a WHERE name='s1-future-idle'),"
            "'business',(SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY id),'[]') FROM public.policy_qualification_source s),"
            "'technical',(SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY case_key),'[]') FROM s1_audit.source s))"
        )
        before_state = json.loads(sql(state_query))
        assert before_state["cases"] == before and before_state["business"] == source
        assert before_state["technical"] == temporal_source
        assert not before_state["intent_requests"] and not before_state["intent_attempts"]
        assert not before_state["rule_work"] and not before_state["rule_attempts"]
        assert not [r for r in before_state["mdm_receipts"]
                    if r["request_body"].get("policy_revision") == "s1-idle-feasibility"]
        binding = json.loads(sql(
            "SELECT jsonb_build_object('binding_id',binding_id,'binding_version',binding_version,"
            "'policy_digest',encode(policy_digest,'hex'),"
            "'runtime_version',runtime.runtime_version) FROM pgreact_mdm.policy_intent_bindings binding "
            "JOIN pgreact_mdm.policy_intent_runtime runtime USING (binding_id) "
            "WHERE policy_revision='s1-idle-feasibility' AND enabled"))
        expected_controls = json.loads(sql(
            "SELECT jsonb_agg(jsonb_build_object('case_key',c.case_key,'control',"
            "jsonb_build_object('assigned_queue',c.assigned_queue,'due_at',c.due_at::text,"
            "'escalation_level',2,'manual_assignment_protected',c.manual_assignment_protected))"
            " ORDER BY c.case_key) FROM mdm_steward.policy_cases_v1 c "
            "WHERE c.case_key IN (" + ",".join(str(k) for k in sorted(selected)) + ")"))
        controls = {c["case_key"]: c["control"] for c in expected_controls}
        # The installed compatibility gate delegates to the bound-carrying
        # managed worker; inspect both deployed definitions and the public
        # claim implementation rather than assuming a direct GUC read.
        managed_definition = sql(
            "SELECT pg_get_functiondef("
            "'pgreact_internal.managed_cycle(integer)'::regprocedure)")
        worker_definition = sql(
            "SELECT pg_get_functiondef("
            "'pgreact_internal.managed_cycle_m44(integer)'::regprocedure)")
        claim_definition = sql(
            "SELECT pg_get_functiondef("
            "'pgreact.claim(text,integer,interval,text[])'::regprocedure)")
        normalized_managed = " ".join(managed_definition.split())
        normalized_worker = " ".join(worker_definition.split())
        normalized_claim = " ".join(claim_definition.split())
        assert "RETURN pgreact_internal.managed_cycle_m44(process_pid)" in normalized_managed, (
            "deployed compatibility gate no longer reaches the bounded managed worker")
        assert "batch_limit integer := current_setting('pg_react.batch_size')::integer" in normalized_worker, (
            "deployed managed worker does not read the configured batch claim limit")
        assert "claim_limit integer := least(batch_limit, 100)" in normalized_worker, (
            "deployed managed worker no longer derives the bounded claim size")
        assert "pgreact_api.claim(worker, claim_limit, interval '60 seconds')" in normalized_worker, (
            "deployed worker no longer forwards the derived claim limit")
        assert "processed := processed + 1" in normalized_worker, (
            "deployed managed worker no longer counts each claimed execution")
        assert "processed_jobs = processed_jobs + processed" in normalized_worker, (
            "deployed worker no longer persists cumulative processed counts")
        assert "count_claimed := count_claimed + 1" in normalized_claim, (
            "deployed public claim no longer increments its claim count")
        assert "EXIT WHEN count_claimed >= max_items" in normalized_claim, (
            "deployed public claim no longer stops at its requested numeric bound")
        assert "IF max_items NOT BETWEEN 1 AND claim_limit" in normalized_claim, (
            "deployed public claim no longer checks the operational bound")
        claim_limit = int(sql(
            "SELECT max_claims FROM pgreact_internal.operational_settings"))
        assert claim_limit >= 1, claim_limit
        observations["installed_cycle_claim_bound"] = {
            "managed_function": "pgreact_internal.managed_cycle(integer)",
            "managed_definition_sha256": hashlib.sha256(
                managed_definition.encode()).hexdigest(),
            "bound_carrying_function": "pgreact_internal.managed_cycle_m44(integer)",
            "bound_carrying_definition_sha256": hashlib.sha256(
                worker_definition.encode()).hexdigest(),
            "forwarded_claim_limit_expression": "least(batch_limit, 100)",
            "claim_function": "pgreact.claim(text,integer,interval,text[])",
            "claim_definition_sha256": hashlib.sha256(
                claim_definition.encode()).hexdigest(),
            "per_cycle_configured_claim_limit": 1,
            "public_operational_max_claims": claim_limit,
            "managed_to_claim_bound_verified": True,
        }

        def reconcile_after_restart():
            before_runtime = json.loads(sql(
                "SELECT jsonb_build_object('state',runtime.state,"
                "'runtime_version',runtime.runtime_version,"
                "'activation_epoch',encode(runtime.activation_epoch,'hex'),"
                "'current_epoch',encode(mdm_internal.policy_runtime_epoch(),'hex')) "
                "FROM mdm_internal.policy_binding_runtime runtime "
                "WHERE runtime.binding_id='" + binding["binding_id"] + "'::uuid"))
            assert before_runtime["activation_epoch"] != before_runtime["current_epoch"], before_runtime
            assert sql("SELECT NOT pgreact_mdm.policy_runtime_ready()") == "t"
            new_version = int(sql(
                "SET SESSION AUTHORIZATION mdm_legacy_login; "
                "SET ROLE mdm_legacy_administrator; "
                "SELECT pgreact_mdm.reconcile_intent_binding('" + binding["binding_id"] + "'::uuid, "
                + str(binding["runtime_version"]) + "); "
                "RESET ROLE; RESET SESSION AUTHORIZATION"))
            binding["runtime_version"] = new_version
            after_runtime = json.loads(sql(
                "SELECT jsonb_build_object('state',runtime.state,"
                "'runtime_version',runtime.runtime_version,"
                "'activation_epoch',encode(runtime.activation_epoch,'hex'),"
                "'current_epoch',encode(mdm_internal.policy_runtime_epoch(),'hex')) "
                "FROM mdm_internal.policy_binding_runtime runtime "
                "WHERE runtime.binding_id='" + binding["binding_id"] + "'::uuid"))
            assert after_runtime["runtime_version"] == new_version, after_runtime
            assert after_runtime["state"] == "active", after_runtime
            assert after_runtime["activation_epoch"] == after_runtime["current_epoch"], after_runtime
            assert sql("SELECT pgreact_mdm.policy_runtime_ready()") == "t"
            return {"before": before_runtime, "after": after_runtime,
                    "reconcile_api": "pgreact_mdm.reconcile_intent_binding",
                    "runtime_version": new_version}

        original_postmaster = timestamp(sql("SELECT pg_postmaster_start_time()"))
        sql("ALTER SYSTEM SET pg_react.databases = 's1_idle'")
        sql("ALTER SYSTEM SET pg_react.worker_role = 'mdm_s1_runtime'")
        sql("ALTER SYSTEM SET pg_react.batch_size = '1'")
        outage_start = time.monotonic()
        command("docker", "stop", "-t", "10", container)
        stopped_at = datetime.datetime.now(datetime.timezone.utc)
        assert stopped_at < min(selected.values()), {
            "error": "PostgreSQL must stop before both deadlines",
            "stopped_at": stopped_at.isoformat(), "deadlines": temporal_source}
        assert command("docker", "inspect", "-f", "{{.State.Running}}", container).strip() == "false"
        while datetime.datetime.now(datetime.timezone.utc) <= max(selected.values()) + datetime.timedelta(seconds=2):
            time.sleep(0.2)
        restarted_at = datetime.datetime.now(datetime.timezone.utc)
        command("docker", "start", container)
        startup_deadline = outage_start + 120
        while time.monotonic() < startup_deadline:
            ready = subprocess.run(
                ["docker", "exec", container, "pg_isready", "-U", "postgres"],
                capture_output=True, timeout=15)
            if ready.returncode == 0:
                break
            time.sleep(0.2)
        else:
            raise AssertionError("outage exceeded 120 seconds before PostgreSQL became ready")
        outage_seconds = time.monotonic() - outage_start
        assert 0 < outage_seconds <= 120, outage_seconds
        recovery_start = time.monotonic()
        assert sql("SELECT NOT pgreact_mdm.policy_runtime_ready()") == "t"
        preactivation_receipts = json.loads(sql(
            "SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY case_key,receipt_id),'[]') "
            "FROM mdm_steward.policy_receipts_v1 r "
            "WHERE r.request_body ->> 'policy_revision' = 's1-idle-feasibility'"))
        assert not preactivation_receipts, preactivation_receipts
        outage_activation = reconcile_after_restart()
        drain_start = recovery_start
        deadline = recovery_start + 180
        received = []
        status = None
        receipt_progress = []
        last_keys = set()
        while time.monotonic() < deadline:
            ready = subprocess.run(
                ["docker", "exec", container, "pg_isready", "-U", "postgres"],
                capture_output=True, timeout=15)
            if ready.returncode:
                time.sleep(0.2)
                continue
            received = json.loads(sql(
                "SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY case_key,receipt_id),'[]') "
                "FROM mdm_steward.policy_receipts_v1 r "
                "WHERE r.request_body ->> 'policy_revision' = 's1-idle-feasibility'"))
            status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            keys = {row["case_key"] for row in received}
            assert len(received) <= 2 and len(keys) == len(received), {
                "unexpected duplicate or extra receipts": received}
            assert keys <= set(selected), {"unexpected case admitted": received}
            assert last_keys <= keys, {
                "applied receipts disappeared during backlog drain": received,
                "previous": sorted(last_keys)}
            receipt_progress.append({
                "elapsed_seconds": time.monotonic() - drain_start,
                "completed_case_keys": sorted(keys),
                "receipt_count": len(received),
                "worker_state": (status.get("process") or {}).get("state"),
                "pending_jobs": (status.get("process") or {}).get("pending_jobs"),
                "processed_jobs": (status.get("process") or {}).get("processed_jobs"),
                "heartbeat_at": (status.get("process") or {}).get("heartbeat_at"),
            })
            last_keys = keys
            if len(received) == 2:
                break
            time.sleep(0.2)
        assert len(received) == 2, {"error": "two-case managed backlog did not drain",
                                    "receipts": received, "status": status,
                                    "progress": receipt_progress}
        drain_elapsed_seconds = time.monotonic() - recovery_start
        assert 0 < drain_elapsed_seconds <= 180, drain_elapsed_seconds
        assert receipt_progress and receipt_progress[-1]["receipt_count"] == 2
        assert all(sample["receipt_count"] in (0, 1, 2)
                   for sample in receipt_progress), receipt_progress
        # Two status polls cannot establish one worker cycle. A background
        # worker can complete several cycles, or update heartbeat twice within
        # one cycle, between observations regardless of elapsed time. Preserve
        # the measured cumulative-counter deltas without guessing a cycle
        # identity. The numeric per-call bound is proved separately by the
        # installed SQL call chain and the focused max_items=1 claim test.
        observed_counter_intervals = []
        latest_heartbeat = None
        latest_processed = None
        for sample in receipt_progress:
            hb = sample["heartbeat_at"]
            processed = sample["processed_jobs"]
            if hb is None or processed is None:
                continue
            parsed = timestamp(hb)
            if latest_heartbeat is not None and parsed > latest_heartbeat:
                elapsed = (parsed - latest_heartbeat).total_seconds()
                delta = processed - latest_processed
                assert delta >= 0, ("managed cumulative processed counter regressed", sample)
                observed_counter_intervals.append({
                    "from_heartbeat": latest_heartbeat.isoformat(),
                    "to_heartbeat": hb,
                    "elapsed_seconds": elapsed,
                    "processed_delta": delta,
                    "individual_cycle_attribution": False,
                })
            if latest_heartbeat is None or parsed > latest_heartbeat:
                latest_heartbeat = parsed
                latest_processed = processed
        observations["observed_counter_intervals"] = observed_counter_intervals
        new_postmaster = timestamp(sql("SELECT pg_postmaster_start_time()"))
        assert new_postmaster > original_postmaster
        assert new_postmaster > max(selected.values()) and new_postmaster >= restarted_at

        actual = json.loads(sql(state_query))
        assert actual["cases"] == expected, {"expected": expected, "actual": actual["cases"]}
        assert actual["business"] == source and actual["technical"] == temporal_source
        assert len(actual["intent_requests"]) == len(actual["intent_attempts"]) == 2, actual
        assert len(actual["rule_work"]) == len(actual["rule_attempts"]) == 2, actual
        assert all(w["state"] == "COMPLETED" and not w["claimable"]
                   for w in actual["rule_work"]), actual["rule_work"]
        assert all(a["status"] == "COMPLETED" and a["attempt_no"] == 1
                   and a["error_code"] is None
                   for a in actual["rule_attempts"]), actual["rule_attempts"]
        assert {r["case_key"] for r in received} == set(selected)
        assert {r["case_key"] for r in actual["intent_requests"]} == set(selected)
        assert len({r["request_key"] for r in received}) == 2
        assert len({r["receipt_id"] for r in received}) == 2
        requests = {r["case_key"]: r for r in actual["intent_requests"]}
        attempts = {a["case_key"]: a for a in actual["intent_attempts"]}
        assert set(attempts) == set(selected)
        work_ids = {int(w["work_id"]) for w in actual["rule_work"]}
        assert work_ids == {a["episode_id"] for a in actual["rule_attempts"]}
        for receipt in received:
            key = receipt["case_key"]
            prior = original[key]
            request = requests[key]
            attempt = attempts[key]
            body = receipt["request_body"]
            assert receipt["action"] == "ESCALATE"
            assert receipt["outcome"] == "APPLIED_CONTROL" and receipt["reason_code"] == "CONTROL_APPLIED"
            assert receipt["actor"] == "pgreact_mdm_worker"
            assert receipt["selected_role_name"] == "pgreact_mdm_worker"
            assert receipt["session_role_name"] == "mdm_s1_runtime"
            assert receipt["resulting_publication_revision"] is None
            assert receipt["binding_id"] == binding["binding_id"]
            assert receipt["binding_version"] == binding["binding_version"]
            assert receipt["action_revision"] == prior["action_revision"] + 1
            assert receipt["control"] == controls[key]
            assert timestamp(receipt["created_at"]) >= new_postmaster >= selected[key]
            assert body == request["request_body"] == attempt["request_body"]
            assert set(body) == {
                "action", "arguments", "case_key", "binding_id", "policy_revision",
                "expected_policy_digest", "expected_evidence_basis_digest",
                "evaluation_ref", "work_ref", "expected_review_version",
                "expected_definition_version", "expected_publication_revision",
                "expected_stewardship_epoch", "expected_action_revision"}
            assert body["action"] == "ESCALATE" and body["arguments"] == {"level": 2}
            assert body["case_key"] == key and body["binding_id"] == binding["binding_id"]
            assert body["policy_revision"] == "s1-idle-feasibility"
            assert body["expected_policy_digest"] == binding["policy_digest"]
            assert body["expected_evidence_basis_digest"] == prior["evidence_basis_digest"][2:]
            for field in ("review_version", "definition_version", "publication_revision",
                          "stewardship_epoch", "action_revision"):
                assert body["expected_" + field] == prior[field], (key, field, body)
            assert body["evaluation_ref"].startswith("pgreact:")
            assert body["work_ref"].startswith("pgreact:")
            assert request["request_key"] == attempt["request_key"] == receipt["request_key"]
            assert request["request_digest"] == attempt["request_digest"] == receipt["request_digest"]
            assert request["lifecycle_generation"] == 1 and request["consequence_identity"] == "escalate_level_2"
            assert attempt["receipt_id"] == receipt["receipt_id"]
            assert attempt["outcome"] == "APPLIED_CONTROL" and attempt["reason_code"] == "CONTROL_APPLIED"
            assert attempt["episode_id"] in work_ids
            assert attempt["attempt_no"] == 1

        inspections = json.loads(sql(
            "SELECT COALESCE(jsonb_agg(to_jsonb(i) ORDER BY i.case_key),'[]') "
            "FROM pgreact_mdm.delivery_inspection_v1 i "
            "WHERE i.policy_revision='s1-idle-feasibility' AND i.action='ESCALATE'"))
        assert {row["case_key"] for row in inspections} == set(selected), inspections
        cases_by_key = {row["case_key"]: row for row in actual["cases"]}
        receipts_by_key = {row["case_key"]: row for row in received}
        for inspection in inspections:
            key = inspection["case_key"]
            case_row = cases_by_key[key]
            receipt = receipts_by_key[key]
            attempt = attempts[key]
            assert {
                "policy_revision": inspection["policy_revision"],
                "policy_digest": inspection["policy_digest"],
                "binding_version": inspection["binding_version"],
                "action": inspection["action"],
                "delivery_outcome": inspection["delivery_outcome"],
                "delivery_reason_code": inspection["delivery_reason_code"],
                "mdm_receipt_id": inspection["mdm_receipt_id"],
                "mdm_outcome": inspection["mdm_outcome"],
                "mdm_reason_code": inspection["mdm_reason_code"],
                "current_case_status": inspection["current_case_status"],
                "current_due_at": timestamp(inspection["current_due_at"]).isoformat(),
                "requested_due_at": inspection["requested_due_at"],
                "requested_escalation_level": inspection["requested_escalation_level"],
                "applied_escalation_level": inspection["applied_escalation_level"],
                "current_escalation_level": inspection["current_escalation_level"],
                "current_manual_assignment_protected": inspection["current_manual_assignment_protected"],
                "current_pending_stewardship": inspection["current_pending_stewardship"],
            } == {
                "policy_revision": "s1-idle-feasibility",
                "policy_digest": binding["policy_digest"],
                "binding_version": binding["binding_version"],
                "action": "ESCALATE",
                "delivery_outcome": attempt["outcome"],
                "delivery_reason_code": attempt["reason_code"],
                "mdm_receipt_id": receipt["receipt_id"],
                "mdm_outcome": receipt["outcome"],
                "mdm_reason_code": receipt["reason_code"],
                "current_case_status": "open",
                "current_due_at": selected[key].isoformat(),
                "requested_due_at": None,
                "requested_escalation_level": 2,
                "applied_escalation_level": 2,
                "current_escalation_level": 2,
                "current_manual_assignment_protected": case_row["manual_assignment_protected"],
                "current_pending_stewardship": False,
            }, inspection

        settings = json.loads(sql(
            "SELECT jsonb_object_agg(name,setting) FROM pg_settings WHERE name IN "
            "('pg_react.poll_interval_ms','pg_react.batch_size','pg_react.max_pending_jobs')"))
        assert settings["pg_react.batch_size"] == "1", settings
        assert int(settings["pg_react.batch_size"]) <= claim_limit, (
            "managed batch exceeds operational max_claims", settings, claim_limit)
        first_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
        heartbeat = timestamp(first_status["process"]["heartbeat_at"])
        limit = time.monotonic() + 35
        while time.monotonic() < limit:
            later = json.loads(sql("SELECT pgreact_api.managed_status()"))
            current = later.get("process") or {}
            if current.get("state") == "ready" and current.get("heartbeat_at") and (
                    timestamp(current["heartbeat_at"]) > heartbeat + datetime.timedelta(seconds=2)):
                break
            time.sleep(0.2)
        else:
            raise AssertionError("managed worker did not continue through later backlog-drain cycles")
        assert json.loads(sql(state_query)) == actual, "later managed cycles changed complete two-case vectors"
        post_drain_outage_start = time.monotonic()
        command("docker", "restart", container)
        post_drain_startup_deadline = post_drain_outage_start + 120
        final_status = None
        next_postmaster = None
        while time.monotonic() < post_drain_startup_deadline:
            ready = subprocess.run(["docker", "exec", container, "pg_isready", "-U", "postgres"],
                                   capture_output=True, timeout=15)
            if ready.returncode:
                time.sleep(0.2)
                continue
            next_postmaster = timestamp(sql("SELECT pg_postmaster_start_time()"))
            if next_postmaster > new_postmaster:
                break
            time.sleep(0.2)
        else:
            raise AssertionError("post-drain restart did not start PostgreSQL within 120 seconds")
        post_drain_outage_seconds = time.monotonic() - post_drain_outage_start
        assert 0 < post_drain_outage_seconds <= 120, post_drain_outage_seconds
        post_drain_recovery_start = time.monotonic()
        post_drain_activation = reconcile_after_restart()
        limit = post_drain_recovery_start + 180
        while time.monotonic() < limit:
            final_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            process = final_status.get("process") or {}
            if (process.get("state") == "ready" and process.get("heartbeat_at")
                    and timestamp(process["heartbeat_at"]) > timestamp(current["heartbeat_at"])):
                break
            time.sleep(0.2)
        else:
            raise AssertionError({"error": "post-drain restart did not resume managed worker",
                                  "status": final_status})
        post_restart_first = timestamp(final_status["process"]["heartbeat_at"])
        limit = post_drain_recovery_start + 180
        while time.monotonic() < limit:
            final_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            process = final_status.get("process") or {}
            if (process.get("state") == "ready" and process.get("heartbeat_at")
                    and timestamp(process["heartbeat_at"]) > post_restart_first
                    + datetime.timedelta(seconds=2)):
                break
            time.sleep(0.2)
        else:
            raise AssertionError("post-drain worker stopped advancing after cold restart")
        assert json.loads(sql(state_query)) == actual, "post-restart replay mutated two-case vectors"
        observations["multi_outage"] = {
            "stopped_at": stopped_at.isoformat(),
            "due_at": {str(k): t.isoformat() for k, t in sorted(selected.items())},
            "restart_requested_at": restarted_at.isoformat(),
            "outage_seconds": outage_seconds,
            "recovery_seconds_through_two_receipts": drain_elapsed_seconds,
            "post_drain_outage_seconds": post_drain_outage_seconds,
            "post_drain_recovery_seconds": time.monotonic() - post_drain_recovery_start,
            "explicit_outage_activation": outage_activation,
            "explicit_post_drain_activation": post_drain_activation,
            "new_postmaster": new_postmaster.isoformat(),
            "post_drain_restart": next_postmaster.isoformat(),
            "configured_limits": settings,
            "two_case_drain_seconds": drain_elapsed_seconds,
            "observed_receipt_progress": receipt_progress,
            "per_cycle_claim_bound": observations["installed_cycle_claim_bound"],
            "observed_counter_intervals": observed_counter_intervals,
            "two_receipts": received,
            "before": before_state,
            "after": actual,
            "exact": True,
            "no_replay_across_cycles_and_restart": True}
        observations["checks"].append({
            "name": "two-case-real-outage-drain-and-no-replay", "result": "passed"})
        observations["entry_decision"] = "FOCUSED_TWO_CASE_OUTAGE_QUALIFIED"
        print("PASS: two real overdue MDM cases drained after outage with batch_size=1 and no replay", flush=True)

    try:
        observations["react_revision"] = command("git", "-C", str(root), "rev-parse", "HEAD").strip()
        observations["source_sha256"] = {
            str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(set(root.glob("src/*.rs")) | set(root.glob("integrations/pg-mdm/sql/*.sql")) |
                               set((root / "tests/integrations/pg-mdm/time").glob("*")) |
                               {root / "sql/pg_react--0.46.1.sql",
                                root / "sql/pg_react--0.46.0--0.46.1.sql",
                                root / "integrations/pg-mdm/bounded_refresh_producer.py",
                                root / "integrations/pg-mdm/retention_guard_monitor.py",
                                root / "pg_react.control"})
            if path.is_file()
        }
        observations["image_id"] = command("docker", "image", "inspect", image,
                                           "--format", "{{.Id}}").strip()
        observations["image_labels"] = json.loads(command(
            "docker", "image", "inspect", image, "--format", "{{json .Config.Labels}}"))
        observations["image_architecture"] = command(
            "docker", "image", "inspect", image, "--format", "{{.Architecture}}").strip()
        observations["host_architecture_cpus_memory"] = command(
            "docker", "info", "--format", "{{.Architecture}} {{.NCPU}} {{.MemTotal}}").strip()
        worker_settings = (["-c", "pg_react.databases=s1_idle",
                           "-c", "pg_react.worker_role=mdm_s1_runtime"]
                          if statement_time_retry else [])
        platform_args = ["--platform", "linux/" + observations["image_architecture"]]
        binding_lock_mounts = ([
            "--volume", str(root / "sql/pg_react--0.46.1.sql") +
            ":/usr/share/postgresql/18/extension/pg_react--0.46.1.sql:ro",
            "--volume", str(root / "sql/pg_react--0.46.0--0.46.1.sql") +
            ":/usr/share/postgresql/18/extension/pg_react--0.46.0--0.46.1.sql:ro",
        ] if binding_ddl_lock or logical_restore or managed_fairness or claimed_work else [])
        network_args = (["--network", "bridge", "--add-host", "host.docker.internal:host-gateway",
                         "--publish", "127.0.0.1::5432"] if claimed_work_transport_loss or bounded_producer
                        else ["--network", "none"])
        command("docker", "run", *platform_args, "--detach", "--name", container, *network_args,
                "--env", "POSTGRES_HOST_AUTH_METHOD=trust", "--volume", str(root) + ":/work:ro",
                *binding_lock_mounts,
                image, "postgres", "-c", "shared_preload_libraries=" +
                ("pg_trickle,pg_react" if compatibility_only or temporal_limit or dispatcher_recovery or binding_ddl_lock or managed_admission_32 or managed_fairness else "pg_trickle,pg_mdm,pg_react"),
                "-c", "pg_react.batch_size=" + str(configured_batch_size),
                "-c", "pg_react.poll_interval_ms=" + str(profile["poll_interval_ms"]),
                *worker_settings,
                "-c", "pg_trickle.enabled=off", "-c", "pg_trickle.cdc_mode=trigger",
                "-c", "pg_trickle.differential_max_change_ratio=1.0",
                "-c", "default_transaction_isolation=read committed")
        created = True
        for _ in range(60):
            result = subprocess.run(["docker", "exec", container, "pg_isready", "-U", "postgres"],
                                    capture_output=True)
            if result.returncode == 0 and "PostgreSQL init process complete" in command("docker", "logs", container):
                break
            time.sleep(1)
        else:
            raise RuntimeError("PostgreSQL readiness exceeded 60 seconds")
        if binding_ddl_lock:
            database_results = {}
            for database, upgrade in (("s1_binding_lock_fresh", False),
                                      ("s1_binding_lock_upgrade", True)):
                command("docker", "exec", container, "createdb", "-U", "postgres", database)
                if upgrade:
                    sql("CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react VERSION '0.46.0'; "
                        "ALTER EXTENSION pg_react UPDATE TO '0.46.1'", database)
                else:
                    sql("CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react VERSION '0.46.1'",
                        database)
                database_results[database] = binding_lock_probe(database)
            observations["binding_ddl_lock_regression"] = {
                "fresh_install": database_results["s1_binding_lock_fresh"],
                "upgrade_0_46_0_to_0_46_1": database_results["s1_binding_lock_upgrade"],
                "candidate_sql_sha256": hashlib.sha256(
                    (root / "sql/current/binding-ddl-lock.sql").read_bytes()).hexdigest(),
                "result": "passed",
            }
            observations["checks"].append({
                "name": "temp-relation-ddl-skips-coordinator-lock-persistent-ddl-retains-it",
                "result": "passed"})
            observations["entry_decision"] = "FOCUSED_BINDING_DDL_LOCK_REGRESSION"
            print("PASS: nested temp relation DDL bypasses coordinator lock while persistent DDL waits on fresh and upgrade installs", flush=True)
            return
        if temporal_limit:
            command("docker", "exec", container, "createdb", "-U", "postgres", "s1_temporal_limit")
            sql("CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react VERSION '0.46.1'",
                "s1_temporal_limit")
            fixture("temporal-limit-fresh", "/work/tests/integrations/pg-mdm/time/temporal-limit.sql",
                    "s1_temporal_limit")
            command("docker", "exec", container, "createdb", "-U", "postgres", "s1_temporal_limit_upgrade")
            sql("CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react VERSION '0.46.0'; "
                "ALTER EXTENSION pg_react UPDATE TO '0.46.1'", "s1_temporal_limit_upgrade")
            fixture("temporal-limit-upgrade", "/work/tests/integrations/pg-mdm/time/temporal-limit.sql",
                    "s1_temporal_limit_upgrade")
            observations["entry_decision"] = "FOCUSED_TEMPORAL_LIMIT_REGRESSION"
            return
        if dispatcher_recovery:
            command("docker", "exec", container, "createdb", "-U", "postgres", "s1_dispatcher_fresh")
            sql("CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react VERSION '0.46.1'",
                "s1_dispatcher_fresh")
            fixture("dispatcher-recovery-fresh",
                    "/work/tests/integrations/pg-mdm/time/dispatcher-recovery.sql", "s1_dispatcher_fresh")
            command("docker", "exec", container, "createdb", "-U", "postgres", "s1_dispatcher_upgrade")
            sql("CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react VERSION '0.46.0'; "
                "ALTER EXTENSION pg_react UPDATE TO '0.46.1'", "s1_dispatcher_upgrade")
            fixture("dispatcher-recovery-upgrade",
                    "/work/tests/integrations/pg-mdm/time/dispatcher-recovery.sql", "s1_dispatcher_upgrade")
            observations["entry_decision"] = "FOCUSED_DISPATCHER_RECOVERY_REGRESSION"
            return
        if history_retention:
            fixture("autonomous-bootstrap", "/work/tests/integrations/pg-mdm/time/autonomous-bootstrap.sql", "postgres")
            assert sql("SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_roles "
                       "WHERE rolname='mdm_retention_guard_owner')", "postgres") == "f"
            role_bootstrap_output = command(
                "docker", "exec", container, "psql", "-XAtq", "-U", "postgres",
                "-d", "postgres", "-v", "ON_ERROR_STOP=1",
                "-f", "/work/integrations/pg-mdm/sql/retention-guard-role.sql").strip()
            assert role_bootstrap_output == "", role_bootstrap_output
            guard_owner_role = json.loads(sql(
                "SELECT jsonb_build_object('role',rolname,'can_login',rolcanlogin,"
                "'superuser',rolsuper,'createdb',rolcreatedb,'createrole',rolcreaterole,"
                "'inherit',rolinherit,'replication',rolreplication,'bypass_rls',rolbypassrls,"
                "'has_role_memberships',EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members "
                "WHERE roleid=guard_owner.oid OR member=guard_owner.oid),"
                "'has_direct_schema_create_or_ownership',EXISTS (SELECT 1 FROM pg_catalog.pg_namespace schema_row "
                "WHERE schema_row.nspowner=guard_owner.oid OR EXISTS (SELECT 1 FROM pg_catalog.aclexplode(COALESCE("
                "schema_row.nspacl,pg_catalog.acldefault('n',schema_row.nspowner))) schema_acl "
                "WHERE schema_acl.grantee=guard_owner.oid AND schema_acl.privilege_type='CREATE'))) "
                "FROM pg_catalog.pg_roles guard_owner "
                "WHERE rolname='mdm_retention_guard_owner'", "postgres"))
            expected_guard_owner_role = {
                "role": "mdm_retention_guard_owner", "can_login": False,
                "superuser": False, "createdb": False, "createrole": False,
                "inherit": False, "replication": False, "bypass_rls": False,
                "has_role_memberships": False, "has_direct_schema_create_or_ownership": False}
            assert guard_owner_role == expected_guard_owner_role, guard_owner_role
            observations["guard_owner_pre_restore_provisioning"] = {
                "role_absent_before_script": True,
                "role_after_script": guard_owner_role,
                "result": "passed"}
            observations["checks"].append({
                "name": "isolated-retention-guard-owner-preprovisioning",
                "result": "passed"})
            print("PASS: isolated retention guard owner can be provisioned before database restore",
                  flush=True)
            fixture("idle-setup", "/work/tests/integrations/pg-mdm/time/idle.sql", "s1_idle",
                    ("-v", "multi=false", "-v", "VERBOSITY=verbose"))
            observations["fixture_sha256"] = command("docker", "exec", container, "sha256sum",
                "/work/tests/integrations/pg-mdm/time/history-retention.sql",
                "/work/integrations/pg-mdm/sql/request-store.sql",
                "/work/integrations/pg-mdm/sql/intent-worker.sql",
                "/work/integrations/pg-mdm/sql/retention-guard-health.sql",
                "/work/integrations/pg-mdm/sql/retention-guard-role.sql",
                "/work/integrations/pg-mdm/sql/retention-guard.sql",
                "/usr/lib/postgresql/18/lib/pg_react.so",
                "/usr/lib/postgresql/18/lib/pg_mdm.so",
                "/usr/lib/postgresql/18/lib/pg_trickle.so").splitlines()
            result = fixture("history-retention",
                "/work/tests/integrations/pg-mdm/time/history-retention.sql", "s1_idle",
                ("-v", "VERBOSITY=verbose"))
            disabled_health, missing_health, health_result, tampered_health, pass_result = result.splitlines()
            disabled_health = json.loads(disabled_health)
            missing_health = json.loads(missing_health)
            actual_health = json.loads(health_result)
            tampered_health = json.loads(tampered_health)
            assert disabled_health == expected_history_guard_health(False), disabled_health
            assert missing_health == expected_history_guard_health(False), missing_health
            assert actual_health == expected_history_guard_health(True), actual_health
            assert tampered_health == expected_history_guard_health(True, False), tampered_health
            monitor_healthy = run_retention_guard_monitor_contract(root, actual_health, 0, "")
            monitor_tampered = run_retention_guard_monitor_contract(
                root, tampered_health, 1,
                "retention-guard health failed: expected all eighteen named guards healthy\n")
            assert pass_result == (
                "PASS: managed history blocks marker tampering and early DDL, and health detects a replaced "
                "policy retention function; "
                "both DROP OWNED attempts preserve state; aged pruning succeeds"), pass_result
            observations["history_retention"] = {
                "runtime_regression": "passed",
                "guard_health": {
                    "disabled_event_trigger": disabled_health,
                    "missing_event_trigger": missing_health,
                    "tampered_policy_function": tampered_health,
                    "restored": actual_health},
                "scope": "fresh 0.46.1 install with pinned MDM and the current adapter SQL",
                "marker_guards": {
                    "tables": ["pgreact_mdm.policy_intent_bindings",
                              "pgreact_mdm.intent_case_identities"],
                    "blocked_mutations": ["DELETE", "rekeying UPDATE", "TRUNCATE"],
                    "binding_configuration_update": "enabled update succeeded and rollback preserved exact state",
                    "exact_state_preserved_on_block": True},
                "ddl_guard": {
                    "blocked_operation": "DROP OWNED BY mdm_retention_ddl_owner CASCADE",
                    "sqlstate": "55000",
                    "exact_state_preserved": True},
                "guard_function_owner_replacement": {
                    "attempted_by": "non-superuser helper owner",
                    "blocked_operation": "CREATE OR REPLACE FUNCTION pgreact_mdm.enforce_history_guard_ddl()",
                    "sqlstate": "42501",
                    "message": "permission denied for schema pgreact_mdm",
                    "exact_state_preserved": True},
                "guard_function_owner_drop": {
                    "owner": "mdm_retention_guard_owner",
                    "owner_isolated": True,
                    "blocked_operation": "DROP FUNCTION pgreact_mdm.enforce_history_guard_ddl() CASCADE",
                    "sqlstate": "42501",
                    "message": "must be owner of function pgreact_mdm.enforce_history_guard_ddl",
                    "exact_state_preserved": True},
                "superuser_function_body_replacement": {
                    "function": "pgreact_mdm.guard_policy_history_retention()",
                    "health_detected_source_mismatch": tampered_health["all_healthy"] is False,
                    "function_health": next(
                        guard["healthy"] for guard in tampered_health["guards"]
                        if guard["guard"] == "function/pgreact_mdm.guard_policy_history_retention()")},
                "monitor_cli_contract": {
                    "healthy_report": monitor_healthy,
                    "tampered_report": monitor_tampered,
                    "scope": "real monitor process with fixture-backed psql output"},
                "helper_owned_drop_owned": {
                    "blocked_operation": "DROP OWNED BY mdm_helper_owner CASCADE",
                    "sqlstate": "2BP01",
                    "message": "cannot drop function mdm_admin.verify_installation() because extension pg_mdm requires it",
                    "blocking_layer": "PostgreSQL extension dependency; the DDL guard was not reached",
                    "exact_state_preserved": True},
                "limitations": ["superuser can remove the event guard",
                                "coherent backup retention and 90-day restore"]}
            observations["entry_decision"] = "FOCUSED_HISTORY_RETENTION_REGRESSION"
            observations["remaining_gates"] = [
                "superuser event-trigger policy", "coherent backup and matching-binary retention across 90 days"]
            observations["checks"].append({
                "name": "retention-health-query-detects-superuser-function-body-replacement",
                "result": "passed"})
            observations["checks"].append({
                "name": "retention-monitor-accepts-healthy-health-report",
                "result": "passed"})
            observations["checks"].append({
                "name": "retention-monitor-fails-closed-on-unhealthy-health-report",
                "result": "passed"})
            print("PASS: managed history blocks marker tampering and early DDL, the health query detects a replaced "
                  "policy retention function; "
                  "the monitor accepts healthy and rejects unhealthy reports; both DROP OWNED attempts "
                  "preserve state; aged pruning succeeds",
                  flush=True)
            return
        if statement_time_retry:
            fixture("autonomous-bootstrap", "/work/tests/integrations/pg-mdm/time/autonomous-bootstrap.sql", "postgres")
            fixture("idle-setup", "/work/tests/integrations/pg-mdm/time/idle.sql", "s1_idle",
                    ("-v", "multi=false", "-v", "VERBOSITY=verbose"))
            observations["fixture_sha256"] = command("docker", "exec", container, "sha256sum",
                "/usr/lib/postgresql/18/lib/pg_react.so", "/usr/lib/postgresql/18/lib/pg_mdm.so",
                "/usr/lib/postgresql/18/lib/pg_trickle.so").splitlines()
            fixture("statement-time-retry-setup",
                    "/work/tests/integrations/pg-mdm/time/statement-time-retry.sql", "s1_idle")
            state_query = (
                "SELECT jsonb_build_object("
                "'sampled_at',clock_timestamp(),'metadata',to_jsonb(metadata),"
                "'case',to_jsonb(case_row),"
                "'agenda',(SELECT to_jsonb(agenda) FROM pgreact_internal.agenda agenda "
                "WHERE agenda.episode_id=metadata.episode_id),"
                "'executions',COALESCE((SELECT jsonb_agg(to_jsonb(execution) ORDER BY execution.attempt_no) "
                "FROM pgreact_internal.executions execution WHERE execution.episode_id=metadata.episode_id),'[]'),"
                "'requests',COALESCE((SELECT jsonb_agg(to_jsonb(request) ORDER BY request.work_ref) "
                "FROM pgreact_mdm.intent_requests request WHERE request.work_ref=metadata.work_ref),'[]'),"
                "'receipts',COALESCE((SELECT jsonb_agg(to_jsonb(receipt) ORDER BY receipt.created_at,receipt.receipt_id) "
                "FROM mdm_steward.policy_receipts_v1 receipt "
                "WHERE receipt.request_body->>'work_ref'=metadata.work_ref),'[]'),"
                "'intent_attempts',COALESCE((SELECT jsonb_agg(to_jsonb(attempt) ORDER BY attempt.attempt_no) "
                "FROM pgreact_mdm.intent_attempts attempt WHERE attempt.work_ref=metadata.work_ref),'[]'),"
                "'inspection',(SELECT to_jsonb(inspection) FROM pgreact_mdm.delivery_inspection_v1 inspection "
                "WHERE inspection.work_ref=metadata.work_ref),"
                "'work',(SELECT to_jsonb(work) FROM pgreact.work work "
                "WHERE work.work_id=metadata.episode_id::text),"
                "'match',(SELECT to_jsonb(match) FROM pgreact.matches match "
                "WHERE match.rule_version_id=metadata.rule_version_id "
                "AND match.semantic_key=metadata.case_key LIMIT 1)) "
                "FROM s1_statement_retry.metadata metadata "
                "JOIN mdm_steward.policy_cases_v1 case_row USING(case_key)")

            def statement_retry_state():
                return json.loads(sql(state_query, "s1_idle"))

            limit = time.monotonic() + 60
            first_retry = None
            while time.monotonic() < limit:
                current = statement_retry_state()
                agenda = current.get("agenda") or {}
                if agenda.get("state") == "RETRY_WAIT":
                    first_retry = current
                    break
                time.sleep(0.05)
            if first_retry is None:
                observations["statement_retry_failure_state"] = current
                raise AssertionError("managed stale-statement callback did not enter RETRY_WAIT")
            meta = first_retry["metadata"]
            before_case = meta["case_before"]
            first_execution, = first_retry["executions"]
            due_at = timestamp(meta["due_at"])
            assert first_execution["status"] == "RETRY_WAIT", first_execution
            assert first_execution["error_code"] == "40001", first_execution
            assert first_execution["error_message"] == "due escalation requires a fresh statement", first_execution
            assert timestamp(first_execution["started_at"]) < due_at <= timestamp(first_execution["finished_at"]), first_execution
            assert first_retry["case"] == before_case
            assert first_retry["requests"] == first_retry["receipts"] == first_retry["intent_attempts"] == []
            assert first_retry["inspection"] is None
            assert first_retry["agenda"]["attempt_count"] == 1
            assert first_retry["agenda"]["max_attempts"] == 5
            assert first_retry["agenda"]["retry_initial_seconds"] == 1
            assert first_retry["agenda"]["retry_multiplier"] == 2
            assert first_retry["agenda"]["retry_max_seconds"] == 30
            assert timestamp(first_retry["agenda"]["available_at"]) > timestamp(first_retry["sampled_at"])
            observations["statement_retry_first_attempt"] = first_retry
            observations["checks"].append({"name": "stale-statement-enters-bounded-retry-without-mdm-write",
                                            "result": "passed"})
            print("PASS: managed stale-statement callback crossed due time and entered RETRY_WAIT without an MDM write",
                  flush=True)

            limit = time.monotonic() + 60
            final_retry = None
            while time.monotonic() < limit:
                current = statement_retry_state()
                executions = current["executions"]
                if (len(executions) == 2 and executions[-1]["status"] == "COMPLETED"
                        and len(current["receipts"]) == 1):
                    final_retry = current
                    break
                time.sleep(0.1)
            if final_retry is None:
                observations["statement_retry_failure_state"] = current
                raise AssertionError("fresh-statement managed retry did not produce exactly one receipt")

            meta = final_retry["metadata"]
            before_case = meta["case_before"]
            executions = final_retry["executions"]
            second_execution = executions[1]
            assert [execution["status"] + ":" + str(execution["attempt_no"]) + ":"
                    + (execution.get("error_code") or "") for execution in executions] == [
                        "RETRY_WAIT:1:40001", "COMPLETED:2:"], executions
            assert timestamp(second_execution["started_at"]) >= timestamp(meta["due_at"]), second_execution
            assert len(final_retry["requests"]) == len(final_retry["receipts"]) == 1, final_retry
            assert len(final_retry["intent_attempts"]) == 1, final_retry
            assert final_retry["match"]["generation"] == 1, final_retry["match"]
            case_key = meta["case_key"]
            work_ref = meta["work_ref"]
            request, = final_retry["requests"]
            receipt, = final_retry["receipts"]
            attempt, = final_retry["intent_attempts"]
            activation_ref = "pgreact:" + final_retry["match"]["activation_id"]
            request_body = {
                "action": "ESCALATE", "arguments": {"level": 2}, "case_key": case_key,
                "binding_id": meta["binding_id"], "policy_revision": meta["policy_revision"],
                "expected_policy_digest": meta["policy_digest"],
                "expected_evidence_basis_digest": before_case["evidence_basis_digest"][2:],
                "evaluation_ref": activation_ref, "work_ref": work_ref,
                **{"expected_" + key: before_case[key] for key in (
                    "action_revision", "review_version", "definition_version",
                    "publication_revision", "stewardship_epoch")}}
            request_key = sql(
                "SELECT encode(pgreact_mdm.intent_request_key('" + meta["binding_id"] + "'::uuid,'"
                + meta["policy_revision"] + "'," + str(case_key) + ","
                + str(final_retry["match"]["generation"]) + ","
                + str(before_case["action_revision"]) + ",'escalate_level_2',2),'hex')", "s1_idle")
            request_body_sql = json.dumps(request_body, separators=(",", ":")).replace("'", "''")
            request_digest = sql(
                "SELECT encode(pgreact_mdm.intent_request_digest('" + request_body_sql + "'::jsonb),'hex')",
                "s1_idle")
            request_key = "\\x" + request_key
            request_digest = "\\x" + request_digest
            assert request == {
                "binding_id": meta["binding_id"], "request_key": request_key,
                "request_digest": request_digest, "request_body": request_body,
                "work_ref": work_ref, "policy_revision": meta["policy_revision"],
                "case_key": case_key, "lifecycle_generation": final_retry["match"]["generation"],
                "action_revision": before_case["action_revision"],
                "consequence_identity": "escalate_level_2", "escalation_level": 2,
                "first_episode_id": meta["episode_id"], "created_at": request["created_at"]}, request

            expected_control = {
                "assigned_queue": before_case["assigned_queue"],
                "due_at": before_case["due_at"].replace("T", " ").removesuffix(":00"),
                "escalation_level": 2,
                "manual_assignment_protected": before_case["manual_assignment_protected"]}
            assert receipt == {
                "receipt_id": receipt["receipt_id"], "created_at": receipt["created_at"],
                "actor": "pgreact_mdm_worker", "selected_role_name": "pgreact_mdm_worker",
                "session_role_name": "mdm_s1_runtime", "action": "ESCALATE",
                "outcome": "APPLIED_CONTROL", "reason_code": "CONTROL_APPLIED",
                "control": expected_control, "case_key": case_key,
                "binding_id": meta["binding_id"], "binding_version": meta["binding_version"],
                "action_revision": before_case["action_revision"] + 1,
                "resulting_publication_revision": None, "request_body": request_body,
                "request_key": request_key, "request_digest": request_digest}, receipt
            assert attempt == {
                "episode_id": meta["episode_id"], "attempt_no": 2,
                "binding_id": meta["binding_id"], "request_key": request_key,
                "request_digest": request_digest, "request_body": request_body,
                "work_ref": work_ref, "receipt_id": receipt["receipt_id"],
                "outcome": "APPLIED_CONTROL", "reason_code": "CONTROL_APPLIED",
                "case_key": case_key, "action_revision": before_case["action_revision"] + 1,
                "control": expected_control, "resulting_publication_revision": None,
                "attempted_at": attempt["attempted_at"]}, attempt

            expected_case = dict(before_case)
            expected_case.update(escalation_level=2, action_revision=before_case["action_revision"] + 1)
            assert final_retry["case"] == expected_case
            assert final_retry["inspection"] == {
                "work_ref": work_ref, "binding_id": meta["binding_id"],
                "binding_version": meta["binding_version"], "entity_name": "policy_qualification",
                "policy_revision": meta["policy_revision"], "policy_digest": meta["policy_digest"],
                "case_key": case_key, "lifecycle_generation": final_retry["match"]["generation"],
                "action_revision": before_case["action_revision"], "action": "ESCALATE",
                "requested_at": request["created_at"], "delivery_outcome": "APPLIED_CONTROL",
                "delivery_reason_code": "CONTROL_APPLIED", "attempted_at": attempt["attempted_at"],
                "mdm_receipt_id": receipt["receipt_id"], "mdm_outcome": "APPLIED_CONTROL",
                "mdm_reason_code": "CONTROL_APPLIED", "resulting_publication_revision": None,
                "current_case_status": final_retry["case"]["status"],
                "current_publication_revision": before_case["publication_revision"],
                "remediation_state": "NONE", "remediation_reason_code": None, "remediation_at": None,
                "requested_due_at": None, "current_due_at": final_retry["case"]["due_at"],
                "requested_escalation_level": 2, "applied_escalation_level": 2,
                "current_escalation_level": 2,
                "current_manual_assignment_protected": before_case["manual_assignment_protected"],
                "current_pending_stewardship": final_retry["case"]["pending_stewardship"]}
            assert final_retry["work"]["state"] == "COMPLETED", final_retry["work"]
            observations["statement_retry_final"] = final_retry
            observations["checks"].append({"name": "fresh-managed-statement-retry-applies-exactly-once",
                                            "result": "passed"})
            observations["entry_decision"] = "FOCUSED_STATEMENT_TIME_RETRY"
            print("PASS: fresh managed-statement retry produced one exact APPLIED_CONTROL receipt",
                  flush=True)
            return
        command("docker", "exec", container, "createdb", "-U", "postgres", "s1_compatibility")
        sql("CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react", "s1_compatibility")
        observations["installed_profile"] = json.loads(sql(
            "SELECT jsonb_build_object('postgresql',version(),'extensions',"
            "(SELECT jsonb_object_agg(extname,extversion) FROM pg_extension),"
            "'settings',(SELECT jsonb_object_agg(name,setting) FROM pg_settings WHERE name IN "
            "('pg_react.batch_size','pg_react.poll_interval_ms','pg_trickle.enabled','pg_trickle.cdc_mode','pg_trickle.differential_max_change_ratio',"
            "'default_transaction_isolation','transaction_isolation','shared_preload_libraries')),"
            "'compatibility',pgreact_internal.pgtrickle_integration_status())", "s1_compatibility"))
        fixture("compatibility", "/work/tests/integrations/pg-mdm/time/compatibility.sql", "s1_compatibility")
        command("docker", "exec", container, "createdb", "-U", "postgres", "s1_compatibility_upgrade")
        sql("CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react VERSION '0.46.0'", "s1_compatibility_upgrade")
        if producer_outage_only:
            sql("ALTER EXTENSION pg_react UPDATE TO '0.46.1'", "s1_compatibility_upgrade")
            observations["checks"].append({"name": "upgrade-state-only-temporal-reconciliation",
                "result": "not_run", "reason": "outside producer-outage-only scope"})
        else:
            upgrade_output = fixture("populated-core-upgrade-rollback",
                "/work/tests/integrations/pg-mdm/time/upgrade-rollback.sql",
                "s1_compatibility_upgrade")
            expected_upgrade_output = (
                "PASS: upgrade STATE_ONLY temporal recovery preserved its pending deadline and cleared the barrier")
            assert expected_upgrade_output in upgrade_output.splitlines(), upgrade_output
            observations["checks"].append({"name": "upgrade-state-only-temporal-reconciliation",
                                           "result": "passed"})
            print("PASS: upgrade STATE_ONLY temporal reconciliation", flush=True)
            observations["core_upgrade_rollback"] = json.loads(sql(
                "SELECT result FROM upgrade_rollback.evidence", "s1_compatibility_upgrade"))
        callable_query = (
            "SELECT jsonb_agg(jsonb_build_object('identity',p.oid::regprocedure::text,"
            "'owner',pg_get_userbyid(p.proowner),'acl',p.proacl::text,"
            "'definition',pg_get_functiondef(p.oid)) ORDER BY p.oid::regprocedure::text) "
            "FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace "
            "WHERE n.nspname IN ('pgreact_internal','pgreact_api','pgreact') "
            "AND p.proname IN ('pgtrickle_capability_report','pgtrickle_integration_status',"
            "'require_pgtrickle_runtime','pgtrickle_health_findings','assert_m0_compatibility',"
            "'managed_cycle','doctor','health_check')")
        fresh = json.loads(sql(callable_query, "s1_compatibility"))
        upgraded = json.loads(sql(callable_query, "s1_compatibility_upgrade"))
        assert fresh == upgraded, "fresh/adjacent-upgrade compatibility definitions or privileges differ"
        assert json.loads(sql("SELECT pgreact_internal.pgtrickle_integration_status()",
            "s1_compatibility_upgrade")) == observations["installed_profile"]["compatibility"]
        observations["compatibility_callables"] = fresh
        observations["checks"].append({"name": "fresh-adjacent-upgrade-compatibility", "result": "passed"})
        print("PASS: fresh/adjacent-upgrade compatibility and callable privileges", flush=True)
        if compatibility_only and not managed_admission_32:
            observations["entry_decision"] = "ADMISSION_ONLY"
            return
        if managed_admission_32:
            command("docker", "exec", container, "createdb", "-U", "postgres", "s1_cycle_bound32")
            sql("CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react", "s1_cycle_bound32")
            fixture("managed-cycle-admission-bound-32",
                    "/work/tests/integrations/pg-mdm/time/managed-admission-batch32.sql",
                    "s1_cycle_bound32")
            settings = observations["installed_profile"]["settings"]
            assert settings["pg_react.batch_size"] == "32", settings
            observations["managed_cycle_admission"] = json.loads(sql(
                "SELECT jsonb_agg(to_jsonb(e) ORDER BY e.cycle) FROM cycle_bound32.evidence AS e",
                "s1_cycle_bound32"))
            assert len(observations["managed_cycle_admission"]) == 3
            observations["entry_decision"] = "FOCUSED_MANAGED_CYCLE_ADMISSION_32"
            print("PASS: managed cycle processed exactly 32 due items and preserved the 33rd", flush=True)
            return
        if managed_fairness:
            cycle_runs = []
            concurrent_runs = []
            for database, upgrade in (("s1_managed_fairness", False),
                                      ("s1_managed_fairness_upgrade", True)):
                command("docker", "exec", container, "createdb", "-U", "postgres", database)
                if upgrade:
                    sql("CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react VERSION '0.46.0'; "
                        "ALTER EXTENSION pg_react UPDATE TO '0.46.1'", database)
                else:
                    sql("CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react", database)
                fixture_output = fixture("managed-cycle-fairness-" + ("upgrade" if upgrade else "fresh"),
                    "/work/tests/integrations/pg-mdm/time/managed-fairness.sql", database)
                assert "managed-cycle fairness state vectors passed" in fixture_output.splitlines(), fixture_output
                assert "global claim conflict fairness state vector passed" in fixture_output.splitlines(), fixture_output
                assert "concurrent global claim fairness state vector passed" in fixture_output.splitlines(), fixture_output
                cycle_runs.append(json.loads(sql(
                    "SELECT jsonb_agg(to_jsonb(e) ORDER BY e.cycle) FROM managed_fairness.evidence e",
                    database)))
                concurrent_runs.append(json.loads(sql(
                    "SELECT jsonb_build_object('claims',claims,'state',state) "
                    "FROM managed_fairness.concurrent_evidence", database)))
            assert cycle_runs[0] == cycle_runs[1], "fresh/upgrade managed-cycle fairness vectors differ"
            assert concurrent_runs[0]["state"] == concurrent_runs[1]["state"], \
                "fresh/upgrade concurrent global claim state vectors differ"
            assert len(cycle_runs[0]) == 2 and observations["installed_profile"]["settings"]["pg_react.batch_size"] == "1"
            observations["managed_cycle_fairness"] = cycle_runs[0]
            observations["concurrent_global_claim_order"] = concurrent_runs
            observations["checks"].append({"name": "fresh-and-upgrade-managed-cycle-fairness",
                                           "result": "passed"})
            observations["entry_decision"] = "FOCUSED_MANAGED_CYCLE_FAIRNESS"
            observations["checks"].append({"name": "fresh-and-upgrade-global-claim-conflict-fairness",
                                           "result": "passed"})
            observations["checks"].append({"name": "fresh-and-upgrade-concurrent-global-claim-fairness",
                                           "result": "passed"})
            print("PASS: managed-cycle ordering, concurrent workers and global conflict-aware claim ordering passed", flush=True)
            return
        if logical_restore or clean_clone or direct_clone:
            observations["fixture_sha256"] = command("docker", "exec", container, "sha256sum",
                "/usr/lib/postgresql/18/lib/pg_react.so", "/usr/lib/postgresql/18/lib/pg_mdm.so",
                "/usr/lib/postgresql/18/lib/pg_trickle.so").splitlines()
            fixture("autonomous-bootstrap", "/work/tests/integrations/pg-mdm/time/autonomous-bootstrap.sql", "postgres")
            sql("INSERT INTO public.policy_qualification_source VALUES "
                "(5,'Clone One','clone-one@example.test',statement_timestamp()),"
                "(6,'Clone One','clone-pair@example.test',statement_timestamp()),"
                "(7,'Clone Two','clone-two@example.test',statement_timestamp()),"
                "(8,'Clone Two','clone-pair@example.test',statement_timestamp())")
            sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
                "SELECT mdm.refresh('policy_qualification','ALLOW')")
            assert sql("SELECT count(*) FROM mdm_steward.policy_cases_v1 WHERE status='open'") == "2"
            fixture("idle-setup", "/work/tests/integrations/pg-mdm/time/idle.sql", "s1_idle",
                    ("-v", "multi=true", "-v", "VERBOSITY=verbose"))
            qualify_pending_recovery()
            return
        if autonomous_recurrence or claimed_work or bounded_producer:
            if claimed_work:
                from claimed_work import qualify
            else:
                from autonomous_recurrence import qualify
            transport_loss_target_port = None
            if claimed_work_transport_loss:
                published = command("docker", "port", container, "5432/tcp").strip()
                transport_loss_target_port = int(published.rsplit(":", 1)[1])
            observations["fixture_sha256"] = command("docker", "exec", container, "sha256sum",
                "/usr/lib/postgresql/18/lib/pg_react.so", "/usr/lib/postgresql/18/lib/pg_mdm.so",
                "/usr/lib/postgresql/18/lib/pg_trickle.so").splitlines()
            fixture("autonomous-bootstrap", "/work/tests/integrations/pg-mdm/time/autonomous-bootstrap.sql", "postgres")
            fixture("idle-setup", "/work/tests/integrations/pg-mdm/time/idle.sql", "s1_idle",
                    ("-v", "multi=false", "-v", "VERBOSITY=verbose"))
            if bounded_producer:
                qualify_bounded_producer(sql, command, container, root, output, observations,
                    installed_wheel=bounded_producer_wheel, outage_only=producer_outage_only,
                    wheel_file=bounded_producer_wheel_file)
            elif claimed_work:
                qualify(sql, command, fixture, container, observations,
                        postmaster_crash=claimed_work_crash,
                        transport_loss_target_port=transport_loss_target_port)
            else:
                qualify(sql, command, fixture, container, observations, timestamp)
            return
        command("docker", "exec", container, "createdb", "-U", "postgres", "s1_cycle_bound")
        sql("CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react", "s1_cycle_bound")
        fixture("managed-cycle-admission-bound",
                "/work/tests/integrations/pg-mdm/time/managed-admission.sql", "s1_cycle_bound")
        observations["managed_cycle_admission"] = json.loads(sql(
            "SELECT jsonb_agg(to_jsonb(e) ORDER BY cycle) FROM cycle_bound.evidence e", "s1_cycle_bound"))
        fixture("refresh-permission", "/work/tests/integrations/pg-mdm/time/refresh-permission.sql", "s1_compatibility")
        producer_archive = (observations["image_labels"] or {}).get("pg_trickle.source_archive_sha256")
        mdm_bootstrap_file = current_mdm_bootstrap_fixture()
        fixture("mdm-bootstrap", mdm_bootstrap_file, "postgres",
                ("-v", "producer_artifact_sha256=" + producer_archive) if producer_archive else ())
        fixture("mdm-policy-fixtures", "/tests/e2e_policy.sql")
        observations["mdm_entry_cases"] = json.loads(sql(
            "SELECT jsonb_agg(to_jsonb(c) ORDER BY case_key) FROM mdm_steward.policy_cases_v1 c", "foundation"))
        observations["mdm_entry_receipts"] = json.loads(sql(
            "SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id) FROM mdm_steward.policy_receipts_v1 r", "foundation"))
        observations["mdm_fixture_cases"] = observations["mdm_entry_cases"]
        fixture("idle-seed", "/work/tests/integrations/pg-mdm/time/idle-seed.sql")
        observations["mdm_entry_cases"] = json.loads(sql(
            "SELECT jsonb_agg(to_jsonb(c) ORDER BY case_key) FROM mdm_steward.policy_cases_v1 c", "foundation"))
        observations["fixture_sha256"] = command("docker", "exec", container, "sha256sum",
            "/tests/e2e.sql", mdm_bootstrap_file, "/tests/e2e_policy.sql",
            "/usr/lib/postgresql/18/lib/pg_react.so", "/usr/lib/postgresql/18/lib/pg_mdm.so",
            "/usr/lib/postgresql/18/lib/pg_trickle.so").splitlines()
        sql("ALTER DATABASE foundation ALLOW_CONNECTIONS false", "postgres")
        sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='foundation'", "postgres")
        try:
            command("docker", "exec", container, "createdb", "-U", "postgres",
                    "--template=foundation", "s1_idle")
            command("docker", "exec", container, "createdb", "-U", "postgres",
                    "--template=foundation", "s1_mdm_upgrade")
        finally:
            sql("ALTER DATABASE foundation ALLOW_CONNECTIONS true", "postgres")
        sql("CREATE EXTENSION pg_react VERSION '0.46.0'", "s1_mdm_upgrade")
        fixture("populated-mdm-upgrade-rollback", "/work/tests/integrations/pg-mdm/time/upgrade-rollback.sql",
                "s1_mdm_upgrade")
        observations["mdm_upgrade_rollback"] = json.loads(sql(
            "SELECT result FROM upgrade_rollback.evidence", "s1_mdm_upgrade"))
        command("docker", "exec", container, "dropdb", "-U", "postgres", "--force", "s1_mdm_upgrade")
        # Recover only the disposable clone's capture identity, before future-deadline setup.
        observations["clone_capture_recovery"] = sql("SELECT pgtrickle.recover_capture_instance()")
        assert cases() == observations["mdm_entry_cases"], "clone recovery changed MDM cases"
        assert json.loads(sql("SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id) "
                              "FROM mdm_steward.policy_receipts_v1 r")) == observations["mdm_entry_receipts"], "clone recovery changed MDM receipts"
        for database in ("foundation", "s1_idle"):
            version = "0.46.0" if maintenance and database == "foundation" else "0.46.1"
            sql("CREATE EXTENSION pg_react VERSION '{}'".format(version), database)
        entry = json.loads(sql("SELECT pgreact_api.managed_cycle()"))
        observations["runtime_entry"] = entry
        if entry["state"] == "blocked":
            for name in ("v0.47", "v0.48-codec"):
                fixture(name, "/work/tests/integrations/pg-mdm/" + name + ".sql", "postgres")
            fixture("runtime-gate", "/work/tests/integrations/pg-mdm/time/runtime-gate.sql", "s1_idle")
            observations["runtime_gate"] = json.loads(sql("SELECT vector FROM s1_runtime_gate.evidence"))
            before = cases()
            receipts_before = json.loads(sql(
                "SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id) FROM mdm_steward.policy_receipts_v1 r"))
            source_before = json.loads(sql(
                "SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM public.policy_qualification_source s"))
            temporal_source = json.loads(sql("SELECT jsonb_agg(to_jsonb(s) ORDER BY case_key) FROM s1_runtime_gate.source s"))
            deadline = timestamp(temporal_source[0]["due_at"])
            for role in ("author", "operator", "worker", "reader", "advanced_reader"):
                sql("CREATE ROLE s1_gate_" + role + " LOGIN NOSUPERUSER NOBYPASSRLS")
            sql("SELECT pgreact_api.configure_roles('s1_gate_author','s1_gate_operator',"
                "'s1_gate_worker','s1_gate_reader','s1_gate_advanced_reader')")
            sql("ALTER SYSTEM SET pg_react.databases = 's1_idle'")
            sql("ALTER SYSTEM SET pg_react.worker_role = 's1_gate_worker'")
            command("docker", "restart", container)
            end = time.monotonic() + 30
            while time.monotonic() < end:
                ready = subprocess.run(["docker", "exec", container, "pg_isready", "-U", "postgres"], capture_output=True)
                if not ready.returncode:
                    status = json.loads(sql("SELECT pgreact_api.managed_status()"))
                    process = status.get("process") or {}
                    if process.get("state") == "error" and timestamp(process["heartbeat_at"]) >= deadline:
                        break
                time.sleep(0.2)
            else:
                raise AssertionError("managed worker did not expose the gate after the idle deadline within 30 seconds")
            assert process["detail"] == "pg_trickle compatibility blocked: " + sql(
                "SELECT (vector #> '{cycle,compatibility}')::text FROM s1_runtime_gate.evidence"), status
            assert {key: value for key, value in status.items() if key != "process"} == {
                "contract_version": 5, "database": "s1_idle", "configured": True}, status
            assert {key: value for key, value in process.items() if key not in
                    ("pid", "started_at", "heartbeat_at", "detail")} == {
                "state": "error", "protocol": 2, "pending_jobs": 0, "processed_jobs": 0}, process
            assert sql("SELECT usename FROM pg_stat_activity WHERE pid=" + str(process["pid"])) == "s1_gate_worker"
            assert cases() == before
            assert json.loads(sql("SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id) "
                                  "FROM mdm_steward.policy_receipts_v1 r")) == receipts_before
            assert json.loads(sql("SELECT jsonb_agg(to_jsonb(s) ORDER BY id) "
                                  "FROM public.policy_qualification_source s")) == source_before
            assert json.loads(sql("SELECT jsonb_agg(to_jsonb(s) ORDER BY case_key) "
                                  "FROM s1_runtime_gate.source s")) == temporal_source
            public_state = json.loads(sql("SELECT jsonb_build_object("
                "'rules',(SELECT COALESCE(jsonb_agg(to_jsonb(r)),'[]') FROM pgreact.rules r),"
                "'work',(SELECT COALESCE(jsonb_agg(to_jsonb(w)),'[]') FROM pgreact.work w),"
                "'attempts',(SELECT COALESCE(jsonb_agg(to_jsonb(a)),'[]') FROM pgreact.attempts a))"))
            assert public_state == {"rules": [], "work": [], "attempts": []}, public_state
            observations.update(entry_decision="STOP", managed_status=status, public_state=public_state,
                cases_before=before, cases_actual=cases(), receipts=receipts_before,
                business_source=source_before, temporal_source=temporal_source, idle_case_delivered=False,
                stop_reason="The MDM-qualified pg_trickle 0.108.3 producer is rejected by React's exact-0.108.0 admission guard; public temporal registration and managed dispatch are unavailable on this joint profile.",
                conditional_work_not_performed=["managed escalation implementation", "idle MDM delivery acceptance",
                    "bounded progression/recovery/concurrency acceptance", "numeric operating envelope"])
            observations["checks"].append({"name": "managed-runtime-compatibility-stop", "result": "confirmed"})
            print("STOP: public registration and actual managed worker reject the MDM-qualified producer; no control or receipt changes", flush=True)
            return
        sql("CREATE EXTENSION IF NOT EXISTS pg_trickle; CREATE EXTENSION IF NOT EXISTS pg_react", "postgres")
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
                "/work/tests/integrations/pg-mdm/v0.48-admission.sh", "s1_missing_mdm", "current")
        observations["checks"].append({"name": "missing-mdm-admission", "result": "passed"})
        command("docker", "exec", container, "createdb", "-U", "postgres", "s1_boundary")
        sql("CREATE EXTENSION pg_trickle; CREATE EXTENSION pg_react", "s1_boundary")
        fixture("sample-boundaries", "/work/tests/integrations/pg-mdm/time/boundaries.sql", "s1_boundary")
        fixture("idle-setup", "/work/tests/integrations/pg-mdm/time/idle.sql", "s1_idle",
                ("-v", "multi=" + str(multi_outage or pending_recovery or clean_clone).lower(), "-v", "VERBOSITY=verbose"))
        observations["role_membership_matrix"] = qualify_role_membership_matrix(sql)
        observations["checks"].append({"name": "role-membership-matrix", "result": "passed"})
        print("PASS: exact runner, worker, runtime and recovery role membership matrix", flush=True)
        if pending_recovery or clean_clone:
            qualify_pending_recovery()
            return
        observations["registered_s1_rules"] = json.loads(sql(
            "SELECT COALESCE(jsonb_agg(jsonb_build_object('rule_name',r.rule_name,'rule_id',r.rule_id,"
            "'rule_version_id',v.rule_version_id,'match_name',v.match_name) ORDER BY r.rule_name),'[]') "
            "FROM pgreact_internal.rules r JOIN pgreact_internal.rule_versions v USING(rule_id) "
            "WHERE r.rule_name IN ('s1-callback-failure','s1-future-idle')"))
        observations["callback_failure_rule_ids"] = json.loads(sql(
            "SELECT COALESCE(jsonb_agg(to_jsonb(f) ORDER BY rule_id),'[]') "
            "FROM s1_audit.callback_failure_rules f"))
        assert [row["rule_name"] for row in observations["registered_s1_rules"]] == [
            "s1-callback-failure", "s1-future-idle"], observations["registered_s1_rules"]
        assert len(observations["callback_failure_rule_ids"]) == 1, observations["callback_failure_rule_ids"]
        assert observations["callback_failure_rule_ids"][0]["rule_id"] == next(
            row["rule_id"] for row in observations["registered_s1_rules"]
            if row["rule_name"] == "s1-callback-failure")
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
        if multi_outage:
            qualify_two_case_outage(before, source, temporal_source)
            return
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
        outage_before = None
        if outage_mode:
            # A genuine PostgreSQL outage starts before the *future* deadline,
            # remains down while that deadline passes, and ends only after it.
            # This is not a manual clock input, source update or worker tick.
            outage_postmaster_before = timestamp(sql("SELECT pg_postmaster_start_time()"))
            outage_before = json.loads(sql(
                "SELECT jsonb_build_object("
                "'cases',(SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY case_key),'[]') FROM mdm_steward.policy_cases_v1 c),"
                "'receipts',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id),'[]') FROM mdm_steward.policy_receipts_v1 r),"
                "'requests',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id,request_key),'[]') FROM pgreact_mdm.intent_requests r),"
                "'attempts',(SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY episode_id,attempt_no),'[]') FROM pgreact_mdm.intent_attempts a),"
                "'work',(SELECT COALESCE(jsonb_agg(to_jsonb(w) ORDER BY work_id),'[]') FROM pgreact.work w),"
                "'business',(SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY id),'[]') FROM public.policy_qualification_source s),"
                "'technical',(SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY case_key),'[]') FROM s1_audit.source s))"))
            assert outage_before["cases"] == before
            assert outage_before["business"] == source
            assert outage_before["technical"] == temporal_source
            assert not [r for r in outage_before["receipts"]
                        if r["request_body"].get("policy_revision") == "s1-idle-feasibility"]
            command("docker", "stop", "-t", "10", container)
            stopped_at = datetime.datetime.now(datetime.timezone.utc)
            assert stopped_at < deadline, {
                "error": "PostgreSQL did not stop before the case was due",
                "stopped_at": stopped_at.isoformat(), "deadline": deadline.isoformat()}
            assert command("docker", "inspect", "-f", "{{.State.Running}}", container).strip() == "false"
            # Wait for the due boundary while PostgreSQL is completely stopped.
            # This sleep is a controlled outage stimulus, not the evidence of
            # delivery; the later real worker receipt and complete vectors are.
            while datetime.datetime.now(datetime.timezone.utc) <= deadline + datetime.timedelta(seconds=2):
                time.sleep(0.2)
            resumed_at = datetime.datetime.now(datetime.timezone.utc)
            assert resumed_at > deadline
            command("docker", "start", container)
            observations["outage_across_deadline"] = {
                "postmaster_before": outage_postmaster_before.isoformat(),
                "stopped_at": stopped_at.isoformat(),
                "deadline_at": deadline.isoformat(),
                "resume_requested_at": resumed_at.isoformat(),
                "complete_state_before": outage_before,
            }
        else:
            command("docker", "restart", container)
        command("docker", "exec", container, "sh", "-c",
                "until pg_isready -U postgres >/dev/null 2>&1; do sleep 0.2; done")
        if sql("SELECT to_regprocedure('mdm_internal.policy_runtime_epoch()') IS NOT NULL") == "t":
            activation_deadline = time.monotonic() + 30
            while time.monotonic() < activation_deadline:
                status = json.loads(sql("SELECT pgreact_api.managed_status()"))
                process = status.get("process") or {}
                if process.get("state") == "error" and process.get("detail") == "MDM activation required":
                    break
                time.sleep(0.2)
            else:
                raise AssertionError("managed worker did not block for post-restart activation")
            assert cases() == before
            assert json.loads(sql("SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id) "
                                  "FROM mdm_steward.policy_receipts_v1 r")) == observations["mdm_entry_receipts"]
            runtime = json.loads(sql("SELECT jsonb_build_object('binding_id',b.binding_id,'runtime_version',r.runtime_version) "
                "FROM pgreact_mdm.policy_intent_bindings b JOIN mdm_internal.policy_binding_runtime r USING(binding_id) "
                "WHERE b.enabled AND b.policy_revision='s1-idle-feasibility'"))
            observations["post_restart_activation"] = {"blocked_status": status, "runtime_before": runtime}
            observations["post_restart_activation"]["runtime_after"] = int(sql(
                "SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
                "SELECT pgreact_mdm.reconcile_intent_binding('{}'::uuid,{})".format(
                    runtime["binding_id"], runtime["runtime_version"])))
            assert observations["post_restart_activation"]["runtime_after"] == runtime["runtime_version"] + 1
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
                         "WHERE name='s1-future-idle' AND status='FAILED' "
                         "AND error_message <> 'injected registered S1 callback failure')")
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
        if outage_mode:
            postmaster_after = timestamp(sql("SELECT pg_postmaster_start_time()"))
            assert postmaster_after > outage_postmaster_before and postmaster_after > deadline
            assert delivered_at >= postmaster_after >= resumed_at
            observations["outage_across_deadline"].update({
                "postmaster_after": postmaster_after.isoformat(),
                "delivered_at": delivered_at.isoformat(),
                "one_case_caught_up": True,
            })
            observations["checks"].append({
                "name": "outage-deadline-catchup-single-case", "result": "passed"})
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
        attempt_projection = [{k: v for k, v in row.items() if k not in
                               ("execution_id", "episode_id", "started_at", "finished_at")}
                              for row in attempts]
        completed_attempt = {"attempt_no": 1, "worker_id": worker, "status": "COMPLETED",
            "error_message": None, "error_code": None, "event_kind": "ACTIVATE",
            "name": "s1-future-idle"}
        retry_attempt = {"attempt_no": 1, "worker_id": worker, "status": "RETRY_WAIT",
            "error_message": "due escalation requires a fresh statement", "error_code": "40001",
            "event_kind": "ACTIVATE", "name": "s1-future-idle"}
        retry_completion = {**completed_attempt, "attempt_no": 2}
        assert attempt_projection in ([completed_attempt], [retry_attempt, retry_completion]), attempts
        completed = attempts[-1]
        assert int(work[0]["work_id"]) == completed["episode_id"] > 0
        assert isinstance(completed["execution_id"], int) and completed["execution_id"] > 0
        started_at = timestamp(completed["started_at"])
        finished_at = timestamp(completed["finished_at"])
        updated_at = timestamp(work[0]["updated_at"])
        if len(attempts) == 2:
            assert timestamp(attempts[0]["started_at"]) < deadline <= started_at, attempts
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
        assert timestamp(receipt["publication_tracking_started_at"]) <= timestamp(receipt["created_at"]), receipt
        expected_receipt = {"receipt_id": receipt["receipt_id"], "created_at": receipt["created_at"],
            "publication_tracking_started_at": receipt["publication_tracking_started_at"],
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
        failure_attempts = []
        end = time.monotonic() + 30
        while time.monotonic() < end:
            failure_attempts = json.loads(sql(
                "SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY execution_id),'[]') "
                "FROM pgreact.attempts a WHERE name='s1-callback-failure'"))
            if failure_attempts:
                break
            time.sleep(0.2)
        observations["all_s1_work"] = json.loads(sql(
            "SELECT COALESCE(jsonb_agg(to_jsonb(w) ORDER BY work_id),'[]') "
            "FROM pgreact.work w WHERE name IN ('s1-callback-failure','s1-future-idle')"))
        observations["all_s1_attempts"] = json.loads(sql(
            "SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY execution_id),'[]') "
            "FROM pgreact.attempts a WHERE name IN ('s1-callback-failure','s1-future-idle')"))
        assert len(failure_attempts) == 1, failure_attempts
        callback_failure = "injected registered S1 callback failure"
        assert {key: failure_attempts[0][key] for key in
                ("attempt_no", "status", "error_code", "error_message", "event_kind", "name")} == {
                    "attempt_no": 1, "status": "FAILED", "error_code": "P0001",
                    "error_message": callback_failure,
                    "event_kind": "ACTIVATE", "name": "s1-callback-failure"}, failure_attempts
        failure_work = json.loads(sql(
            "SELECT COALESCE(jsonb_agg(to_jsonb(w) ORDER BY work_id),'[]') "
            "FROM pgreact.work w WHERE name='s1-callback-failure'"))
        assert [{key: row[key] for key in ("kind", "name", "version", "state", "claimable")}
                for row in failure_work] == [{"kind": "rule", "name": "s1-callback-failure",
                    "version": "1", "state": "FAILED", "claimable": False}], failure_work
        callback_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
        failure_finished = timestamp(failure_attempts[0]["finished_at"])
        after_error_cycle = failure_finished + datetime.timedelta(seconds=1.5)
        end = time.monotonic() + 30
        while time.monotonic() < end:
            callback_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            heartbeat = timestamp(callback_status["process"]["heartbeat_at"])
            if callback_status["process"]["state"] == "ready" and heartbeat > after_error_cycle:
                break
            time.sleep(0.2)
        assert callback_status["process"]["state"] == "ready", callback_status
        assert timestamp(callback_status["process"]["heartbeat_at"]) > after_error_cycle, callback_status
        logs = subprocess.run(["docker", "logs", "--tail", "1000", container],
                              capture_output=True, text=True, timeout=30)
        assert not logs.returncode, logs.stderr
        worker_logs = logs.stdout + logs.stderr
        callback_identity = ("registered-S1 callback entry rule_id=" +
                             observations["callback_failure_rule_ids"][0]["rule_id"] +
                             " session_user=mdm_s1_runtime "
                             "current_user=mdm_s1_runner")
        identity_at = worker_logs.find(callback_identity)
        assert failure_attempts[0]["error_message"] == callback_failure, failure_attempts
        assert identity_at >= 0, worker_logs
        assert "managed worker must begin each cycle as its configured login" not in worker_logs, worker_logs
        assert "managed cycle must restore its configured login role" not in worker_logs, worker_logs
        assert cases() == actual
        assert json.loads(sql("SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id) "
                              "FROM mdm_steward.policy_receipts_v1 r")) == retained_receipts
        assert json.loads(sql("SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id) "
                              "FROM public.policy_qualification_source s")) == source
        assert json.loads(sql("SELECT jsonb_agg(to_jsonb(s) ORDER BY s.case_key) "
                              "FROM s1_audit.source s")) == temporal_source
        observations["callback_error_reset"] = {"managed_worker": True,
            "failed_registered_callback": "s1_audit.deliver(pgreact.activation_context,s1_audit.candidate)",
            "failure_attempts": failure_attempts, "failure_work": failure_work,
            "callback_identity": callback_identity, "post_error_managed_status": callback_status,
            "subsequent_cycle_after_error": True,
            "worker_role_identity": {"actor": receipt["actor"],
                "selected_role_name": receipt["selected_role_name"],
                "session_role_name": receipt["session_role_name"]},
            "public_state_unchanged": True, "transaction_path": "BackgroundWorker::transaction"}
        observations["checks"].append({"name": "callback-error-role-reset", "result": "passed"})
        # A receipt after one idle deadline is not sufficient: the real worker
        # must remain quiescent across *later* managed ticks. Preserve the full
        # durable control, request, receipt and worker-effect vectors while
        # allowing the process heartbeat and observational clock to advance.
        quiescence_sql = (
            "SELECT jsonb_build_object("
            "'cases',(SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY case_key),'[]') "
            "FROM mdm_steward.policy_cases_v1 c),"
            "'mdm_receipts',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id),'[]') "
            "FROM mdm_steward.policy_receipts_v1 r),"
            "'intent_requests',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id,request_key),'[]') "
            "FROM pgreact_mdm.intent_requests r),"
            "'intent_attempts',(SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY episode_id,attempt_no),'[]') "
            "FROM pgreact_mdm.intent_attempts a),"
            "'rule_work',(SELECT COALESCE(jsonb_agg(to_jsonb(w) ORDER BY work_id),'[]') "
            "FROM pgreact.work w WHERE name='s1-future-idle'),"
            "'rule_attempts',(SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY execution_id),'[]') "
            "FROM pgreact.attempts a WHERE name='s1-future-idle'),"
            "'business_source',(SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY id),'[]') "
            "FROM public.policy_qualification_source s),"
            "'technical_source',(SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY case_key),'[]') "
            "FROM s1_audit.source s))"
        )
        def activate_after_restart(name, expected, expect_worker=True):
            command("docker", "exec", container, "sh", "-c",
                    "until pg_isready -U postgres >/dev/null 2>&1; do sleep 0.2; done")
            if sql("SELECT to_regprocedure('mdm_internal.policy_runtime_epoch()') IS NULL") == "t":
                return
            if expect_worker:
                end = time.monotonic() + 30
                while time.monotonic() < end:
                    status = json.loads(sql("SELECT pgreact_api.managed_status()"))
                    process = status.get("process") or {}
                    if process.get("state") == "error" and process.get("detail") == "MDM activation required":
                        break
                    time.sleep(0.2)
                else:
                    raise AssertionError("managed worker did not block for " + name)
            else:
                assert sql("SELECT pgreact_mdm.policy_runtime_ready()") == "f"
                status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            assert json.loads(sql(quiescence_sql)) == expected
            runtime = json.loads(sql("SELECT jsonb_build_object('binding_id',b.binding_id,'runtime_version',r.runtime_version) "
                "FROM pgreact_mdm.policy_intent_bindings b JOIN mdm_internal.policy_binding_runtime r USING(binding_id) "
                "WHERE b.enabled AND b.policy_revision='s1-idle-feasibility' AND r.state='active'"))
            version = int(sql("SET SESSION AUTHORIZATION mdm_legacy_login; SET ROLE mdm_legacy_administrator; "
                "SELECT pgreact_mdm.reconcile_intent_binding('{}'::uuid,{})".format(
                    runtime["binding_id"], runtime["runtime_version"])))
            assert version == runtime["runtime_version"] + 1
            observations.setdefault("restart_activations", {})[name] = {
                "blocked_status": status, "runtime_before": runtime, "runtime_after": version}

        quiescence_before = json.loads(sql(quiescence_sql))
        saved_requests = [
            row for row in quiescence_before["intent_requests"]
            if row["policy_revision"] == "s1-idle-feasibility" and row["case_key"] == case_key
        ]
        saved_attempts = [
            row for row in quiescence_before["intent_attempts"]
            if row["work_ref"] == expected_body["work_ref"]
        ]
        assert len(saved_requests) == len(saved_attempts) == 1, (saved_requests, saved_attempts)
        assert quiescence_before["cases"] == expected
        assert quiescence_before["mdm_receipts"] == retained_receipts
        assert quiescence_before["business_source"] == source
        assert quiescence_before["technical_source"] == temporal_source
        assert quiescence_before["rule_work"] == work
        assert quiescence_before["rule_attempts"] == attempts

        quiet_first_heartbeat = timestamp(callback_status["process"]["heartbeat_at"])
        quiet_deadline = quiet_first_heartbeat + datetime.timedelta(seconds=2)
        end = time.monotonic() + 30
        while time.monotonic() < end:
            later_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            process = later_status.get("process") or {}
            heartbeat_value = process.get("heartbeat_at")
            if process.get("state") == "ready" and heartbeat_value and timestamp(heartbeat_value) > quiet_deadline:
                break
            time.sleep(0.2)
        else:
            raise AssertionError("managed worker did not complete later idle cycles")
        quiescence_after = json.loads(sql(quiescence_sql))
        assert quiescence_after == quiescence_before, {
            "before": quiescence_before, "after": quiescence_after
        }
        observations["later_idle_cycles"] = {
            "first_heartbeat_at": quiet_first_heartbeat.isoformat(),
            "later_heartbeat_at": heartbeat_value,
            "exact_state_before": quiescence_before,
            "exact_state_after": quiescence_after,
            "unchanged": True,
        }
        observations["checks"].append({"name": "post-delivery-idle-quiescence", "result": "passed"})
        # A normal PostgreSQL restart must not turn an already delivered
        # escalation into another control. Validate a *new postmaster* and
        # a resumed ordinary managed worker, not just pg_isready.
        before_restart_postmaster = timestamp(sql("SELECT pg_postmaster_start_time()"))
        before_restart_state = quiescence_after
        before_restart_heartbeat = timestamp(later_status["process"]["heartbeat_at"])
        command("docker", "restart", container)
        activate_after_restart("post_delivery", before_restart_state)
        end = time.monotonic() + 60
        restart_status = None
        restart_postmaster = None
        while time.monotonic() < end:
            ready = subprocess.run(["docker", "exec", container, "pg_isready", "-U", "postgres"],
                                   capture_output=True)
            if ready.returncode:
                time.sleep(0.2)
                continue
            restart_postmaster = timestamp(sql("SELECT pg_postmaster_start_time()"))
            restart_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            process = restart_status.get("process") or {}
            heartbeat = process.get("heartbeat_at")
            if (restart_postmaster > before_restart_postmaster
                    and process.get("state") == "ready" and heartbeat
                    and timestamp(heartbeat) > before_restart_heartbeat):
                break
            time.sleep(0.2)
        else:
            raise AssertionError({
                "error": "managed worker did not resume after a new PostgreSQL postmaster",
                "old_postmaster": before_restart_postmaster.isoformat(),
                "postmaster": str(restart_postmaster), "status": restart_status,
            })
        # Wait for more than one post-restart managed cycle, so a lazy replay
        # is observed before we assert unchanged durable state.
        resumed_heartbeat = timestamp(restart_status["process"]["heartbeat_at"])
        end = time.monotonic() + 30
        while time.monotonic() < end:
            restart_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            process = restart_status.get("process") or {}
            heartbeat = process.get("heartbeat_at")
            if (process.get("state") == "ready" and heartbeat
                    and timestamp(heartbeat) > resumed_heartbeat + datetime.timedelta(seconds=2)):
                break
            time.sleep(0.2)
        else:
            raise AssertionError("managed worker stopped advancing after restart")
        after_restart_state = json.loads(sql(quiescence_sql))
        assert after_restart_state == before_restart_state, {
            "error": "recovered managed worker recreated an already delivered effect",
            "before": before_restart_state, "after": after_restart_state,
        }
        observations["post_delivery_restart"] = {
            "postmaster_before": before_restart_postmaster.isoformat(),
            "postmaster_after": restart_postmaster.isoformat(),
            "heartbeat_before": before_restart_heartbeat.isoformat(),
            "heartbeat_after": heartbeat,
            "exact_state_before": before_restart_state,
            "exact_state_after": after_restart_state,
            "unchanged": True,
        }
        observations["checks"].append({"name": "post-delivery-restart-no-replay", "result": "passed"})
        if outage_mode:
            # This branch already proved the complete canonical MDM receipt,
            # actual action/case/source vector and worker role above. Record
            # the normal proof marker before ending this focused outage run.
            observations["checks"].append({
                "name": "future-idle-mdm-receipt", "result": "passed"})
            # Focused T49.06 proof: this run also checked post-delivery cycles
            # and a second real restart without replay. The ordinary full
            # audit runs separately to retain all later security/MDM vectors.
            observations["entry_decision"] = "FOCUSED_OUTAGE_QUALIFIED"
            return
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
        activate_after_restart("after_rejected_worker", json.loads(sql(quiescence_sql)), expect_worker=False)
        # Separate authority-level regression after the proven worker delivery,
        # restart and privilege tests. This intentionally changes only the
        # MDM case via its authorized human API, then sends two *new* keys
        # through the authenticated worker interface. It does not claim that
        # React emitted those independent work items.
        fixture("human-reduction-crosskey",
                "/work/tests/integrations/pg-mdm/time/human-reduction-crosskey.sql", "s1_idle")
        cross_key = json.loads(sql("SELECT vector FROM s1_cross_key.evidence"))
        assert cross_key["exact"] and len(cross_key["denial_receipts"]) == 2, cross_key
        observations["human_reduction_crosskey"] = cross_key
        observations["cases_after_human_reduction"] = cases()
        observations["receipts_after_human_reduction"] = json.loads(sql(
            "SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id) "
            "FROM mdm_steward.policy_receipts_v1 r"))

        # After the human reduced level 2 -> 1 and MDM retained its two
        # terminal cross-key denials, put the legitimate managed login back in
        # service. A new worker must not manufacture any additional control,
        # receipt, immutable request/attempt, work, or source changes merely
        # because that previously applied level is again visible as next.
        human_quiet_before = json.loads(sql(quiescence_sql))
        assert human_quiet_before["cases"] == observations["cases_after_human_reduction"]
        assert human_quiet_before["mdm_receipts"] == observations["receipts_after_human_reduction"]
        assert human_quiet_before["business_source"] == source
        assert human_quiet_before["technical_source"] == temporal_source
        sql("ALTER SYSTEM SET pg_react.worker_role = 'mdm_s1_runtime'")
        postmaster_before_human = timestamp(sql("SELECT pg_postmaster_start_time()"))
        command("docker", "restart", container)
        activate_after_restart("post_human_reduction", human_quiet_before)
        end = time.monotonic() + 60
        human_worker_status = None
        human_postmaster = None
        while time.monotonic() < end:
            ready = subprocess.run(["docker", "exec", container, "pg_isready", "-U", "postgres"],
                                   capture_output=True)
            if ready.returncode:
                time.sleep(0.2)
                continue
            human_postmaster = timestamp(sql("SELECT pg_postmaster_start_time()"))
            human_worker_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            worker = human_worker_status.get("process") or {}
            if (human_postmaster > postmaster_before_human
                    and worker.get("state") == "ready" and worker.get("heartbeat_at")):
                break
            time.sleep(0.2)
        else:
            raise AssertionError({
                "error": "authenticated managed worker did not resume after human reduction",
                "status": human_worker_status, "postmaster": str(human_postmaster)
            })
        human_heartbeat_first = timestamp(human_worker_status["process"]["heartbeat_at"])
        end = time.monotonic() + 30
        while time.monotonic() < end:
            human_worker_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            worker = human_worker_status.get("process") or {}
            heartbeat = worker.get("heartbeat_at")
            if (worker.get("state") == "ready" and heartbeat
                    and timestamp(heartbeat) > human_heartbeat_first + datetime.timedelta(seconds=3)):
                break
            time.sleep(0.2)
        else:
            raise AssertionError("managed worker did not advance after human reduction")
        human_quiet_after = json.loads(sql(quiescence_sql))
        assert human_quiet_after == human_quiet_before, {
            "error": "human-reduced occurrence generated another durable effect",
            "before": human_quiet_before, "after": human_quiet_after
        }
        observations["post_human_managed_convergence"] = {
            "postmaster": human_postmaster.isoformat(),
            "heartbeat_first": human_heartbeat_first.isoformat(),
            "heartbeat_after": heartbeat,
            "complete_before": human_quiet_before,
            "complete_after": human_quiet_after,
            "unchanged": True,
        }
        observations["checks"].append({"name": "post-human-managed-convergence", "result": "passed"})

        # Two distinct authenticated MDM worker requests must contend for the
        # *same* case-row lock. Hold that row in an independent transaction,
        # prove BOTH callers are waiting on PostgreSQL locks, then release it.
        # This tests concurrency of the MDM authority, not React claim races.
        # Reuse MDM's previously persisted canonical denial body/tokens rather
        # than manufacturing fresh policy or revision values.
        deny_template = cross_key["denial_receipts"][0]
        assert all(row["reason_code"] == "ESCALATION_LEVEL_ALREADY_APPLIED"
                   for row in cross_key["denial_receipts"])
        assert deny_template["request_body"]["case_key"] == case_key
        concurrent_before = json.loads(sql(quiescence_sql))

        def sql_literal(value):
            return "'" + str(value).replace("'", "''") + "'"

        concurrent_requests = {}
        worker_sessions = []
        holder = None
        observed_waits = []
        try:
            holder = subprocess.Popen([
                "docker", "exec", "-i", container, "psql", "-XAtq", "-U", "postgres",
                "-d", "s1_idle", "-v", "ON_ERROR_STOP=1"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True)
            holder.stdin.write(
                "SET application_name = 'react11-case-lock-holder';\n"
                "BEGIN;\n"
                f"SELECT case_key FROM mdm_steward.policy_cases_v1 "
                f"WHERE case_key = {int(case_key)} FOR UPDATE;\n")
            holder.stdin.flush()
            end = time.monotonic() + 20
            while time.monotonic() < end:
                held = sql("SELECT count(*) FROM pg_stat_activity "
                           "WHERE application_name = 'react11-case-lock-holder' "
                           "AND state = 'idle in transaction'")
                if held == "1":
                    break
                if holder.poll() is not None:
                    raise AssertionError("concurrency lock holder exited before case lock")
                time.sleep(0.1)
            else:
                raise AssertionError("concurrency lock holder did not acquire case row")

            for suffix in ("ee", "ef"):
                key_hex = suffix * 32
                body = dict(deny_template["request_body"])
                body["evaluation_ref"] = "concurrent-" + suffix
                body["work_ref"] = "concurrent-work-" + suffix
                concurrent_requests[suffix] = (key_hex, body)
                statement = (
                    "SET application_name = " + sql_literal("react11-worker-" + suffix) + "; "
                    "SET SESSION AUTHORIZATION mdm_s1_runtime; "
                    "SET ROLE pgreact_mdm_worker; "
                    "SELECT row_to_json(result) FROM mdm_steward.submit_policy_intent("
                    + sql_literal(deny_template["binding_id"]) + "::uuid, "
                    + "decode(" + sql_literal(key_hex) + ", 'hex'), "
                    + str(int(case_key)) + ", 'ESCALATE', "
                    + sql_literal(json.dumps(body["arguments"])) + "::jsonb, "
                    + ", ".join(str(int(body[k])) for k in (
                        "expected_review_version", "expected_definition_version",
                        "expected_publication_revision", "expected_stewardship_epoch"))
                    + ", decode(" + sql_literal(body["expected_evidence_basis_digest"]) + ", 'hex'), "
                    + str(int(body["expected_action_revision"])) + ", decode("
                    + sql_literal(body["expected_policy_digest"]) + ", 'hex'), "
                    + ", ".join(sql_literal(body[k]) for k in (
                        "policy_revision", "evaluation_ref", "work_ref"))
                    + ") AS result;"
                )
                worker_sessions.append((suffix, subprocess.Popen([
                    "docker", "exec", container, "psql", "-XAtq", "-U", "postgres",
                    "-d", "s1_idle", "-v", "ON_ERROR_STOP=1", "-c", statement],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)))

            end = time.monotonic() + 25
            while time.monotonic() < end:
                observed_waits = json.loads(sql(
                    "SELECT COALESCE(jsonb_agg(jsonb_build_object("
                    "'app',application_name,'wait',wait_event_type) "
                    "ORDER BY application_name),'[]') "
                    "FROM pg_stat_activity "
                    "WHERE application_name IN ('react11-worker-ee','react11-worker-ef')"))
                if observed_waits == [
                    {"app": "react11-worker-ee", "wait": "Lock"},
                    {"app": "react11-worker-ef", "wait": "Lock"},
                ]:
                    break
                if any(process.poll() is not None for _, process in worker_sessions):
                    raise AssertionError({"error": "concurrent worker exited before lock barrier",
                                          "observed": observed_waits})
                time.sleep(0.1)
            else:
                raise AssertionError({"error": "both requests did not contend on case lock",
                                      "observed": observed_waits})

            holder.stdin.write("COMMIT;\n\\q\n")
            holder.stdin.flush()
            holder_stdout, holder_stderr = holder.communicate(timeout=20)
            assert holder.returncode == 0, (holder_stdout, holder_stderr)
            concurrent_responses = {}
            for suffix, process in worker_sessions:
                stdout, stderr = process.communicate(timeout=30)
                assert process.returncode == 0, {"caller": suffix, "stderr": stderr}
                concurrent_responses[suffix] = json.loads(stdout.strip())
        finally:
            for _, process in worker_sessions:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=10)
            if holder is not None and holder.poll() is None:
                holder.kill()
                holder.communicate(timeout=10)

        concurrent_after = json.loads(sql(quiescence_sql))
        for state_name, before_vector in concurrent_before.items():
            if state_name != "mdm_receipts":
                assert concurrent_after[state_name] == before_vector, {
                    "state": state_name, "before": before_vector,
                    "after": concurrent_after[state_name],
                }
        existing_ids = {r["receipt_id"] for r in concurrent_before["mdm_receipts"]}
        new_receipts = [r for r in concurrent_after["mdm_receipts"]
                        if r["receipt_id"] not in existing_ids]
        assert len(new_receipts) == 2, new_receipts
        assert [r for r in concurrent_after["mdm_receipts"]
                if r["receipt_id"] in existing_ids] == concurrent_before["mdm_receipts"]
        receipt_by_key = {r["request_key"]: r for r in new_receipts}
        assert set(receipt_by_key) == {"\\x" + suffix * 32 for suffix in ("ee", "ef")}
        expected_receipts = []
        for suffix in ("ee", "ef"):
            key_hex, body = concurrent_requests[suffix]
            saved = receipt_by_key["\\x" + key_hex]
            response = concurrent_responses[suffix]
            assert response["receipt_id"] == saved["receipt_id"]
            assert response["outcome"] == "ACTION_DENIED"
            assert response["reason_code"] == "ESCALATION_LEVEL_ALREADY_APPLIED"
            assert response["case_key"] == case_key
            assert response["action_revision"] == body["expected_action_revision"]
            assert response["control"] == saved["control"]
            assert response["resulting_publication_revision"] is None
            uuid.UUID(saved["receipt_id"])
            assert timestamp(saved["created_at"]).tzinfo is not None
            digest = sql("SELECT encode(pgreact_mdm.intent_request_digest("
                         + sql_literal(json.dumps(body)) + "::jsonb),'hex')")
            expected_saved = dict(deny_template)
            expected_saved.update({
                "receipt_id": saved["receipt_id"],
                "created_at": saved["created_at"],
                "request_key": "\\x" + key_hex,
                "request_digest": "\\x" + digest,
                "request_body": body,
            })
            assert saved == expected_saved, {"expected": expected_saved, "actual": saved}
            expected_receipts.append(expected_saved)
        assert concurrent_after["cases"] == human_quiet_before["cases"]
        assert concurrent_after["business_source"] == source
        assert concurrent_after["technical_source"] == temporal_source
        observations["concurrent_cross_key_denials"] = {
            "observed_lock_waits": observed_waits,
            "responses": concurrent_responses,
            "before": concurrent_before,
            "after": concurrent_after,
            "new_exact_receipts": expected_receipts,
        }
        observations["checks"].append({"name": "concurrent-cross-key-denials", "result": "passed"})
        # A subsequent human edit advances only the case action revision.
        # Captured pre-edit tokens must be rejected as stale, while current
        # tokens for the previously automated-applied level must be denied by
        # retained MDM occurrence history. Exact immutable React work and
        # public source vectors are asserted by the SQL fixture.
        fixture("human-stale-after-concurrency",
                "/work/tests/integrations/pg-mdm/time/human-stale-after-concurrency.sql",
                "s1_idle")
        stale_human = json.loads(sql("SELECT vector FROM s1_stale.evidence"))
        assert stale_human["exact"] and stale_human["unchanged_adapter_and_sources"], stale_human
        observations["stale_after_human_edit"] = stale_human
        observations["checks"].append({
            "name": "stale-vs-current-human-token", "result": "passed"
        })

        # Reuse MDM's real resolution/publication recurrence fixture, where
        # the same issue_key was reopened as a different case_key. The original
        # applied-level history must remain scoped to its own occurrence, not
        # block a permitted first level-2 application in the new occurrence.
        # This test invokes the real MDM human/worker APIs: it does not claim
        # React's ordinary managed worker discovered the new case.
        before_recurrence = json.loads(sql(quiescence_sql))
        fixture("recurrence-independent",
                "/work/tests/integrations/pg-mdm/time/recurrence-independent.sql",
                "s1_idle")
        recurrence = json.loads(sql("SELECT vector FROM s1_recurrence.evidence"))
        assert recurrence["exact"] and recurrence["old_receipts_unchanged"], recurrence
        assert recurrence["old_case_key"] != recurrence["new_case_key"], recurrence
        after_recurrence = json.loads(sql(quiescence_sql))
        for category in ("intent_requests", "intent_attempts",
                         "rule_work", "rule_attempts",
                         "business_source", "technical_source"):
            assert after_recurrence[category] == before_recurrence[category], category
        assert len(after_recurrence["mdm_receipts"]) == len(before_recurrence["mdm_receipts"]) + 1
        assert len(after_recurrence["cases"]) == len(before_recurrence["cases"])
        assert all(before == after for before, after in zip(
            before_recurrence["cases"], after_recurrence["cases"])
            if before["case_key"] != recurrence["new_case_key"])
        observations["recurrence_independent"] = recurrence
        observations["checks"].append({
            "name": "recurrence-new-occurrence", "result": "passed"
        })
        # After the real recurrence's authorized MDM control, keep the
        # ordinary managed worker running. Because the enrolled React rule
        # selects a different case_key, a subsequent managed poll must neither
        # replay the new occurrence nor mutate unrelated old cases/sources.
        # This is an observation-only quiescence test, not proof that the
        # React scheduler autonomously enrolls every new MDM occurrence.
        recurrence_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
        process = recurrence_status.get("process") or {}
        assert process.get("state") == "ready" and process.get("heartbeat_at"), recurrence_status
        recurrence_heartbeat = timestamp(process["heartbeat_at"])
        end = time.monotonic() + 35
        observed_status = None
        while time.monotonic() < end:
            observed_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            process = observed_status.get("process") or {}
            observed_heartbeat = process.get("heartbeat_at")
            if (process.get("state") == "ready" and observed_heartbeat
                    and timestamp(observed_heartbeat) >
                    recurrence_heartbeat + datetime.timedelta(seconds=3)):
                break
            time.sleep(0.2)
        else:
            raise AssertionError({
                "error": "managed worker did not complete post-recurrence cycles",
                "initial": recurrence_status, "last": observed_status
            })
        after_recurrence_cycles = json.loads(sql(quiescence_sql))
        assert after_recurrence_cycles == after_recurrence, {
            "error": "post-recurrence managed cycle changed durable state",
            "before": after_recurrence, "after": after_recurrence_cycles
        }
        observations["post_recurrence_worker_quiescence"] = {
            "heartbeat_before": recurrence_heartbeat.isoformat(),
            "heartbeat_after": observed_heartbeat,
            "full_before": after_recurrence,
            "full_after": after_recurrence_cycles,
            "unchanged": True
        }
        observations["checks"].append({
            "name": "post-recurrence-worker-quiescence", "result": "passed"
        })

        # A cold PostgreSQL restart after the genuine recurrence must retain
        # BOTH occurrence populations and the newly applied exact MDM receipt.
        # Observe a different postmaster and multiple resumed managed-worker
        # cycles, then compare the entire durable state, not just counts.
        before_recurrence_restart = json.loads(sql(quiescence_sql))
        old_postmaster = timestamp(sql("SELECT pg_postmaster_start_time()"))
        old_heartbeat = timestamp(observed_heartbeat)
        command("docker", "restart", container)
        activate_after_restart("post_recurrence", before_recurrence_restart)
        restart_end = time.monotonic() + 60
        restarted_status = None
        new_postmaster = None
        while time.monotonic() < restart_end:
            readiness = subprocess.run(
                ["docker", "exec", container, "pg_isready", "-U", "postgres"],
                capture_output=True)
            if readiness.returncode:
                time.sleep(0.2)
                continue
            new_postmaster = timestamp(sql("SELECT pg_postmaster_start_time()"))
            restarted_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            process = restarted_status.get("process") or {}
            heartbeat = process.get("heartbeat_at")
            if (new_postmaster > old_postmaster
                    and process.get("state") == "ready" and heartbeat
                    and timestamp(heartbeat) > old_heartbeat):
                break
            time.sleep(0.2)
        else:
            raise AssertionError({
                "error": "managed worker failed to resume after recurrence restart",
                "old_postmaster": old_postmaster.isoformat(),
                "new_postmaster": str(new_postmaster),
                "status": restarted_status,
            })
        resumed_at = timestamp(restarted_status["process"]["heartbeat_at"])
        restart_end = time.monotonic() + 35
        while time.monotonic() < restart_end:
            restarted_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            process = restarted_status.get("process") or {}
            heartbeat = process.get("heartbeat_at")
            if (process.get("state") == "ready" and heartbeat
                    and timestamp(heartbeat) > resumed_at + datetime.timedelta(seconds=3)):
                break
            time.sleep(0.2)
        else:
            raise AssertionError("managed worker did not complete later cycles after recurrence restart")
        after_recurrence_restart = json.loads(sql(quiescence_sql))
        assert after_recurrence_restart == before_recurrence_restart, {
            "error": "recurrence history or worker effects changed after restart",
            "before": before_recurrence_restart,
            "after": after_recurrence_restart,
        }
        assert any(case["case_key"] == recurrence["old_case_key"]
                   for case in after_recurrence_restart["cases"])
        assert any(case["case_key"] == recurrence["new_case_key"]
                   and case["escalation_level"] == 2
                   for case in after_recurrence_restart["cases"])
        assert sum(r["case_key"] == recurrence["new_case_key"]
                   and r["action"] == "ESCALATE" and r["outcome"] == "APPLIED_CONTROL"
                   for r in after_recurrence_restart["mdm_receipts"]) == 1
        observations["post_recurrence_restart"] = {
            "old_postmaster": old_postmaster.isoformat(),
            "new_postmaster": new_postmaster.isoformat(),
            "first_resumed_heartbeat": resumed_at.isoformat(),
            "later_heartbeat": heartbeat,
            "full_before": before_recurrence_restart,
            "full_after": after_recurrence_restart,
            "unchanged": True,
        }
        observations["checks"].append({
            "name": "post-recurrence-restart-no-replay", "result": "passed"
        })
        # A permitted second level does not imply authorization to move to
        # level 3: enforce the exact active MDM binding's maximum, after the
        # true recurrence and its cold-restart proof. This invokes MDM's
        # authenticated worker entrypoint; it does not synthesize React work.
        fixture("recurrence-maximum",
                "/work/tests/integrations/pg-mdm/time/recurrence-maximum.sql",
                "s1_idle")
        maximum = json.loads(sql("SELECT vector FROM s1_maximum.evidence"))
        assert maximum["exact"] and maximum["state_unchanged"], maximum
        assert maximum["binding_maximum"] == 2, maximum
        assert maximum["case_key"] == recurrence["new_case_key"], maximum
        observations["recurrence_maximum"] = maximum
        observations["checks"].append({
            "name": "recurrence-max-level-denial", "result": "passed"
        })
        # The bound's terminal denial must not create another MDM control
        # when the ordinary managed worker continues to poll. Require
        # observable worker progress rather than sleeping and assuming it.
        max_before = json.loads(sql(quiescence_sql))
        max_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
        max_worker = max_status.get("process") or {}
        assert max_worker.get("state") == "ready" and max_worker.get("heartbeat_at"), max_status
        max_heartbeat = timestamp(max_worker["heartbeat_at"])
        deadline = time.monotonic() + 35
        max_last = None
        while time.monotonic() < deadline:
            max_last = json.loads(sql("SELECT pgreact_api.managed_status()"))
            process = max_last.get("process") or {}
            heartbeat = process.get("heartbeat_at")
            if (process.get("state") == "ready" and heartbeat
                    and timestamp(heartbeat) > max_heartbeat + datetime.timedelta(seconds=3)):
                break
            time.sleep(0.2)
        else:
            raise AssertionError({"error": "worker stalled after maximum-level denial",
                                  "before": max_status, "after": max_last})
        max_after = json.loads(sql(quiescence_sql))
        assert max_after == max_before, {
            "error": "maximum-level denial caused delayed managed effects",
            "before": max_before, "after": max_after,
        }
        assert sum(row["case_key"] == recurrence["new_case_key"]
                   and row["outcome"] == "APPLIED_CONTROL"
                   and row["action"] == "ESCALATE"
                   for row in max_after["mdm_receipts"]) == 1
        assert sum(row["case_key"] == recurrence["new_case_key"]
                   and row["outcome"] == "LIMIT_EXCEEDED"
                   and row["reason_code"] == "ESCALATION_LIMIT"
                   for row in max_after["mdm_receipts"]) == 1
        observations["post_maximum_managed_quiescence"] = {
            "heartbeat_before": max_heartbeat.isoformat(),
            "heartbeat_after": heartbeat,
            "full_before": max_before,
            "full_after": max_after,
            "unchanged": True,
        }
        observations["checks"].append({
            "name": "post-maximum-managed-quiescence", "result": "passed"
        })
        # Recovery after a terminal limit denial: the original applied
        # recurrence receipt and the denied attempt must both survive another
        # postmaster epoch, with no fresh work emitted by the ordinary worker.
        max_restart_before = json.loads(sql(quiescence_sql))
        max_start_before = timestamp(sql("SELECT pg_postmaster_start_time()"))
        max_heartbeat_before = timestamp(heartbeat)
        command("docker", "restart", container)
        activate_after_restart("post_maximum", max_restart_before)
        end = time.monotonic() + 60
        max_restart_status = None
        max_start_after = None
        while time.monotonic() < end:
            ready = subprocess.run(["docker", "exec", container, "pg_isready", "-U", "postgres"],
                                   capture_output=True)
            if ready.returncode:
                time.sleep(0.2)
                continue
            max_start_after = timestamp(sql("SELECT pg_postmaster_start_time()"))
            max_restart_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            proc = max_restart_status.get("process") or {}
            hb = proc.get("heartbeat_at")
            if (max_start_after > max_start_before
                    and proc.get("state") == "ready" and hb
                    and timestamp(hb) > max_heartbeat_before):
                break
            time.sleep(0.2)
        else:
            raise AssertionError({
                "error": "worker unavailable after maximum-denial restart",
                "old_start": max_start_before.isoformat(),
                "new_start": str(max_start_after),
                "status": max_restart_status,
            })
        max_resumed = timestamp(max_restart_status["process"]["heartbeat_at"])
        end = time.monotonic() + 35
        while time.monotonic() < end:
            max_restart_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            proc = max_restart_status.get("process") or {}
            hb = proc.get("heartbeat_at")
            if (proc.get("state") == "ready" and hb
                    and timestamp(hb) > max_resumed + datetime.timedelta(seconds=3)):
                break
            time.sleep(0.2)
        else:
            raise AssertionError("worker did not complete post-denial restart cycles")
        max_restart_after = json.loads(sql(quiescence_sql))
        assert max_restart_after == max_restart_before, {
            "error": "restart replayed or altered terminal maximum denial",
            "before": max_restart_before, "after": max_restart_after,
        }
        assert sum(r["case_key"] == recurrence["new_case_key"]
                   and r["outcome"] == "APPLIED_CONTROL"
                   and r["action"] == "ESCALATE"
                   for r in max_restart_after["mdm_receipts"]) == 1
        assert sum(r["case_key"] == recurrence["new_case_key"]
                   and r["outcome"] == "LIMIT_EXCEEDED"
                   and r["reason_code"] == "ESCALATION_LIMIT"
                   for r in max_restart_after["mdm_receipts"]) == 1
        observations["post_maximum_restart"] = {
            "postmaster_before": max_start_before.isoformat(),
            "postmaster_after": max_start_after.isoformat(),
            "first_resumed_heartbeat": max_resumed.isoformat(),
            "later_heartbeat": hb,
            "full_before": max_restart_before,
            "full_after": max_restart_after,
            "unchanged": True,
        }
        observations["checks"].append({
            "name": "post-maximum-restart-no-replay", "result": "passed"
        })
        # The MDM entity owner explicitly pauses the binding; fresh worker
        # requests must be denied by the MDM pause barrier even if their
        # captured case tokens are current. This runs last to avoid
        # weakening the earlier live-binding coverage.
        fixture("pause-barrier", "/work/tests/integrations/pg-mdm/time/pause-barrier.sql",
                "s1_idle")
        paused = json.loads(sql("SELECT vector FROM s1_pause.evidence"))
        assert paused["exact"] and paused["state_unchanged"], paused
        observations["pause_barrier"] = paused
        observations["checks"].append({
            "name": "authorized-pause-barrier", "result": "passed"
        })
        # The operator-owned paused binding must remain paused after a real
        # PostgreSQL restart, and the worker must not manufacture effects
        # while heartbeat cycles remain fenced pending reconciliation.
        pause_before = json.loads(sql(quiescence_sql))
        pause_binding_before = json.loads(sql(
            "SELECT jsonb_build_object("
            "'bindings',(SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY binding_id),'[]')"
            " FROM pgreact_mdm.policy_intent_bindings b),"
            "'runtime',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id),'[]')"
            " FROM pgreact_mdm.policy_intent_runtime r),"
            "'mdm_runtime',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id),'[]')"
            " FROM mdm_internal.policy_binding_runtime r))"))
        assert all(b["binding_id"] != paused["binding_id"]
                   for b in pause_binding_before["runtime"])
        previous_postmaster = timestamp(sql("SELECT pg_postmaster_start_time()"))
        previous_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
        previous_heartbeat = timestamp(previous_status["process"]["heartbeat_at"])
        pause_requires_activation = sql("SELECT to_regprocedure('mdm_internal.policy_runtime_epoch()') IS NOT NULL") == "t"
        command("docker", "restart", container)
        until = time.monotonic() + 60
        after_postmaster = None
        resumed_status = None
        while time.monotonic() < until:
            probe = subprocess.run(["docker", "exec", container, "pg_isready", "-U", "postgres"],
                                   capture_output=True)
            if probe.returncode:
                time.sleep(0.2)
                continue
            after_postmaster = timestamp(sql("SELECT pg_postmaster_start_time()"))
            resumed_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            process = resumed_status.get("process") or {}
            new_heartbeat = process.get("heartbeat_at")
            expected_pause_state = "error" if pause_requires_activation else "ready"
            if (after_postmaster > previous_postmaster
                    and process.get("state") == expected_pause_state and new_heartbeat
                    and (not pause_requires_activation or process.get("detail") == "MDM activation required")
                    and timestamp(new_heartbeat) > previous_heartbeat):
                break
            time.sleep(0.2)
        else:
            raise AssertionError({
                "error": "managed worker did not resume after operator pause",
                "before": previous_status, "after": resumed_status
            })
        first_resumed = timestamp(new_heartbeat)
        until = time.monotonic() + 35
        while time.monotonic() < until:
            resumed_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            process = resumed_status.get("process") or {}
            new_heartbeat = process.get("heartbeat_at")
            if (process.get("state") == expected_pause_state and new_heartbeat
                    and (not pause_requires_activation or process.get("detail") == "MDM activation required")
                    and timestamp(new_heartbeat) > first_resumed + datetime.timedelta(seconds=3)):
                break
            time.sleep(0.2)
        else:
            raise AssertionError("managed worker did not progress after paused-binding restart")
        pause_after = json.loads(sql(quiescence_sql))
        pause_binding_after = json.loads(sql(
            "SELECT jsonb_build_object("
            "'bindings',(SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY binding_id),'[]')"
            " FROM pgreact_mdm.policy_intent_bindings b),"
            "'runtime',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id),'[]')"
            " FROM pgreact_mdm.policy_intent_runtime r),"
            "'mdm_runtime',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id),'[]')"
            " FROM mdm_internal.policy_binding_runtime r))"))
        assert pause_after == pause_before, {
            "error": "paused binding generated an effect after cold restart",
            "before": pause_before, "after": pause_after
        }
        assert pause_binding_after == pause_binding_before, {
            "error": "binding runtime unexpectedly resumed after restart",
            "before": pause_binding_before, "after": pause_binding_after
        }
        observations["post_pause_restart"] = {
            "postmaster_before": previous_postmaster.isoformat(),
            "postmaster_after": after_postmaster.isoformat(),
            "heartbeat_first": first_resumed.isoformat(),
            "heartbeat_later": new_heartbeat,
            "full_before": pause_before, "full_after": pause_after,
            "binding_before": pause_binding_before, "binding_after": pause_binding_after,
            "unchanged": True,
        }
        observations["checks"].append({
            "name": "paused-binding-restart-no-replay", "result": "passed"
        })

        # Reconcile only after cold-restart durability was established.
        # An old paused request must retain its original BINDING_PAUSED
        # receipt, while a NEW key observes the active binding's maximum.
        resume_before = json.loads(sql(quiescence_sql))
        paused_activation = json.loads(sql(
            "SELECT to_jsonb(m) FROM pgreact.matches m WHERE name='s1-future-idle'"))
        fixture("resume-after-pause",
                "/work/tests/integrations/pg-mdm/time/resume-after-pause.sql", "s1_idle")
        resumed = json.loads(sql("SELECT vector FROM s1_resume.evidence"))
        assert resumed["exact"] and resumed["cases_and_react_unchanged"], resumed
        assert resumed["binding_id"] == paused["binding_id"], resumed
        assert resumed["reactivated_runtime_version"] > resumed["paused_runtime_version"]
        assert resumed["original_paused_receipt_id"] == resumed["replayed_paused_receipt_id"]
        observations["resume_after_pause"] = resumed
        observations["checks"].append({
            "name": "authorized-pause-resume-immutable-receipts", "result": "passed"
        })

        # Runtime removal/reconciliation removes/re-adds selector membership.
        # Its new activation must receive one terminal applied-level denial,
        # preserve every case/source row, then stay quiet on later cycles.
        if not paused_activation["active"]:
            end = time.monotonic() + 35
            while time.monotonic() < end:
                resume_after = json.loads(sql(quiescence_sql))
                new_work = [w for w in resume_after["rule_work"]
                            if w not in resume_before["rule_work"]]
                if new_work and all(w["state"] == "COMPLETED" for w in new_work):
                    break
                time.sleep(0.2)
            else:
                raise AssertionError({"error": "resumed selector activation did not complete",
                                      "state": resume_after})
            resumed_activation = json.loads(sql(
                "SELECT to_jsonb(m) FROM pgreact.matches m WHERE name='s1-future-idle'"))
            assert resumed_activation["active"] and resumed_activation["generation"] == paused_activation["generation"] + 1
            resume_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
            resumed_case = next(c for c in resume_before["cases"] if c["case_key"] == case_key)
            work_row, = new_work
            attempt_row, = [a for a in resume_after["rule_attempts"]
                            if a not in resume_before["rule_attempts"]]
            assert int(work_row["work_id"]) == attempt_row["episode_id"] > 0
            assert attempt_row["execution_id"] > 0
            assert timestamp(attempt_row["started_at"]) <= timestamp(attempt_row["finished_at"]) \
                <= timestamp(work_row["updated_at"])
            expected_work = {"kind": "rule", "name": "s1-future-idle", "version": "1",
                             "state": "COMPLETED", "claimable": False,
                             "work_id": work_row["work_id"], "updated_at": work_row["updated_at"]}
            expected_attempt = {"name": "s1-future-idle", "event_kind": "ACTIVATE",
                "status": "COMPLETED", "attempt_no": 1, "error_code": None, "error_message": None,
                "worker_id": "pg-react-managed/s1_idle/" + str(resume_status["process"]["pid"]),
                **{k: attempt_row[k] for k in ("episode_id", "execution_id", "started_at", "finished_at")}}
            body = {**expected_body,
                "evaluation_ref": "pgreact:" + resumed_activation["activation_id"],
                "work_ref": "pgreact:" + resumed_activation["rule_version_id"] + ":" + work_row["work_id"],
                "expected_evidence_basis_digest": resumed_case["evidence_basis_digest"][2:],
                **{"expected_" + k: resumed_case[k] for k in ("review_version", "definition_version",
                    "publication_revision", "stewardship_epoch", "action_revision")}}
            key = "\\x" + sql("SELECT encode(pgreact_mdm.intent_request_key('{}'::uuid,"
                "'s1-idle-feasibility',{},2,{},'escalate_level_2',2),'hex')".format(
                    binding["binding_id"], int(case_key), int(resumed_case["action_revision"])))
            digest = "\\x" + sql("SELECT encode(pgreact_mdm.intent_request_digest("
                                 + sql_literal(json.dumps(body)) + "::jsonb),'hex')")
            request_row, = [r for r in resume_after["intent_requests"]
                            if r not in resume_before["intent_requests"]]
            intent_row, = [a for a in resume_after["intent_attempts"]
                           if a not in resume_before["intent_attempts"]]
            receipt_row, = [r for r in resume_after["mdm_receipts"] if r["request_key"] == key]
            uuid.UUID(receipt_row["receipt_id"])
            assert timestamp(receipt_row["created_at"]).tzinfo is not None
            for row, field in ((request_row, "created_at"), (intent_row, "attempted_at")):
                assert timestamp(attempt_row["started_at"]) <= timestamp(row[field]) \
                    <= timestamp(attempt_row["finished_at"])
            control = {k: resumed_case[k] for k in
                       ("assigned_queue", "escalation_level", "manual_assignment_protected")}
            control["due_at"] = sql("SELECT due_at::text FROM mdm_steward.policy_cases_v1 "
                                    "WHERE case_key=" + str(int(case_key)))
            expected_denial = {**expected_receipt, "receipt_id": receipt_row["receipt_id"],
                "created_at": receipt_row["created_at"], "outcome": "ACTION_DENIED",
                "reason_code": "ESCALATION_LEVEL_ALREADY_APPLIED", "control": control,
                "action_revision": resumed_case["action_revision"],
                "request_key": key, "request_digest": digest, "request_body": body}
            expected_request = {"binding_id": binding["binding_id"], "request_key": key,
                "request_digest": digest, "request_body": body, "work_ref": body["work_ref"],
                "policy_revision": "s1-idle-feasibility", "case_key": case_key,
                "lifecycle_generation": 2, "action_revision": resumed_case["action_revision"],
                "consequence_identity": "escalate_level_2", "escalation_level": 2,
                "first_episode_id": attempt_row["episode_id"], "created_at": request_row["created_at"]}
            expected_intent = {"episode_id": attempt_row["episode_id"], "attempt_no": 1,
                "binding_id": binding["binding_id"], "request_key": key, "request_digest": digest,
                "request_body": body, "work_ref": body["work_ref"],
                "receipt_id": receipt_row["receipt_id"], "outcome": "ACTION_DENIED",
                "reason_code": "ESCALATION_LEVEL_ALREADY_APPLIED", "case_key": case_key,
                "action_revision": resumed_case["action_revision"], "control": control,
                "resulting_publication_revision": None, "attempted_at": intent_row["attempted_at"]}
            expected_resume = copy.deepcopy(resume_before)
            for category, additions, order in (
                ("rule_work", [expected_work], lambda r: int(r["work_id"])),
                ("rule_attempts", [expected_attempt], lambda r: r["execution_id"]),
                ("intent_requests", [expected_request], lambda r: (r["binding_id"], r["request_key"])),
                ("intent_attempts", [expected_intent], lambda r: (r["episode_id"], r["attempt_no"])),
                ("mdm_receipts", [resumed["new_max_denial_receipt"], expected_denial],
                 lambda r: (timestamp(r["created_at"]), r["receipt_id"]))):
                expected_resume[category] = sorted(expected_resume[category] + additions, key=order)
            assert resume_after == expected_resume, {"expected": expected_resume, "actual": resume_after}
            observations["post_resume_activation"] = {
                "before": resume_before, "expected": expected_resume, "after": resume_after,
                "activation": resumed_activation, "denied_once": True, "controls_unchanged": True}
            observations["checks"].append({"name": "post-resume-exact-denied-activation", "result": "passed"})
        else:
            resume_after = json.loads(sql(quiescence_sql))
            expected_resume = copy.deepcopy(resume_before)
            expected_resume["mdm_receipts"].append(resumed["new_max_denial_receipt"])
            assert resume_after == expected_resume, {"expected": expected_resume, "actual": resume_after}
            observations["post_resume_activation"] = {
                "before": resume_before, "expected": expected_resume, "after": resume_after,
                "activation": paused_activation, "denied_once": False, "controls_unchanged": True}
            observations["checks"].append({"name": "post-resume-membership-preserved", "result": "passed"})
        resumed_quiet_before = json.loads(sql(quiescence_sql))
        resumed_runtime_before = json.loads(sql(
            "SELECT jsonb_build_object("
            "'bindings',(SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY binding_id),'[]')"
            " FROM pgreact_mdm.policy_intent_bindings b),"
            "'runtime',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id),'[]')"
            " FROM pgreact_mdm.policy_intent_runtime r),"
            "'mdm_runtime',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id),'[]')"
            " FROM mdm_internal.policy_binding_runtime r))"))
        assert any(r["binding_id"] == resumed["binding_id"]
                   and r["runtime_version"] == resumed["reactivated_runtime_version"]
                   for r in resumed_runtime_before["runtime"]), resumed_runtime_before
        until = time.monotonic() + 30
        while time.monotonic() < until:
            resumed_worker = json.loads(sql("SELECT pgreact_api.managed_status()"))
            process = resumed_worker.get("process") or {}
            if process.get("state") == "ready" and process.get("heartbeat_at"):
                break
            if process.get("state") == "error" and process.get("detail") != "MDM activation required":
                raise AssertionError(resumed_worker)
            time.sleep(0.2)
        else:
            raise AssertionError({"error": "managed worker did not resume after binding reconciliation",
                                  "status": resumed_worker})
        assert json.loads(sql(quiescence_sql)) == resumed_quiet_before
        start_heartbeat = timestamp(process["heartbeat_at"])
        until = time.monotonic() + 35
        while time.monotonic() < until:
            resumed_worker = json.loads(sql("SELECT pgreact_api.managed_status()"))
            process = resumed_worker.get("process") or {}
            later_heartbeat = process.get("heartbeat_at")
            if (process.get("state") == "ready" and later_heartbeat
                    and timestamp(later_heartbeat) > start_heartbeat + datetime.timedelta(seconds=3)):
                break
            time.sleep(0.2)
        else:
            raise AssertionError({"error": "managed worker stalled after binding reconciliation",
                                  "status": resumed_worker})
        resumed_quiet_after = json.loads(sql(quiescence_sql))
        resumed_runtime_after = json.loads(sql(
            "SELECT jsonb_build_object("
            "'bindings',(SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY binding_id),'[]')"
            " FROM pgreact_mdm.policy_intent_bindings b),"
            "'runtime',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id),'[]')"
            " FROM pgreact_mdm.policy_intent_runtime r),"
            "'mdm_runtime',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id),'[]')"
            " FROM mdm_internal.policy_binding_runtime r))"))
        assert resumed_quiet_after == resumed_quiet_before, {
            "error": "managed cycles after binding resume changed durable state",
            "before": resumed_quiet_before, "after": resumed_quiet_after,
        }
        assert resumed_runtime_after == resumed_runtime_before, {
            "error": "binding state changed on managed cycles after resume",
            "before": resumed_runtime_before, "after": resumed_runtime_after,
        }
        observations["post_resume_managed_quiescence"] = {
            "heartbeat_before": start_heartbeat.isoformat(),
            "heartbeat_after": later_heartbeat,
            "full_before": resumed_quiet_before,
            "full_after": resumed_quiet_after,
            "binding_before": resumed_runtime_before,
            "binding_after": resumed_runtime_after,
            "unchanged": True,
        }
        observations["checks"].append({
            "name": "post-resume-managed-quiescence", "result": "passed"
        })

        # A second operator using the *old* paused runtime version must
        # fail to pause OR resume the now-active binding. MDM's optimistic
        # fence must leave all binding/runtime, case, receipt, React work
        # and business/technical source vectors byte-for-byte unchanged.
        fixture("resume-stale-version",
                "/work/tests/integrations/pg-mdm/time/resume-stale-version.sql",
                "s1_idle")
        stale_version = json.loads(sql("SELECT vector FROM s1_stale_runtime.evidence"))
        assert stale_version["exact"] and stale_version["complete_state_unchanged"], stale_version
        assert stale_version["binding_id"] == resumed["binding_id"]
        assert stale_version["old_version"] == resumed["paused_runtime_version"]
        assert stale_version["active_version"] == resumed["reactivated_runtime_version"]
        assert stale_version["errors"]["both_rejected"], stale_version
        observations["stale_operator_runtime_version"] = stale_version
        observations["checks"].append({
            "name": "stale-operator-runtime-version", "result": "passed"
        })
        # The active binding and the exact rejected stale operator attempts
        # must survive another true PostgreSQL postmaster epoch. Observe
        # multiple resumed managed-worker cycles, then compare complete
        # persisted cases, receipts, runtime binding rows, and React/source
        # work to rule out a delayed replay or binding-state regression.
        final_before = json.loads(sql(quiescence_sql))
        final_binding_before = json.loads(sql(
            "SELECT jsonb_build_object("
            "'bindings',(SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY binding_id),'[]')"
            " FROM pgreact_mdm.policy_intent_bindings b),"
            "'runtime',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id),'[]')"
            " FROM pgreact_mdm.policy_intent_runtime r),"
            "'mdm_runtime',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id),'[]')"
            " FROM mdm_internal.policy_binding_runtime r))"))
        assert any(item["binding_id"] == resumed["binding_id"]
                   and item["runtime_version"] == resumed["reactivated_runtime_version"]
                   for item in final_binding_before["runtime"]), final_binding_before
        final_start = timestamp(sql("SELECT pg_postmaster_start_time()"))
        final_status = json.loads(sql("SELECT pgreact_api.managed_status()"))
        assert final_status["process"]["state"] == "ready", final_status
        final_heartbeat = timestamp(final_status["process"]["heartbeat_at"])
        command("docker", "restart", container)
        activate_after_restart("post_resume", final_before)
        final_binding_activated = json.loads(sql(
            "SELECT jsonb_build_object("
            "'bindings',(SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY binding_id),'[]') FROM pgreact_mdm.policy_intent_bindings b),"
            "'runtime',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id),'[]') FROM pgreact_mdm.policy_intent_runtime r),"
            "'mdm_runtime',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id),'[]') FROM mdm_internal.policy_binding_runtime r))"))
        if "post_resume" in observations.get("restart_activations", {}):
            activation = observations["restart_activations"]["post_resume"]
            assert final_binding_activated["bindings"] == final_binding_before["bindings"]
            for key, changed in (("runtime", {"runtime_version", "activated_at"}),
                                 ("mdm_runtime", {"runtime_version", "activation_epoch", "changed_at"})):
                before_rows, after_rows = final_binding_before[key], final_binding_activated[key]
                assert len(before_rows) == len(after_rows)
                for old, new in zip(before_rows, after_rows):
                    if old["binding_id"] == activation["runtime_before"]["binding_id"]:
                        assert new["runtime_version"] == activation["runtime_after"]
                        assert {k: v for k, v in new.items() if k not in changed} == {k: v for k, v in old.items() if k not in changed}
                    else:
                        assert new == old
        else:
            assert final_binding_activated == final_binding_before
        end = time.monotonic() + 60
        restarted = None
        new_postmaster = None
        while time.monotonic() < end:
            probe = subprocess.run(
                ["docker", "exec", container, "pg_isready", "-U", "postgres"],
                capture_output=True)
            if probe.returncode:
                time.sleep(0.2)
                continue
            new_postmaster = timestamp(sql("SELECT pg_postmaster_start_time()"))
            restarted = json.loads(sql("SELECT pgreact_api.managed_status()"))
            worker = restarted.get("process") or {}
            heartbeat = worker.get("heartbeat_at")
            if (new_postmaster > final_start and worker.get("state") == "ready"
                    and heartbeat and timestamp(heartbeat) > final_heartbeat):
                break
            time.sleep(0.2)
        else:
            raise AssertionError({
                "error": "resumed binding did not recover after restart",
                "postmaster_before": final_start.isoformat(),
                "postmaster_after": str(new_postmaster),
                "status": restarted,
            })
        restart_heartbeat_first = timestamp(restarted["process"]["heartbeat_at"])
        end = time.monotonic() + 35
        while time.monotonic() < end:
            restarted = json.loads(sql("SELECT pgreact_api.managed_status()"))
            worker = restarted.get("process") or {}
            heartbeat = worker.get("heartbeat_at")
            if (worker.get("state") == "ready" and heartbeat
                    and timestamp(heartbeat) > restart_heartbeat_first
                    + datetime.timedelta(seconds=3)):
                break
            time.sleep(0.2)
        else:
            raise AssertionError("resumed binding worker did not complete later restart cycles")
        final_after = json.loads(sql(quiescence_sql))
        final_binding_after = json.loads(sql(
            "SELECT jsonb_build_object("
            "'bindings',(SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY binding_id),'[]')"
            " FROM pgreact_mdm.policy_intent_bindings b),"
            "'runtime',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id),'[]')"
            " FROM pgreact_mdm.policy_intent_runtime r),"
            "'mdm_runtime',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY binding_id),'[]')"
            " FROM mdm_internal.policy_binding_runtime r))"))
        assert final_after == final_before, {
            "error": "post-resume restart replayed or changed durable state",
            "before": final_before, "after": final_after,
        }
        assert final_binding_after == final_binding_activated, {
            "error": "post-resume restart changed binding version or state",
            "before": final_binding_activated, "after": final_binding_after,
        }
        observations["post_resume_restart"] = {
            "postmaster_before": final_start.isoformat(),
            "postmaster_after": new_postmaster.isoformat(),
            "first_heartbeat": restart_heartbeat_first.isoformat(),
            "later_heartbeat": heartbeat,
            "full_before": final_before,
            "full_after": final_after,
            "bindings_before": final_binding_before,
            "bindings_after_activation": final_binding_activated,
            "bindings_after": final_binding_after,
            "unchanged": True,
            "bindings_unchanged_after_activation": True,
        }
        observations["checks"].append({
            "name": "post-resume-restart-no-replay", "result": "passed"
        })
        qualify_recovery(quiescence_sql)
        observations["entry_decision"] = "QUALIFICATION_INCOMPLETE"
        observations["remaining_gates"] = profile["remaining_measurements"]
        print("PASS: future idle deadline -> actual MDM receipt; registered callback failure and role reset; complete case/source vectors", flush=True)
    except BaseException as error:
        observations["failure"] = str(error)
        if created:
            if (observations["checks"] and observations["checks"][-1] == {"name": "idle-setup", "result": "failed"}
                    and sql("SELECT to_regclass('s1_audit.before_registration') IS NOT NULL") == "t"):
                before = json.loads(sql("SELECT vector FROM s1_audit.before_registration"))
                after = json.loads(sql("SELECT s1_audit.registration_state()"))
                observations.update(entry_decision="STOP", registration_before=before,
                    registration_after=after, registration_state_unchanged=before == after,
                    idle_case_delivered=False,
                    stop_reason="Direct authorized MDM-source deadline registration fails inside pgtrickle.create_stream_table; the successful technical-source idle proof does not qualify this source path.",
                    conditional_work_not_performed=["typed managed temporal registration implementation",
                        "bounded catch-up", "deduplication convergence", "diagnostics/recovery/concurrency acceptance"])
            logs = subprocess.run(["docker", "logs", "--tail", "100", container],
                                  capture_output=True, text=True, timeout=30)
            observations["failure_logs"] = logs.stdout + logs.stderr
            recovery_logs = subprocess.run(
                ["docker", "exec", container, "cat", "/tmp/s1-recovered.log"],
                capture_output=True, text=True, timeout=30)
            if recovery_logs.returncode == 0:
                observations["recovery_failure_logs"] = recovery_logs.stdout
        raise
    finally:
        (output / "observations.json").write_text(json.dumps(observations, indent=2) + "\n")
        if created:
            command("docker", "rm", "--force", "--volumes", container)
        if clone_volume:
            command("docker", "volume", "rm", clone_volume)


if __name__ == "__main__":
    main()
