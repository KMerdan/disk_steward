#!/usr/bin/env python3
"""Archive compact completed-run evidence, never the synthetic files or DBs."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import sqlite3
from resume_scale import validate_database_family


def inspect_database(path):
    if not path.is_file():
        return None
    validate_database_family(path)
    connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)
    connection.execute("PRAGMA query_only=ON")
    try:
        # Autocommit read statements; no long-running reader during benchmarking.
        queries = {
            "integrity": "PRAGMA quick_check",
            "currentFiles": "SELECT COUNT(*) FROM current_file_state WHERE presence='present'",
            "observations": "SELECT COUNT(*) FROM observation_runs",
            "stagedFiles": "SELECT COUNT(*) FROM scan_generation_entries",
            "generations": "SELECT status,processed_entry_count,staged_file_count FROM scan_generations",
            "openPathCountPlan": "EXPLAIN QUERY PLAN SELECT COUNT(*) FROM path_bindings WHERE object_id='fixture' AND valid_through IS NULL",
            "openPathPagePlan": "EXPLAIN QUERY PLAN SELECT path FROM path_bindings WHERE object_id='fixture' AND valid_through IS NULL AND path>'' ORDER BY path LIMIT 1",
        }
        if connection.execute("SELECT COUNT(*) FROM sqlite_master WHERE name='visible'").fetchone()[0]:
            # Distinct research schema: never label these counts as product lifecycle proof.
            revised = connection.execute("SELECT COUNT(*) FROM sqlite_master WHERE name='directories_unvalidated'").fetchone()[0] != 0
            open_index = " INDEXED BY directories_open" if revised else ""
            pending_index = " INDEXED BY directories_unvalidated" if revised else ""
            queries = {
                "integrity": "PRAGMA quick_check",
                "visibleFiles": "SELECT COUNT(*) FROM entries e JOIN visible v ON e.generation=v.generation JOIN directories d ON e.directory=d.id AND e.epoch=d.epoch WHERE d.parent IS NULL OR EXISTS(SELECT 1 FROM directories p WHERE p.id=d.parent AND p.epoch=d.owner_epoch)",
                "physicalEntries": "SELECT COUNT(*) FROM entries",
                "scratchNames": "SELECT COUNT(*) FROM names",
                "visibleDirectoryPhases": "SELECT d.phase,COUNT(*) FROM directories d JOIN visible v ON d.generation=v.generation GROUP BY d.phase ORDER BY d.phase",
                "physicalDirectoryCount": "SELECT COUNT(*) FROM directories",
                "generations": "SELECT id,mode,status FROM generations ORDER BY id",
                "queuePlan": f"EXPLAIN QUERY PLAN SELECT d.id,d.path,d.depth,d.phase,d.signature,d.epoch,d.offset FROM directories d{open_index} LEFT JOIN directories p ON d.parent=p.id WHERE d.generation=1 AND d.phase<3 AND (d.parent IS NULL OR d.owner_epoch=p.epoch) ORDER BY d.id LIMIT 1",
                "validationQueuePlan": f"EXPLAIN QUERY PLAN SELECT d.id,d.path,d.depth,d.phase,d.signature,d.epoch,d.offset FROM directories d{pending_index} LEFT JOIN directories p ON d.parent=p.id WHERE d.generation=1 AND d.phase<4 AND (d.parent IS NULL OR d.owner_epoch=p.epoch) ORDER BY d.id LIMIT 1",
            }
        queries.update({
            "pageCount": "PRAGMA page_count",
            "pageSize": "PRAGMA page_size",
            "freePages": "PRAGMA freelist_count",
        })
        result = {"readerSQLiteVersion": sqlite3.sqlite_version,
                  "queries": {name: {"sql": sql, "rows": connection.execute(sql).fetchall()} for name, sql in queries.items()}}
        sql = "SELECT name,COUNT(*) AS pages,SUM(pgsize) AS bytes,SUM(payload) AS payloadBytes,SUM(unused) AS unusedBytes FROM dbstat GROUP BY name ORDER BY bytes DESC LIMIT 128"
        try:
            result["queries"]["tableAndIndexPages"] = {"sql": sql, "rows": connection.execute(sql).fetchall()}
        except sqlite3.OperationalError as error:
            result["queries"]["tableAndIndexPages"] = {"sql": sql, "unavailable": str(error)}
        result["postRunFamilyBytes"] = {p.name: p.stat().st_size for p in sorted(path.parent.iterdir())}
        return result
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", nargs=2, action="append", metavar=("LABEL", "ROOT"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--candidate-sha256", required=True)
    parser.add_argument("--phase", choices=["baseline", "resume", "recovery"], default="baseline")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-f0-9]{64}", args.candidate_sha256):
        parser.error("Invalid source hash")
    output = args.output.resolve()
    if output.parent.name != "RESEARCH-530" or output.parent.parent.name != "evidence":
        parser.error("Output must be a new RESEARCH-530/evidence run collection")
    output.mkdir()  # Do not overwrite a prior collection.
    runs = []
    for label, supplied in args.run:
        if not re.fullmatch(r"[a-z0-9-]+", label):
            parser.error("Unsafe label")
        root = Path(supplied)
        if (root.resolve() != root or root.parent != Path("/private/tmp")
                or not root.name.startswith("disk-steward-530-scale.")
                or not (root / "owner-token").is_file()):
            parser.error("Not a generated fixture root")
        target = output / label
        target.mkdir()
        hashes = {}
        names = ["fixture.json", "fixture.log", "fixture-supervision.json", "baseline.log", "baseline-supervision.json"]
        if args.phase in {"resume", "recovery"}:
            names += ["resume.log", "resume-supervision.json"]
        if args.phase == "recovery":
            names += ["recovery.log", "recovery-supervision.json"]
        for name in names:
            source = root / name
            if source.is_file():
                if source.stat().st_size > 8 * 1024 * 1024:
                    raise ValueError("Refusing an unexpectedly large evidence file")
                shutil.copyfile(source, target / name)
                hashes[name] = hashlib.sha256(source.read_bytes()).hexdigest()
        text = (root / f"{args.phase}.log").read_text(errors="replace")
        rows = [json.loads(line) for line in text.splitlines() if line.startswith('{"')]
        measurements = [row for row in rows if row.get("schema") in ("disk-steward-scale-baseline-v1", "disk-steward-scale-prototype-v1", "disk-steward-scale-resume-v1")]
        results = [row for row in measurements if row.get("kind") == "result"]
        record = {
            "label": label, "root": str(root), "phase": args.phase,
            "fixture": json.loads((root / "fixture.json").read_text()),
            "supervision": json.loads((root / f"{args.phase}-supervision.json").read_text()),
            "lastMeasurement": measurements[-1] if measurements else None,
            "result": results[-1] if results else None,
            "postRunDatabase": inspect_database(root / "baseline/evidence.sqlite"),
            "artifactSHA256": hashes,
        }
        (target / "record.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
        runs.append(record)
    summary = {"schema": "disk-steward-scale-collection-v1", "collectedAt": datetime.now(timezone.utc).isoformat(),
               "candidateSHA256": args.candidate_sha256, "runs": runs,
               "limits": ["Single runs, warm/uncontrolled OS caches; not latency distributions.",
                          "Sampled RSS/WAL peaks are lower bounds, not exact high-water marks.",
                          "Supervision may stop after atomic publication; inspect durable state separately.",
                          "Prototype index only changes disposable databases; no product migration selected."]}
    (output / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"collection": str(output), "runs": len(runs)}, sort_keys=True))


if __name__ == "__main__":
    main()
