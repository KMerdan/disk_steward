#!/usr/bin/env python3
"""Resume a collected, stopped prototype with new logs and a pinned SQLite reader."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat

import supervise_scale as bench


def validate_database_family(database):
    members = list(database.parent.iterdir())
    if (database not in members or not {p.name for p in members} <=
            {"evidence.sqlite", "evidence.sqlite-wal", "evidence.sqlite-shm"}):
        raise ValueError("Unsafe or absent database family")
    for member in members:
        metadata = member.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or member.resolve() != member:
            raise ValueError("Unsafe or absent database family")


def validate_collected_run(collection, label, phase="resume"):
    if phase not in {"resume", "recovery"}:
        raise ValueError("Unknown measurement phase")
    if not re.fullmatch(r"[a-z0-9-]+", label):
        raise ValueError("Unsafe run label")
    collection = collection.resolve()
    if collection.parent.name != "RESEARCH-530" or collection.parent.parent.name != "evidence":
        raise ValueError("Not a research evidence collection")
    summary = json.loads((collection / "summary.json").read_text())
    matches = [r for r in summary["runs"] if r["label"] == label]
    if len(matches) != 1:
        raise ValueError("Exactly one collected run must match")
    record = matches[0]
    root = Path(record["root"])
    if record["supervision"]["reason"] != "exited":
        raise ValueError("Only a cooperatively stopped XCTest can resume")
    if phase == "resume":
        if record["supervision"]["exitCode"] != 0 or record.get("phase", "baseline") != "baseline":
            raise ValueError("Expected a successful collected baseline XCTest")
        if record["result"]["schema"] != "disk-steward-scale-prototype-v1" or record["result"]["status"] != "time-limit":
            raise ValueError("Expected a collected incomplete prototype")
        if record["result"]["publishedGenerations"] != 1 or record["result"]["requestedGenerations"] != 2:
            raise ValueError("Expected a preparing second generation")
    else:
        result = record["result"]
        # The original pinned-reader harness classified an admission stop as a
        # test error. Accept only that exact recorded error, not arbitrary failure.
        expected_stop = ((result["status"] == "admission-stop" and record["supervision"]["exitCode"] == 0)
                         or (result["status"] == "error" and result["error"] == "capacity"
                             and record["supervision"]["exitCode"] == 1))
        if (record.get("phase") != "resume" or result["schema"] != "disk-steward-scale-resume-v1"
                or not result["pinnedReader"] or result["published"] or not expected_stop
                or record["postRunDatabase"]["queries"]["integrity"]["rows"] != [["ok"]]):
            raise ValueError("Expected a verified intact pinned-reader admission stop")
    # Resolve only already collected roots. No caller-supplied database path.
    fixture_command = json.loads((collection / label / "fixture-supervision.json").read_text())["command"]
    token = fixture_command[fixture_command.index("--token") + 1]
    bench.validate_root(root, token)
    expected_children = {"baseline", "fixture", "fixture.json", "owner-token", "fixture.log",
                         "fixture-supervision.json", "baseline.log", "baseline-supervision.json"}
    if phase == "recovery":
        expected_children |= {"resume.log", "resume-supervision.json"}
    if {p.name for p in root.iterdir()} != expected_children or any(p.is_symlink() for p in root.iterdir()):
        raise ValueError("Unexpected content or previous resume attempt")
    for name, digest in record["artifactSHA256"].items():
        if name not in expected_children or name in {"baseline", "fixture", "owner-token"}:
            raise ValueError("Unexpected artifact name")
        if (hashlib.sha256((root / name).read_bytes()).hexdigest() != digest
                or hashlib.sha256((collection / label / name).read_bytes()).hexdigest() != digest):
            raise ValueError("Original collected evidence changed")
    fixture = json.loads((root / "fixture.json").read_text())
    if (fixture != record["fixture"] or fixture["shape"] != "wide" or fixture.get("complete") is not True
            or not 1 <= fixture["files"] <= 1_000_000):
        raise ValueError("Only complete wide-file fixtures are supported")
    database = root / "baseline/evidence.sqlite"
    # SQLite may access sidecars during even a read-only open. Establish the
    # complete family ownership before opening any member, not after SQL checks.
    validate_database_family(database)
    connection = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)
    try:
        if connection.execute("SELECT generation FROM visible WHERE singleton=1").fetchone() != (1,):
            raise ValueError("Visible generation changed since collection")
        if connection.execute("SELECT id,mode,status,fenced FROM generations ORDER BY id LIMIT 3").fetchall() != [
                (1, record["result"]["variant"], "published", 0), (2, record["result"]["variant"], "preparing", 0)]:
            raise ValueError("Unexpected generation state")
        # A wide-only two-generation fixture has exactly two roots and no
        # descendants. Do not accept queued paths that the worker would traverse.
        roots = connection.execute("SELECT path,parent FROM directories LIMIT 3").fetchall()
        if len(roots) != 2 or any(parent is not None or Path(p) != root / "fixture" for p, parent in roots):
            raise ValueError("Database references another fixture")
    finally:
        connection.close()
    return root, token, fixture, record["result"]["variant"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--collection", type=Path, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=120)
    parser.add_argument("--confirmed-stopped", action="store_true")
    parser.add_argument("--phase", choices=["resume", "recovery"], default="resume")
    args = parser.parse_args()
    if not args.confirmed_stopped or not 0 < args.seconds <= 120:
        parser.error("Confirm actual handles are stopped; use seconds in (0,120]")
    workspace = args.workspace.resolve()
    bundle = workspace / ".build/arm64-apple-macosx/release/DiskStewardPackageTests.xctest"
    if workspace.parent != Path("/private/tmp") or not workspace.name.startswith("disk-steward-") or not bundle.is_dir():
        parser.error("Expected an already-built disposable workspace")
    root, token, fixture, variant = validate_collected_run(args.collection, args.label, args.phase)
    disk = os.statvfs(root)
    if disk.f_bavail * disk.f_frsize < 32 * bench.GIB:
        parser.error("Insufficient free space")
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": str(root), "LANG": "en_US.UTF-8",
                   "DISK_STEWARD_SCALE_BENCHMARK": "resume-supervised-v1", "DISK_STEWARD_SCALE_ROOT": str(root),
                   "DISK_STEWARD_SCALE_TOKEN": token, "DISK_STEWARD_SCALE_SECONDS": str(args.seconds),
                   "DISK_STEWARD_SCALE_PIN_READER": "1" if args.phase == "resume" else "0",
                   "DISK_STEWARD_SCALE_VARIANT": variant, "DISK_STEWARD_SCALE_FILES": str(fixture["files"])}
    result = bench.supervise(["/usr/bin/nice", "-n", "10", "/usr/bin/xcrun", "xctest", "-XCTest",
                              "PerformanceTests.BoundedTraversalResumeTests/testOptInResumeWithControlledReader", str(bundle)],
                             environment, root, args.phase, args.seconds + 15, 256 * bench.MIB)
    rows = [json.loads(line) for line in (root / f"{args.phase}.log").read_text().splitlines()
            if line.startswith('{"') and '"kind":"result"' in line]
    if result["reason"] == "exited" and (result["exitCode"] != 0 or len(rows) != 1):
        raise SystemExit("Resume did not produce one verified result")
    for row in rows:
        bench.emit(row)


if __name__ == "__main__":
    main()
