#!/usr/bin/env python3
"""Bounded query comparison over the retained matched synthetic layout pair."""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import sqlite3
import statistics
import time

from probe_dictionary_layout import TABLES, ident
from resume_scale import validate_database_family


def open_probe(record_path, encoding):
    if record_path.parent.name != "RESEARCH-530" or record_path.parent.parent.name != "evidence":
        raise ValueError("Expected archived density evidence")
    record = json.loads(record_path.read_text())
    if record.get("encoding") != encoding or record.get("productEquivalent") is not False:
        raise ValueError("Unexpected probe identity")
    root = Path(record["destinationRoot"])
    if root.parent != Path("/private/tmp") or root.resolve() != root or not root.name.startswith("disk-steward-530-layout."):
        raise ValueError("Unexpected generated probe root")
    database = root / "evidence.sqlite"
    validate_database_family(database)
    if database.stat().st_size != record["afterCheckpointBytes"]["evidence.sqlite"]:
        raise ValueError("Probe size changed")
    connection = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)
    connection.execute("PRAGMA cache_size=-2048")
    # Temporary schema is connection-local. Main DB remains opened read-only.
    return connection, record


def decoded_views(plain, encoded):
    for table in TABLES:
        columns = plain.execute(f"PRAGMA table_info({ident(table)})").fetchall()
        plain.execute(f"CREATE TEMP VIEW {ident('decoded_' + table)} AS SELECT * FROM main.{ident(table)}")
        terms, joins = [], []
        for i, c in enumerate(columns):
            name = ident(c[1])
            if c[2].upper() == "TEXT":
                joins.append(f"LEFT JOIN main.text_values d{i} ON d{i}.id=t.{name}")
                terms.append(f"d{i}.value AS {name}")
            else:
                terms.append(f"t.{name}")
        encoded.execute(f"CREATE TEMP VIEW {ident('decoded_' + table)} AS SELECT {','.join(terms)} FROM main.{ident(table)} t {' '.join(joins)}")
    plain.execute("PRAGMA query_only=ON")
    encoded.execute("PRAGMA query_only=ON")


def measure(connection, sql, parameters=(), step_limit=2_000_000, seconds=2.0):
    if not 0 < step_limit <= 2_000_000 or not 0 < seconds <= 2:
        raise ValueError("Invalid query budget")
    started, steps, reason = time.monotonic(), 0, None
    plan, cursor = [], None

    def progress():
        nonlocal steps, reason
        steps += 100
        if steps >= step_limit:
            reason = "vm-step-limit"
        elif time.monotonic() - started >= seconds:
            reason = "time-limit"
        elif steps % 10000 == 0 and resource.getrusage(resource.RUSAGE_SELF).ru_maxrss > 128 * 1024**2:
            reason = "rss-limit"
        return int(reason is not None)

    connection.set_progress_handler(progress, 100)
    try:
        plan = connection.execute("EXPLAIN QUERY PLAN " + sql, parameters).fetchall()
        cursor = connection.execute(sql, parameters)
        rows = cursor.fetchmany(502)
        if len(rows) > 501:
            raise ValueError("Unexpected unbounded query output")
        return {"status": "completed", "seconds": time.monotonic() - started,
                "vmStepsLowerBound": steps, "rows": rows, "plan": plan}
    except sqlite3.OperationalError:
        if reason is None:
            raise
        return {"status": reason, "seconds": time.monotonic() - started,
                "vmStepsLowerBound": steps, "rows": None, "plan": plan}
    finally:
        if cursor is not None:
            cursor.close()
        connection.set_progress_handler(None, 0)


def summarize_runs(runs):
    if not runs:
        raise ValueError("Expected at least one query attempt")
    failure = next((r["status"] for r in runs if r["status"] != "completed"), None)
    completed = failure is None
    if completed and any(r["rows"] != runs[0]["rows"] for r in runs):
        raise ValueError("Query changed during repeated measurement")
    rows = runs[0]["rows"] if completed else None
    return {"status": failure or "completed",
            "attemptStatuses": [r["status"] for r in runs],
            "seconds": [r["seconds"] for r in runs],
            "medianSeconds": statistics.median(r["seconds"] for r in runs) if completed else None,
            "vmStepsLowerBound": [r["vmStepsLowerBound"] for r in runs],
            "rowCount": len(rows) if rows is not None else None,
            "orderedRowsSHA256": hashlib.sha256(json.dumps(rows, ensure_ascii=False).encode()).hexdigest() if rows is not None else None,
            "plan": runs[0]["plan"]}, rows


