#!/usr/bin/env python3
"""Stream idempotent source admissions in bounded transactions and refresh separately."""
import argparse
import csv
import datetime
import io
import json
import math
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from decimal import Decimal
from pathlib import Path

MAX_ADMISSIONS_PER_REFRESH = 5
MAX_ADMISSIONS_PER_RUN = 300
MAX_SOURCE_ROWS_PER_ADMISSION = 4
MAX_ADMISSION_JSONL_BYTES = 65_536
MAX_INPUT_JSONL_BYTES = MAX_ADMISSIONS_PER_RUN * (MAX_ADMISSION_JSONL_BYTES + 2)
MAX_PENDING_ADMISSIONS = MAX_ADMISSIONS_PER_RUN
MAX_BATCH_RETRY_SECONDS = 300
CONNECTION_RETRY_INTERVAL_SECONDS = 1
MAX_TRANSACTION_RETRIES = 4
TRANSACTION_RETRY_BASE_SECONDS = 0.1
TRANSACTION_RETRY_MAX_SECONDS = 1.0
PSQL_CONNECT_TIMEOUT_SECONDS = 10
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_$]*\Z")
SERVICE = re.compile(r"[A-Za-z0-9_.-]+\Z")


class DatabaseConnectionLost(RuntimeError):
    pass


class DatabaseTransactionRetry(RuntimeError):
    def __init__(self, service, sqlstate):
        self.sqlstate = sqlstate
        super().__init__("psql service " + service + " failed with retryable SQLSTATE " + sqlstate)


def identifier(value):
    if not IDENTIFIER.fullmatch(value) or len(value.encode("utf-8")) > 63:
        raise ValueError("expected an unquoted PostgreSQL identifier of at most 63 bytes: " + value)
    return '"' + value + '"'


def relation(value):
    parts = value.split(".")
    if len(parts) != 2:
        raise ValueError("source relation must be schema-qualified")
    return ".".join(identifier(part) for part in parts)


def names(value, label):
    parts = [part.strip() for part in value.split(",")]
    if not parts or any(not part for part in parts) or len(set(parts)) != len(parts):
        raise ValueError(label + " must be a non-empty comma-separated list without duplicates")
    return parts


def json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("JSON object contains a duplicate field: " + key)
        result[key] = value
    return result


def json_constant(value):
    raise ValueError("JSON numeric constants must be finite: " + value)


def encode_json_value(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, Decimal):
        if not value.is_finite():
            raise ValueError("JSON numeric values must be finite")
        return str(value)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError("JSON numeric values must be finite")
        return json.dumps(value, allow_nan=False)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[" + ",".join(encode_json_value(item) for item in value) + "]"
    if isinstance(value, dict):
        return "{" + ",".join(
            json.dumps(key, ensure_ascii=False) + ":" + encode_json_value(value[key])
            for key in sorted(value)) + "}"
    raise ValueError("JSONL values must be scalar, object, array, or null")


def row_values(record, line_number, columns, keys):
    if not isinstance(record, dict):
        raise ValueError("source row at line " + str(line_number) + " must be an object")  # noqa: TRY004
    if set(record) != set(columns):
        raise ValueError("source row fields at line " + str(line_number) + " must exactly match configured columns")
    if any(record[key] is None for key in keys):
        raise ValueError("source conflict keys cannot be null at line " + str(line_number))
    return [record[column] for column in columns]


def decode_admission_line(raw_line, line_number):
    payload = raw_line[:-1] if raw_line.endswith(b"\n") else raw_line
    if payload.endswith(b"\r"):
        payload = payload[:-1]
    if len(payload) > MAX_ADMISSION_JSONL_BYTES:
        raise ValueError("admission at line " + str(line_number) + " exceeds supported maximum of "
                         + str(MAX_ADMISSION_JSONL_BYTES) + " UTF-8 bytes")
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError("admission at line " + str(line_number) + " is not valid UTF-8") from error


