#!/usr/bin/env python3
"""Create bounded disposable fixtures; supervise ONE already-built XCTest.

No watched folders, user settings, production DB, app launch, or client configs.
Artifacts stay in a new /private/tmp leaf. This script never deletes a tree.
Only the process group created by this invocation can be terminated.
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
    if (root.parent != Path("/private/tmp") or not root.name.startswith("disk-steward-530-scale.")
            or root.resolve() != root or (root / "owner-token").read_text() != token):
        raise ValueError("Not a supervisor-owned benchmark leaf")


def fixture_worker(root, token, count, shape):
    validate_root(root, token)
    os.nice(10)
    directory = root / "fixture"
    directory.mkdir()  # Never reuse/overwrite.
    parents = [directory]
    if shape == "deep":
        for _ in range(31):
            child = parents[-1] / "level"
            child.mkdir()
            parents.append(child)
    for index in range(count):
        parent = parents[index % len(parents)]
        path = parent / f"item-{index:09d}"
        if shape == "fanout":
            path.mkdir()
        else:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.close(descriptor)
        if index % 10_000 == 0:
            emit({"kind": "fixture-progress", "entries": index + 1})
    manifest = {"count": count, "shape": shape, "files": 0 if shape == "fanout" else count,
                "directories": count + 1 if shape == "fanout" else len(parents), "complete": True}
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
        path = root / ("baseline/evidence.sqlite" + suffix)
        try:
            sizes[suffix or "db"] = path.stat().st_size
        except FileNotFoundError:
            sizes[suffix or "db"] = 0
    return sizes


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
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)


def supervise(command, environment, root, phase, seconds, rss_cap):
    started = time.monotonic()
    peak_rss = peak_wal = peak_family = 0
    reason = "exited"
    # Fresh log and metrics only; never truncate evidence from a previous run.
    with (root / f"{phase}.log").open("xb") as output:
        process = subprocess.Popen(command, env=environment, cwd=root, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while process.poll() is None:
                rss = group_rss(process.pid)
                sizes = database_bytes(root)
                peak_rss, peak_wal = max(peak_rss, rss), max(peak_wal, sizes["-wal"])
                peak_family = max(peak_family, sum(sizes.values()))
                disk = os.statvfs(root)
                if rss > rss_cap:
                    reason = "rss-limit"
                elif time.monotonic() - started > seconds:
                    reason = "time-limit"
                elif disk.f_bavail * disk.f_frsize < 32 * GIB:
                    reason = "free-space-floor"
                elif sum(sizes.values()) > 768 * MIB:
                    reason = "database-family-limit"
                elif (root / f"{phase}.log").stat().st_size > 8 * MIB:
                    reason = "output-limit"
                if reason != "exited":
                    terminate_owned_group(process)
                    break
                time.sleep(0.1)
        except BaseException:
            terminate_owned_group(process)
            raise
    result = {"schema": "disk-steward-scale-supervisor-v1", "phase": phase, "root": str(root),
              "reason": reason, "exitCode": process.returncode, "seconds": time.monotonic() - started,
              "peakProcessGroupRSSBytes": peak_rss, "peakSampledWALBytes": peak_wal,
              "peakSampledDatabaseFamilyBytes": peak_family, "pollIntervalSeconds": 0.1,
              "rssStopBytes": rss_cap, "timeoutSeconds": seconds, "command": command}
    (root / f"{phase}-supervision.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    emit(result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path)
    parser.add_argument("--count", type=int, default=10_000)
    parser.add_argument("--shape", choices=["wide", "deep", "fanout"], default="wide")
    parser.add_argument("--seconds", type=float, default=45)
    parser.add_argument("--variant", choices=["baseline", "path-index", "stream", "spool"], default="baseline")
    parser.add_argument("--generations", type=int, choices=[1, 2], default=1)
    parser.add_argument("--worker-fixture", type=Path)
    parser.add_argument("--token")
    args = parser.parse_args()
    if not 1 <= args.count <= 1_000_000 or not 0 < args.seconds <= 120:
        parser.error("count must be 1..1M and seconds in (0,120]")
    if args.generations != 1 and args.variant in ("baseline", "path-index"):
        parser.error("Two-generation measurement is currently prototype-only")
    if args.worker_fixture:
        fixture_worker(args.worker_fixture, args.token, args.count, args.shape)
        return
    if args.workspace is None:
        parser.error("--workspace must name a disposable, already-built source copy")
    workspace = args.workspace.resolve()
    if workspace.parent != Path("/private/tmp") or not workspace.name.startswith("disk-steward-"):
        parser.error("Build workspace must be an explicit /private/tmp/disk-steward-* leaf")
    bundle = workspace / ".build/arm64-apple-macosx/release/DiskStewardPackageTests.xctest"
    if not bundle.is_dir():
        parser.error("Optimized test bundle missing; compile separately with --jobs 2")
    disk = os.statvfs("/private/tmp")
    if disk.f_bavail * disk.f_frsize < 32 * GIB:
        parser.error("Insufficient free space for a safe fixture")
    root = Path(tempfile.mkdtemp(prefix="disk-steward-530-scale.", dir="/private/tmp"))
    token = str(uuid.uuid4())
    (root / "owner-token").write_text(token)
    emit({"kind": "created", "root": str(root), "count": args.count, "shape": args.shape, "variant": args.variant})
    # XCTest can print its environment on invocation failure. Never inherit credentials.
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": str(root),
                   "LANG": "en_US.UTF-8"}
    fixture = supervise([sys.executable, str(Path(__file__).resolve()), "--worker-fixture", str(root),
                         "--token", token, "--count", str(args.count), "--shape", args.shape],
                        environment, root, "fixture", 300, 128 * MIB)
    if fixture["exitCode"] != 0 or not (root / "fixture.json").is_file():
        raise SystemExit("Fixture did not complete; no benchmark started")
    environment.update({"DISK_STEWARD_SCALE_BENCHMARK": "supervised-v1", "DISK_STEWARD_SCALE_ROOT": str(root),
                        "DISK_STEWARD_SCALE_TOKEN": token, "DISK_STEWARD_SCALE_SECONDS": str(args.seconds),
                        "DISK_STEWARD_SCALE_VARIANT": args.variant,
                        "DISK_STEWARD_SCALE_GENERATIONS": str(args.generations),
                        "DISK_STEWARD_SCALE_DIRECTORIES": str(args.count + 1 if args.shape == "fanout" else 32 if args.shape == "deep" else 1),
                        "DISK_STEWARD_SCALE_FILES": "0" if args.shape == "fanout" else str(args.count)})
    test = ("PerformanceTests.BoundedTraversalScaleTests/testOptInBoundedPrototype" if args.variant in ("stream", "spool")
            else "PerformanceTests.ScaleBenchmarkTests/testOptInProductionScan")
    benchmark = supervise(["/usr/bin/nice", "-n", "10", "/usr/bin/xcrun", "xctest", "-XCTest", test, str(bundle)],
                          environment, root, "baseline", args.seconds + 15, 256 * MIB)
    lines = (root / "baseline.log").read_text(errors="replace").splitlines()
    results = [json.loads(line) for line in lines if line.startswith('{"') and '"kind":"result"' in line]
    if benchmark["reason"] == "exited" and (benchmark["exitCode"] != 0 or len(results) != 1):
        raise SystemExit("Benchmark did not produce one verified result; inspect its bounded log")
    for result in results:
        emit(result)


if __name__ == "__main__":
    main()