def cases(path, object_id, observation_id, after):
    # Representative expressions, not the complete MCP backend or every filter.
    current = "SELECT c.object_id,c.path,c.allocated_bytes,c.modified_at,c.observed_at,c.presence FROM decoded_current_file_state c WHERE c.presence='present' AND c.actionable=1"
    page_order = " ORDER BY c.allocated_bytes DESC,c.path,c.object_id LIMIT 101"
    return [
        ("current-count", "SELECT COUNT(*),COALESCE(SUM(allocated_bytes),0) FROM decoded_current_file_state WHERE presence='present' AND actionable=1", ()),
        ("current-first-page", current + page_order, ()),
        ("current-next-page", current + " AND (c.allocated_bytes<? OR (c.allocated_bytes=? AND (c.path>? OR (c.path=? AND c.object_id>?))))" + page_order,
         (after[2], after[2], after[1], after[1], after[0])),
        ("exact-path", "SELECT object_id,path,observed_at,presence FROM decoded_current_file_state WHERE path=? ORDER BY object_id LIMIT 101", (path,)),
        ("open-object-paths", "SELECT path,valid_from,confidence FROM decoded_path_bindings WHERE object_id=? AND valid_through IS NULL ORDER BY path LIMIT 101", (object_id,)),
        ("object-events", "SELECT e.event_id,e.path,e.observed_at,ce.occurred_start,ce.occurred_end,e.operation FROM decoded_change_events ce JOIN decoded_events e ON e.event_id=ce.event_id WHERE ce.object_id=? ORDER BY e.observed_at,e.event_id LIMIT 101", (object_id,)),
        ("observation-page", "SELECT object_id,path,observed_at,existence,confidence FROM decoded_file_state_observations WHERE observation_id=? ORDER BY path,object_id LIMIT 101", (observation_id,)),
    ]


def compare(plain, encoded):
    decoded_views(plain, encoded)
    seed = plain.execute("SELECT path,object_id,state_as_of_observation_id FROM current_file_state ORDER BY path LIMIT 1").fetchone()
    if seed is None:
        raise ValueError("Expected nonempty fixture")
    first = measure(plain, "SELECT object_id,path,allocated_bytes FROM current_file_state WHERE presence='present' AND actionable=1 ORDER BY allocated_bytes DESC,path,object_id LIMIT 100")
    if first["status"] != "completed" or not first["rows"]:
        raise ValueError("Cannot establish pagination seed")
    results = []
    for name, sql, parameters in cases(*seed, first["rows"][-1]):
        variants = {}
        observations = []
        for label, connection in [("plain", plain), ("dictionary", encoded)]:
            runs = [measure(connection, sql, parameters) for _ in range(3)]
            variants[label], rows = summarize_runs(runs)
            observations.append(rows)
        equal = observations[0] is not None and observations[0] == observations[1]
        if all(v["status"] == "completed" for v in variants.values()) and not equal:
            raise ValueError("Decoded query results diverged")
        results.append({"query": name, "sql": sql, "variants": variants, "equalCompletedRows": equal})
    # Typed rewrite isolates the enum predicate from the decoded-view approach.
    typed = "SELECT COUNT(*),COALESCE(SUM(allocated_bytes),0) FROM current_file_state WHERE presence=(SELECT id FROM text_values WHERE value='present') AND actionable=1"
    typed_result = measure(encoded, typed)
    baseline = measure(plain, "SELECT COUNT(*),COALESCE(SUM(allocated_bytes),0) FROM current_file_state WHERE presence='present' AND actionable=1")
    if typed_result["status"] != "completed" or typed_result["rows"] != baseline["rows"]:
        raise ValueError("Typed count differs")
    return {"schema": "disk-steward-layout-query-probe-v1", "productEquivalent": False,
            "queries": results, "typedCount": typed_result, "plainCount": baseline,
            "limitations": ["10k quiescent single-observation fixture, three instrumented warm runs; not p95 or app latency.",
                             "Decoded views preserve selected SQL values, not all product constraints or query filters.",
                             "VM counts are progress-callback lower bounds at 100-op granularity, including the query-plan statement.",
                             "Time/RSS limits are cooperative; query interruptions are failures to complete, not passing performance."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plain", type=Path, required=True)
    parser.add_argument("--encoded", type=Path, required=True)
    args = parser.parse_args()
    plain, plain_record = open_probe(args.plain.resolve(), "plain")
    try:
        encoded, encoded_record = open_probe(args.encoded.resolve(), "dictionary")
        try:
            if plain_record["tables"] != encoded_record["tables"]:
                raise ValueError("Probe source hashes differ")
            result = compare(plain, encoded)
            result["inputs"] = {"plain": str(args.plain), "dictionary": str(args.encoded)}
            result["readerSQLiteVersion"] = sqlite3.sqlite_version
            print(json.dumps(result, sort_keys=True))
        finally:
            encoded.close()
    finally:
        plain.close()


if __name__ == "__main__":
    main()