def load_admission(line, line_number, columns, keys):
    try:
        record = json.loads(line, object_pairs_hook=json_object,
                            parse_float=Decimal, parse_constant=json_constant)
    except (json.JSONDecodeError, ValueError) as error:
        raise ValueError("invalid JSONL record at line " + str(line_number) + ": " + str(error)) from error
    if isinstance(record, dict) and set(record) == {"rows"}:
        rows = record["rows"]
        if not isinstance(rows, list) or not rows:
            raise ValueError("rows at line " + str(line_number) + " must be a non-empty array")
        if len(rows) > MAX_SOURCE_ROWS_PER_ADMISSION:
            raise ValueError("rows at line " + str(line_number) + " exceed supported maximum of "
                             + str(MAX_SOURCE_ROWS_PER_ADMISSION) + " source rows per admission")
        return [row_values(row, line_number, columns, keys) for row in rows]
    if not isinstance(record, dict):
        raise ValueError("JSONL record at line " + str(line_number) + " must be an object")  # noqa: TRY004
    return [row_values(record, line_number, columns, keys)]


def load_admissions(path, columns, keys):
    admissions = []
    input_path = Path(path)
    if input_path.stat().st_size > MAX_INPUT_JSONL_BYTES:
        raise ValueError("input exceeds supported maximum of " + str(MAX_INPUT_JSONL_BYTES) + " bytes")
    input_bytes = 0
    with input_path.open("rb") as source:
        line_number = 0
        while True:
            raw_line = source.readline(MAX_ADMISSION_JSONL_BYTES + 3)
            if not raw_line:
                break
            input_bytes += len(raw_line)
            if input_bytes > MAX_INPUT_JSONL_BYTES:
                raise ValueError("input exceeds supported maximum of " + str(MAX_INPUT_JSONL_BYTES) + " bytes")
            line_number += 1
            line = decode_admission_line(raw_line, line_number)
            if not line.strip():
                continue
            if len(admissions) >= MAX_ADMISSIONS_PER_RUN:
                raise ValueError("input exceeds supported maximum of "
                                 + str(MAX_ADMISSIONS_PER_RUN) + " admissions")
            admissions.append(load_admission(line, line_number, columns, keys))
    return admissions


def copy_value(value):
    if value is None:
        return None
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (dict, list)):
        return encode_json_value(value)
    if isinstance(value, Decimal):
        if not value.is_finite():
            raise ValueError("JSON numeric values must be finite")
        return str(value)
    if isinstance(value, float) and not math.isfinite(value):
        raise ValueError("JSON numeric values must be finite")
    if isinstance(value, (str, int, float)):
        return str(value)
    raise ValueError("JSONL values must be scalar, object, array, or null")


def write_csv(records, columns):
    values = [[copy_value(value) for value in record] for record in records]
    while True:
        null_marker = "PGREACT_NULL_" + uuid.uuid4().hex.upper()
        if all(value != null_marker for row in values for value in row if value is not None):
            break
    buffer = io.StringIO(newline="")
    writer = csv.writer(buffer, lineterminator="\n")
    for row in values:
        writer.writerow([null_marker if value is None else value for value in row])
    return buffer.getvalue(), null_marker


