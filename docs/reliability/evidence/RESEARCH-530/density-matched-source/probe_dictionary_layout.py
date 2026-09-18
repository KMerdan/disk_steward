#!/usr/bin/env python3
"""Lossless density probe of six synthetic product tables; not a product schema."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import resource
import sqlite3
import tempfile
import time

from resume_scale import validate_database_family
from supervise_scale import validate_root

TABLES = ("file_objects", "current_file_state", "path_bindings", "file_state_observations", "events", "change_events")


def ident(value):
    if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_]*", value):
        raise ValueError("Unexpected schema identifier")
    return '"' + value + '"'


def budgeted_rows(cursor, check_budget):
    for count, row in enumerate(cursor, 1):
        yield row
        if count % 512 == 0:
            check_budget()
    check_budget()


def probe(source, destination, encoding="dictionary"):
    if encoding not in {"dictionary", "plain"}:
        raise ValueError("Unknown encoding")
    if destination.exists():
        raise ValueError("Never overwrite a probe database")
    validate_database_family(source)
    original = sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)
    target = sqlite3.connect(destination)
    started = time.monotonic()
    peak_family = 0
    result = {"schema": "disk-steward-dictionary-probe-v1", "encoding": encoding, "productEquivalent": False, "tables": []}

    def check_budget():
        nonlocal peak_family
        sizes = sum(p.stat().st_size for p in destination.parent.iterdir() if p.name.startswith(destination.name))
        peak_family = max(peak_family, sizes)
        if time.monotonic() - started > 45 or sizes > 128 * 1024**2 or resource.getrusage(resource.RUSAGE_SELF).ru_maxrss > 128 * 1024**2:
            raise RuntimeError("Density probe budget exceeded")

    try:
        original.execute("PRAGMA query_only=ON")
        page_size = original.execute("PRAGMA page_size").fetchone()[0]
        target.execute(f"PRAGMA page_size={page_size}")
        target.execute("PRAGMA journal_mode=WAL")
        target.execute("PRAGMA cache_size=-2048")
        if encoding == "dictionary":
            target.execute("CREATE TABLE text_values(id INTEGER PRIMARY KEY,value TEXT NOT NULL UNIQUE)")
        for table in TABLES:
            count = original.execute(f"SELECT COUNT(*) FROM {ident(table)}").fetchone()[0]
            if count > 10_000:
                raise ValueError("Probe limited to 10k rows per table")
            columns = original.execute(f"PRAGMA table_info({ident(table)})").fetchall()
            text_columns = {i for i, c in enumerate(columns) if c[2].upper() == "TEXT" and encoding == "dictionary"}
            definition = ",".join(ident(c[1]) + " " + ("INTEGER" if i in text_columns else c[2]) for i, c in enumerate(columns))
            target.execute(f"CREATE TABLE {ident(table)}(source_rowid INTEGER PRIMARY KEY,{definition})")
            source_hash, recovered_hash = hashlib.sha256(), hashlib.sha256()
            cursor = original.execute(f"SELECT rowid,* FROM {ident(table)} ORDER BY rowid")
            rows_copied = 0
            while rows := cursor.fetchmany(512):
                with target:
                    for row in rows:
                        encoded = [row[0]]
                        source_hash.update(json.dumps(row, ensure_ascii=False, separators=(",", ":")).encode() + b"\n")
                        for i, value in enumerate(row[1:]):
                            if i in text_columns and value is not None:
                                if not isinstance(value, str) or len(value.encode()) > 65536:
                                    raise ValueError("Unexpected text payload")
                                target.execute("INSERT OR IGNORE INTO text_values(value) VALUES(?)", (value,))
                                value = target.execute("SELECT id FROM text_values WHERE value=?", (value,)).fetchone()[0]
                            encoded.append(value)
                        target.execute(f"INSERT INTO {ident(table)} VALUES({','.join('?' for _ in encoded)})", encoded)
                        rows_copied += 1
                check_budget()
            # Keep equivalent column/uniqueness index shapes, including the one
            # partial open-binding index. Integer dictionary order is NOT path order.
            index_count = 0
            for index in original.execute(f"PRAGMA index_list({ident(table)})").fetchall():
                index_name, unique, partial = index[1], bool(index[2]), bool(index[4])
                index_columns = original.execute(f"PRAGMA index_xinfo({ident(index_name)})").fetchall()
                terms = []
                for c in index_columns:
                    if c[5]:
                        terms.append(ident(c[2]) + (" DESC" if c[3] else ""))
                predicate = ""
                if partial:
                    sql = original.execute("SELECT sql FROM sqlite_master WHERE name=?", (index_name,)).fetchone()[0]
                    predicate = " WHERE " + sql.split(" WHERE ", 1)[1]
                    if predicate != " WHERE valid_through IS NULL":
                        raise ValueError("Unreviewed partial predicate")
                target.execute(f"CREATE {'UNIQUE ' if unique else ''}INDEX {ident('probe_' + table + '_' + str(index_count))} ON {ident(table)}({','.join(terms)}){predicate}")
                index_count += 1
                check_budget()
            # Reconstruct each original SQL value, including NULL and floating
            # observation times, without retaining all rows or a global dictionary.
            reconstructed_count = 0
            for row in budgeted_rows(target.execute(f"SELECT * FROM {ident(table)} ORDER BY source_rowid"), check_budget):
                decoded = [row[0]]
                for i, value in enumerate(row[1:]):
                    if i in text_columns and value is not None:
                        value = target.execute("SELECT value FROM text_values WHERE id=?", (value,)).fetchone()[0]
                    decoded.append(value)
                recovered_hash.update(json.dumps(decoded, ensure_ascii=False, separators=(",", ":")).encode() + b"\n")
                reconstructed_count += 1
            if rows_copied != count or reconstructed_count != count or source_hash.digest() != recovered_hash.digest():
                raise ValueError("Lossless reconstruction failed")
            result["tables"].append({"table": table, "rows": count, "indexes": index_count,
                                     "sourceRowsSHA256": source_hash.hexdigest(), "reconstructedRowsSHA256": recovered_hash.hexdigest()})
        target.commit()
        if target.execute("PRAGMA quick_check").fetchone() != ("ok",):
            raise ValueError("Target integrity failed")
        result["dictionaryValues"] = target.execute("SELECT COUNT(*) FROM text_values").fetchone()[0] if encoding == "dictionary" else 0
        result["pagesBeforeCheckpoint"] = target.execute("PRAGMA page_count").fetchone()[0]
        checkpoint = target.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        if checkpoint[0] != 0:
            raise ValueError("Checkpoint did not complete")
        pages = target.execute("SELECT name,SUM(pgsize) FROM dbstat GROUP BY name ORDER BY SUM(pgsize) DESC").fetchall()
        free_pages = target.execute("PRAGMA freelist_count").fetchone()[0]
        check_budget()
        result.update({"elapsedSeconds": time.monotonic() - started, "peakSampledFamilyBytes": peak_family,
                       "peakRSSBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                       "afterCheckpointBytes": {p.name: p.stat().st_size for p in destination.parent.iterdir()},
                       "pageSize": page_size, "freePages": free_pages,
                       "tableAndIndexPages": pages,
                       "limitations": ["Six table density probe only; not all product tables or prepared generations.",
                                        "Lossless values do not prove equivalent query plans, constraints, ordering or migration safety.",
                                        "Dictionary integer order differs from lexical path order; path queries require joins and measured plans.",
                                        "45-second/128-MiB checks are cooperative; not exact allocation guarantees."]})
        return result
    finally:
        target.close()
        original.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--collection", type=Path, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--encoding", choices=["dictionary", "plain"], default="dictionary")
    args = parser.parse_args()
    collection = args.collection.resolve()
    if collection.parent.name != "RESEARCH-530" or collection.parent.parent.name != "evidence":
        parser.error("Expected research collection")
    records = json.loads((collection / "summary.json").read_text())["runs"]
    matches = [r for r in records if r["label"] == args.label]
    if len(matches) != 1:
        parser.error("Expected one archived source run")
    record = matches[0]
    if record["result"]["status"] != "completed" or record["fixture"]["files"] > 10_000:
        parser.error("Expected completed small product fixture")
    root = Path(record["root"])
    command = json.loads((collection / args.label / "fixture-supervision.json").read_text())["command"]
    validate_root(root, command[command.index("--token") + 1])
    destination_root = Path(tempfile.mkdtemp(prefix="disk-steward-530-layout.", dir="/private/tmp"))
    result = probe(root / "baseline/evidence.sqlite", destination_root / "evidence.sqlite", args.encoding)
    result["sourceRun"] = str(collection / args.label / "record.json")
    result["destinationRoot"] = str(destination_root)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
