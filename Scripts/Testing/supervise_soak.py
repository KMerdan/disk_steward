#!/usr/bin/env python3
"""Fixture-only wall-clock soak supervisor (TASK-572 / FIND-OVERNIGHT).

Creates one disposable fixture tree in a new /private/tmp leaf it owns, then
supervises ONE already-built XCTest (PerformanceTests.SoakBenchmarkTests) for a
real wall-clock duration with explicit process handles, time and storage
quotas, bounded output, RSS/CPU/FD/DB/WAL/export measurements taken by both the
test and this supervisor, and an external stop threshold (a "stop" file in the
root, written by an operator or by this supervisor on SIGINT/SIGTERM).

No watched folders, user settings, production DB, app launch, or client
configs. This script never deletes a tree. Only the process group it created
can be terminated. Virtual time is never substituted for wall-clock time.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import uuid

MIB = 1024 * 1024
GIB = 1024 * MIB


def emit(value):
    print(json.dumps(value, sort_keys=True), flush=True)


def validate_root(root, token):
    if (root.parent != Path("/private/tmp") or not root.name.startswith("disk-steward-572-soak.")
            or root.resolve() != root or (root / "owner-token").read_text() != token):
        raise ValueError("Not a supervisor-owned soak leaf")


def fixture_worker(root, token, files, buckets):
    validate_root(root, token)
    os.nice(10)
    directory = root / "fixture"
    directory.mkdir()  # Never reuse/overwrite.
    for bucket in range(buckets):
        (directory / f"bucket-{bucket:02d}").mkdir()
    for index in range(files):
        path = directory / f"bucket-{index % buckets:02d}" / f"s-{index:09d}"
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(descriptor, b"0")
        os.close(descriptor)
        if index % 10_000 == 0:
            emit({"kind": "fixture-progress", "entries": index + 1})
    manifest = {"files": files, "buckets": buckets, "complete": True}
    (root / "fixture.json").write_text(json.dumps(manifest, sort_keys=True))
    emit(manifest)


def group_rss(pgid):
    # Do not inspect process arguments/environment; only process group + RSS.
    output = subprocess.check_output(["/bin/ps", "-axo", "pgid=,rss="], text=True, timeout=2)
    return sum(int(rss) * 1024 for group, rss in (line.split() for line in output.splitlines())
               if int(group) == pgid)


def database_bytes(root):
    sizes = {}
    for suffix in ("", "-wal", "-shm"):
        path = root / ("soak/evidence.sqlite" + suffix)
        try:
            sizes[suffix or "db"] = path.stat().st_size
        except FileNotFoundError:
            sizes[suffix or "db"] = 0
    return sizes


def tree_bytes(path):
    total = 0
    for parent, _, names in os.walk(path):
        for name in names:
            try:
                total += os.lstat(os.path.join(parent, name)).st_size
            except FileNotFoundError:
                pass
    return total


def terminate_owned_group(process):
    # start_new_session creates pgid == pid; never target the caller's group.
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait(timeout=2)
        return
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)


def supervise(command, environment, root, phase, seconds, rss_cap, family_cap, stop_file):
    started = time.monotonic()
    peak_rss = peak_wal = peak_family = peak_exports = 0
    reason = "exited"
    samples = []
    last_progress = started
    stop_requested = {"value": False}

    def request_stop(signum, _frame):
        stop_requested["value"] = True
        try:
            stop_file.touch(exist_ok=True)
        except OSError:
            pass

    previous = {signal.SIGINT: signal.signal(signal.SIGINT, request_stop), signal.SIGTERM: signal.signal(signal.SIGTERM, request_stop)}
    # Fresh log and metrics only; never truncate evidence from a previous run.
    with (root / f"{phase}.log").open("xb") as output:
        process = subprocess.Popen(command, env=environment, cwd=root, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while process.poll() is None:
                rss = group_rss(process.pid)
                sizes = database_bytes(root)
                exports = tree_bytes(root / "exports") if (root / "exports").exists() else 0
                peak_rss, peak_wal = max(peak_rss, rss), max(peak_wal, sizes["-wal"])
                peak_family = max(peak_family, sum(sizes.values()))
                peak_exports = max(peak_exports, exports)
                disk = os.statvfs(root)
                log_size = (root / f"{phase}.log").stat().st_size
                if rss > rss_cap:
                    reason = "rss-limit"
                elif time.monotonic() - started > seconds:
                    reason = "time-limit"
                elif disk.f_bavail * disk.f_frsize < 32 * GIB:
                    reason = "free-space-floor"
                elif sum(sizes.values()) > family_cap:
                    reason = "database-family-limit"
                elif exports > 2 * GIB:
                    reason = "export-limit"
                elif log_size > 64 * MIB:
                    reason = "output-limit"
                if reason != "exited":
                    terminate_owned_group(process)
                    break
                if stop_requested["value"] and time.monotonic() - started > seconds + 120:
                    reason = "stop-grace-expired"
                    terminate_owned_group(process)
                    break
                if time.monotonic() - last_progress >= 60:
                    sample = {"kind": "supervisor-progress", "elapsedSeconds": round(time.monotonic() - started, 1),
                              "processGroupRSSBytes": rss, "databaseFamilyBytes": sum(sizes.values()), "walBytes": sizes["-wal"],
                              "exportBytes": exports, "logBytes": log_size, "stopRequested": stop_requested["value"]}
                    samples.append(sample)
                    emit(sample)
                    last_progress = time.monotonic()
                time.sleep(1.0)
        except BaseException:
            terminate_owned_group(process)
            raise
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)
    result = {"schema": "disk-steward-soak-supervisor-v1", "phase": phase, "root": str(root),
              "reason": reason, "exitCode": process.returncode, "seconds": time.monotonic() - started,
              "peakProcessGroupRSSBytes": peak_rss, "peakSampledWALBytes": peak_wal,
              "peakSampledDatabaseFamilyBytes": peak_family, "peakExportBytes": peak_exports,
              "pollIntervalSeconds": 1.0, "rssStopBytes": rss_cap, "databaseFamilyStopBytes": family_cap,
              "timeoutSeconds": seconds, "stopRequested": stop_requested["value"], "command": command}
    (root / f"{phase}-supervision.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    (root / f"{phase}-samples.jsonl").write_text("".join(json.dumps(s, sort_keys=True) + "\n" for s in samples))
    emit(result)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", type=Path, help="Built package copy holding .build/arm64-apple-macosx/release/DiskStewardPackageTests.xctest")
    parser.add_argument("--files", type=int, default=10_000)
    parser.add_argument("--buckets", type=int, default=16)
    parser.add_argument("--seconds", type=float, default=600)
    parser.add_argument("--cap-mib", type=int, default=512)
    parser.add_argument("--rss-cap-mib", type=int, default=600)
    parser.add_argument("--family-cap-gib", type=int, default=4)
    parser.add_argument("--churn", type=int, default=200)
    parser.add_argument("--pause-seconds", type=float, default=15)
    parser.add_argument("--export-every", type=int, default=10)
    parser.add_argument("--retention-every", type=int, default=20)
    parser.add_argument("--worker-fixture", type=Path)
    parser.add_argument("--token")
    args = parser.parse_args()
    if args.worker_fixture:
        fixture_worker(args.worker_fixture, args.token, args.files, args.buckets)
        return 0
    if args.workspace is None:
        parser.error("--workspace is required")
    if not (0 < args.seconds <= 172_800):
        parser.error("--seconds must be within two days")
    if not (0 < args.files <= 200_000):
        parser.error("--files must be at most 200,000 for a soak")
    bundle = args.workspace / ".build/arm64-apple-macosx/release/DiskStewardPackageTests.xctest"
    if not bundle.is_dir():
        raise SystemExit(f"Missing built test bundle: {bundle}")
    root = Path(tempfile.mkdtemp(prefix="disk-steward-572-soak.", dir="/private/tmp"))
    os.chmod(root, 0o700)
    token = str(uuid.uuid4())
    (root / "owner-token").write_text(token)
    stop_file = root / "stop"
    emit({"kind": "created", "root": str(root), "files": args.files, "buckets": args.buckets, "seconds": args.seconds})
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(root), "TMPDIR": str(root), "LANG": "en_US.UTF-8"}
    fixture = supervise([sys.executable, str(Path(__file__).resolve()), "--worker-fixture", str(root),
                         "--token", token, "--files", str(args.files), "--buckets", str(args.buckets)],
                        environment, root, "fixture", 3_600, 512 * MIB, 6 * GIB, stop_file)
    if fixture["exitCode"] != 0:
        return 2
    environment.update({"DISK_STEWARD_SOAK_BENCHMARK": "supervised-v1", "DISK_STEWARD_SOAK_ROOT": str(root),
                        "DISK_STEWARD_SOAK_TOKEN": token, "DISK_STEWARD_SOAK_SECONDS": str(args.seconds),
                        "DISK_STEWARD_SOAK_CAP_MIB": str(args.cap_mib), "DISK_STEWARD_SOAK_RSS_MIB": str(args.rss_cap_mib),
                        "DISK_STEWARD_SOAK_CHURN": str(args.churn), "DISK_STEWARD_SOAK_BUCKETS": str(args.buckets),
                        "DISK_STEWARD_SOAK_PAUSE_SECONDS": str(args.pause_seconds), "DISK_STEWARD_SOAK_EXPORT_EVERY": str(args.export_every),
                        "DISK_STEWARD_SOAK_RETENTION_EVERY": str(args.retention_every)})
    test = "PerformanceTests.SoakBenchmarkTests/testOptInProductionSoak"
    result = supervise(["/usr/bin/nice", "-n", "10", "/usr/bin/xcrun", "xctest", "-XCTest", test, str(bundle)],
                       environment, root, "soak", args.seconds + 900, args.rss_cap_mib * MIB, args.family_cap_gib * GIB, stop_file)
    rows = [json.loads(line) for line in (root / "soak.log").read_text(errors="replace").splitlines()
            if line.startswith("{") and '"disk-steward-soak-v1"' in line]
    final = next((row for row in reversed(rows) if row.get("kind") == "result"), None)
    (root / "result.json").write_text(json.dumps(final or {"status": "missing"}, indent=2, sort_keys=True) + "\n")
    emit(final or {"kind": "result", "status": "missing"})
    return 0 if result["exitCode"] == 0 and final and final.get("status") in ("completed", "external-stop") else 1


if __name__ == "__main__":
    sys.exit(main())