def psql(psql_path, service, script, variables=(), deadline=None):
    command = [psql_path, "-XAtqw", "--set=ON_ERROR_STOP=1", "--set=VERBOSITY=verbose",
               "--dbname=service=" + service + " connect_timeout=" + str(PSQL_CONNECT_TIMEOUT_SECONDS)]
    for key, value in variables:
        command.append("--set=" + key + "=" + value)
    timeout = 120 if deadline is None else min(120, deadline - time.monotonic())
    if timeout <= 0:
        raise DatabaseConnectionLost("psql service " + service + " exceeded the batch retry window")
    try:
        result = subprocess.run(command + ["--file=-"], input=script, capture_output=True,
                                text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as error:
        raise DatabaseConnectionLost("psql service " + service + " timed out") from error
    if result.returncode == 2:
        raise DatabaseConnectionLost("psql service " + service + " lost its database connection")
    if result.returncode:
        retryable_sqlstate = re.search(r"ERROR:\s+(40P01|40001):", result.stderr)
        if retryable_sqlstate:
            raise DatabaseTransactionRetry(service, retryable_sqlstate.group(1))
        raise RuntimeError("psql service " + service + " failed: " + result.stderr.strip())
    return [line for line in result.stdout.splitlines() if line]


def cluster_identity_guard():
    return (
        "SET LOCAL pgreact_producer.expected_database = :'expected_database';\n"
        "SET LOCAL pgreact_producer.expected_system_identifier = :'expected_system_identifier';\n"
        "DO $pgreact_producer_cluster_guard$ BEGIN "
        "IF current_database() <> current_setting('pgreact_producer.expected_database') OR "
        "(SELECT system_identifier::text FROM pg_catalog.pg_control_system()) <> "
        "current_setting('pgreact_producer.expected_system_identifier') THEN "
        "RAISE EXCEPTION 'service connected to a different database or PostgreSQL cluster'; "
        "END IF; END $pgreact_producer_cluster_guard$;\n"
    )


def database_identity(psql_path, service, deadline=None):
    lines = psql(psql_path, service,
        "SELECT 'TARGET|' || current_database() || '|' || system_identifier::text "
        "FROM pg_catalog.pg_control_system();\n", deadline=deadline)
    marker = [line.split("|", 2) for line in lines if line.startswith("TARGET|")]
    if len(marker) != 1 or len(marker[0]) != 3:
        raise RuntimeError("database identity query returned an unexpected result: " + repr(lines))
    return marker[0][1], marker[0][2]


def source_transaction(psql_path, service, table, columns, keys, records, deadline=None,
                       *, expected_database, expected_system_identifier):
    csv_text, null_marker = write_csv(records, columns)
    with tempfile.TemporaryDirectory(prefix="pg-mdm-producer-") as temp_dir:
        csv_path = Path(temp_dir) / "batch.csv"
        with csv_path.open("w", encoding="utf-8", newline="") as csv_file:
            csv_file.write(csv_text)
        csv_path_text = str(csv_path)
        if ("'" in csv_path_text or "\\" in csv_path_text
                or any(ord(character) < 32 or ord(character) == 127
                       for character in csv_path_text)):
            raise ValueError("temporary directory path contains unsupported characters")
        column_list = ", ".join(identifier(column) for column in columns)
        key_list = ", ".join(identifier(key) for key in keys)
        column_literals = ", ".join("'" + column + "'" for column in columns)
        first_key = identifier(keys[0])
        script = (
            "BEGIN;\n"
            + cluster_identity_guard() +
            "CREATE TEMP TABLE pgreact_producer_batch ON COMMIT DROP AS "
            "SELECT " + column_list + " FROM " + table + " WHERE false;\n"
            "\\copy pg_temp.pgreact_producer_batch (" + column_list + ") FROM '" +
            csv_path_text + "' WITH (FORMAT csv, NULL '" + null_marker + "')\n"
            "INSERT INTO " + table + " (" + column_list + ") SELECT " + column_list +
            " FROM pg_temp.pgreact_producer_batch ON CONFLICT (" + key_list + ") DO NOTHING;\n"
            "DO $verify_replay$ DECLARE comparison text; conflicting boolean; BEGIN "
            "SELECT string_agg(CASE WHEN attribute.atttypid = 'json'::regtype "
            "THEN pg_catalog.format('existing.%I::text IS DISTINCT FROM incoming.%I::text', "
            "attribute.attname, attribute.attname) "
            "ELSE pg_catalog.format('existing.%I IS DISTINCT FROM incoming.%I', "
            "attribute.attname, attribute.attname) END, ' OR ' "
            "ORDER BY array_position(ARRAY[" + column_literals + "]::name[], attribute.attname)) "
            "INTO comparison FROM pg_catalog.pg_attribute AS attribute "
            "WHERE attribute.attrelid = '" + table + "'::regclass "
            "AND attribute.attnum > 0 AND NOT attribute.attisdropped "
            "AND attribute.attname = ANY(ARRAY[" + column_literals + "]::name[]); "
            "IF comparison IS NULL THEN RAISE EXCEPTION 'source replay comparison columns are missing'; END IF; "
            "EXECUTE 'SELECT EXISTS (SELECT 1 FROM pg_temp.pgreact_producer_batch AS incoming "
            "LEFT JOIN " + table + " AS existing USING (" + key_list + ") WHERE existing." + first_key +
            " IS NULL OR (' || comparison || '))' INTO conflicting; "
            "IF conflicting THEN RAISE EXCEPTION USING ERRCODE='23505', "
            "MESSAGE='source replay conflicts with existing row'; END IF; END $verify_replay$;\n"
            "SELECT 'SOURCE|' || txid_current()::text || '|' || current_user || '|' || current_database() || '|' "
            "|| system_identifier::text FROM pg_catalog.pg_control_system();\n"
            "COMMIT;\n"
        )
        lines = psql(psql_path, service, script, (("expected_database", expected_database),
            ("expected_system_identifier", expected_system_identifier)), deadline)
    marker = [line.split("|", 4) for line in lines if line.startswith("SOURCE|")]
    if len(marker) != 1 or len(marker[0]) != 5:
        raise RuntimeError("source transaction did not return exactly one transaction marker: " + repr(lines))
    return int(marker[0][1]), marker[0][2], marker[0][3], marker[0][4]


def refresh_transaction(psql_path, service, entity, policy, deadline=None,
                        *, expected_database, expected_system_identifier):
    script = (
        "BEGIN;\n"
        + cluster_identity_guard() +
        "SELECT 'REFRESH|' || txid_current()::text || '|' || current_user || '|' || current_database() || '|' "
        "|| system_identifier::text FROM pg_catalog.pg_control_system();\n"
        "SELECT mdm.refresh(:'entity', :'policy');\n"
        "COMMIT;\n"
    )
    lines = psql(psql_path, service, script, (("entity", entity), ("policy", policy),
        ("expected_database", expected_database),
        ("expected_system_identifier", expected_system_identifier)), deadline)
    marker = [line.split("|", 4) for line in lines if line.startswith("REFRESH|")]
    results = [line for line in lines if not line.startswith("REFRESH|")]
    if len(marker) != 1 or len(marker[0]) != 5 or len(results) != 1:
        raise RuntimeError("refresh transaction returned an unexpected result: " + repr(lines))
    return int(marker[0][1]), marker[0][2], marker[0][3], marker[0][4], results[0]


def run(args):
    psql_path = shutil.which("psql")
    if not psql_path:
        raise RuntimeError("psql is required on PATH")
    if not SERVICE.fullmatch(args.source_service) or not SERVICE.fullmatch(args.refresh_service):
        raise ValueError("service names may contain only letters, digits, underscore, dot, and hyphen")
    if not args.entity or not args.policy:
        raise ValueError("entity and policy must be non-empty")
    if not 1 <= args.batch_size <= MAX_ADMISSIONS_PER_REFRESH:
        raise ValueError("batch size must be between 1 and " + str(MAX_ADMISSIONS_PER_REFRESH))
    if args.rate_per_minute < 0 or not math.isfinite(args.rate_per_minute):
        raise ValueError("rate per minute must be finite and non-negative")
    table = relation(args.table)
    columns = names(args.columns, "columns")
    keys = names(args.key_columns, "key columns")
    for name in columns + keys:
        identifier(name)
    if not set(keys) <= set(columns):
        raise ValueError("key columns must be included in columns")
    started = time.monotonic()
    admission_records = load_admissions(args.input, columns, keys)
    interval = 60.0 / args.rate_per_minute if args.rate_per_minute else 0.0
    batch = []
    batch_number = 0
    admissions = 0
    source_row_count = 0
    refresh_calls = 0
    connection_retries = 0
    transaction_retries = 0
    offers = {"count": 0, "started": None, "finished": None}
    pinned_database = None
    pinned_system_identifier = None
    event_output_lock = threading.Lock()
    offer_order_lock = threading.Lock()
    pending = queue.Queue(maxsize=MAX_PENDING_ADMISSIONS)
    stop_offering = threading.Event()

    def emit(event):
        with event_output_lock:
            print(json.dumps(event, sort_keys=True), flush=True)

    def enqueue(item):
        while not stop_offering.is_set():
            try:
                pending.put(item, timeout=0.1)
                return True
            except queue.Full:
                continue
        return False

    def flush(records):
        nonlocal batch_number, refresh_calls, connection_retries, transaction_retries
        nonlocal pinned_database, pinned_system_identifier
        batch_number += 1
        source_rows = [row for admission in records for row in admission]
        if args.emit_admission_events:
            with offer_order_lock:
                emit({"event": "source_batch_started", "batch": batch_number,
                    "admissions": len(records), "source_rows": len(source_rows),
                    "started_at": datetime.datetime.now(
                        datetime.timezone.utc).isoformat(),  # noqa: UP017 - retain broad Python 3 compatibility
                    "started_offset_seconds": round(
                        time.monotonic() - offers["started"], 6)})
        retry_deadline = time.monotonic() + MAX_BATCH_RETRY_SECONDS
        retry_attempt = 0
        transaction_retry_attempt = 0
        while True:
            try:
                observed_database, observed_system_identifier = database_identity(
                    psql_path, args.refresh_service, deadline=retry_deadline)
                if pinned_database is None:
                    pinned_database = observed_database
                    pinned_system_identifier = observed_system_identifier
                elif (observed_database, observed_system_identifier) != (
                        pinned_database, pinned_system_identifier):
                    raise RuntimeError(
                        "refresh service changed database or cluster identity during producer run")
                source_started = time.monotonic()
                source_txid, source_role, source_database, source_system_identifier = source_transaction(
                    psql_path, args.source_service, table, columns, keys, source_rows,
                    deadline=retry_deadline, expected_database=pinned_database,
                    expected_system_identifier=pinned_system_identifier)
                source_seconds = time.monotonic() - source_started
                refresh_started = time.monotonic()
                refresh_txid, refresh_role, refresh_database, refresh_system_identifier, refresh_result = refresh_transaction(
                    psql_path, args.refresh_service, args.entity, args.policy,
                    deadline=retry_deadline, expected_database=pinned_database,
                    expected_system_identifier=pinned_system_identifier)
                refresh_seconds = time.monotonic() - refresh_started
                break
            except DatabaseConnectionLost:
                remaining = retry_deadline - time.monotonic()
                if remaining <= 0:
                    raise
                retry_attempt += 1
                connection_retries += 1
                delay = min(CONNECTION_RETRY_INTERVAL_SECONDS, remaining)
                emit({"event": "connection_retry", "batch": batch_number,
                    "attempt": retry_attempt, "delay_seconds": delay})
                time.sleep(delay)
            except DatabaseTransactionRetry as error:
                if transaction_retry_attempt >= MAX_TRANSACTION_RETRIES:
                    raise
                remaining = retry_deadline - time.monotonic()
                if remaining <= 0:
                    raise DatabaseConnectionLost(
                        "psql service " + error.service + " exceeded the batch retry window") from error
                transaction_retry_attempt += 1
                transaction_retries += 1
                delay = min(TRANSACTION_RETRY_BASE_SECONDS * (2 ** (transaction_retry_attempt - 1)),
                    TRANSACTION_RETRY_MAX_SECONDS, remaining)
                emit({"event": "transaction_retry", "batch": batch_number,
                    "attempt": transaction_retry_attempt, "sqlstate": error.sqlstate,
                    "delay_seconds": delay})
                time.sleep(delay)
        if source_system_identifier != refresh_system_identifier:
            raise RuntimeError("source and refresh services connected to different database clusters")
        if source_database != refresh_database:
            raise RuntimeError("source and refresh services connected to different databases")
        if source_txid == refresh_txid:
            raise RuntimeError("source commit and refresh unexpectedly shared a transaction ID")
        refresh_calls += 1
        emit({"event": "batch_complete", "batch": batch_number,
            "admissions": len(records), "source_rows": len(source_rows),
            "transaction_retries": transaction_retry_attempt,
            "source_txid": source_txid,
            "source_role": source_role, "source_database": source_database,
            "source_commit_seconds": round(source_seconds, 6),
            "refresh_txid": refresh_txid, "refresh_role": refresh_role,
            "refresh_database": refresh_database,
            "refresh_seconds": round(refresh_seconds, 6),
            "refresh_result": refresh_result})

    def offer_records():
        offers["started"] = time.monotonic()
        wall_started = datetime.datetime.now(
            datetime.timezone.utc)  # noqa: UP017 - retain broad Python 3 compatibility
        try:
            for admission in admission_records:
                offer_number = offers["count"] + 1
                if interval:
                    deadline = offers["started"] + offer_number * interval
                    delay = deadline - time.monotonic()
                    if delay > 0 and stop_offering.wait(delay):
                        return
                if stop_offering.is_set():
                    return
                offered = threading.Event() if args.emit_admission_events else None
                if not enqueue(("record", admission, offered)):
                    return
                try:
                    if offered is not None:
                        with offer_order_lock:
                            offers["count"] = offer_number
                            emit({"event": "admission_offered", "admission": offer_number,
                                "scheduled_at": (wall_started + datetime.timedelta(
                                    seconds=offer_number * interval)).isoformat(),
                                "submitted_at": datetime.datetime.now(
                                datetime.timezone.utc).isoformat(),  # noqa: UP017 - retain broad Python 3 compatibility
                                "scheduled_offset_seconds": round(offer_number * interval, 6),
                                "submitted_offset_seconds": round(
                                    time.monotonic() - offers["started"], 6)})
                    else:
                        offers["count"] = offer_number
                finally:
                    if offered is not None:
                        offered.set()
            offers["finished"] = time.monotonic()
            enqueue(("done", None))
        except Exception as error:  # noqa: BLE001 - forward worker errors to the consumer
            offers["finished"] = time.monotonic()
            enqueue(("error", error))

    offerer = threading.Thread(target=offer_records, name="bounded-source-offerer")
    offerer.start()
    try:
        finished = False
        while not finished:
            item = pending.get()
            kind, value = item[:2]
            if kind == "done":
                finished = True
            elif kind == "error":
                raise value
            else:
                offered = item[2] if len(item) > 2 else None
                if offered is not None:
                    offered.wait()
                batch.append(value)
                admissions += 1
                source_row_count += len(value)
                if len(batch) == args.batch_size:
                    flush(batch)
                    batch = []
        if batch:
            flush(batch)
    except Exception:
        stop_offering.set()
        raise
    finally:
        # KeyboardInterrupt bypasses the Exception handler above.
        stop_offering.set()
        offerer.join()

    elapsed = time.monotonic() - started
    offered_seconds = max(0.0, offers["finished"] - offers["started"])
    summary = {"event": "producer_complete", "admissions": admissions,
        "source_rows": source_row_count,
        "offered_admissions": offers["count"],
        "offered_seconds": round(offered_seconds, 6),
        "offered_admissions_per_minute": round(offers["count"] * 60 / offered_seconds, 6)
            if offered_seconds else 0.0,
        "batch_size_limit": MAX_ADMISSIONS_PER_REFRESH, "batches": batch_number,
        "refresh_calls": refresh_calls, "connection_retries": connection_retries,
        "transaction_retries": transaction_retries,
        "elapsed_seconds": round(elapsed, 6),
        "admissions_per_minute": round(admissions * 60 / elapsed, 6) if elapsed else 0.0}
    emit(summary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-service", required=True,
        help="libpq service for the source writer; configure it in PGSERVICEFILE")
    parser.add_argument("--refresh-service", required=True,
        help="libpq service for the MDM entity execution role")
    parser.add_argument("--table", required=True, help="schema-qualified source table")
    parser.add_argument("--columns", required=True, help="comma-separated source columns")
    parser.add_argument("--key-columns", required=True,
        help="comma-separated non-null unique source key columns for replay safety")
    parser.add_argument("--entity", required=True, help="single MDM entity to refresh")
    parser.add_argument("--policy", required=True, help="full MDM refresh policy")
    parser.add_argument("--input", required=True,
        help="UTF-8 JSONL admissions: one source row object or an object with a rows array")
    parser.add_argument("--batch-size", type=int, default=MAX_ADMISSIONS_PER_REFRESH,
        help="admissions committed before one refresh (maximum 5)")
    parser.add_argument("--rate-per-minute", type=float, default=60,
        help="offered admission rate; use 0 for unpaced processing")
    parser.add_argument("--emit-admission-events", action="store_true",
        help="emit one JSON event per paced admission with scheduled and submitted timestamps")
    args = parser.parse_args()
    try:
        run(args)
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
