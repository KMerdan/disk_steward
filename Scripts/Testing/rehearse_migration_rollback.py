raise SystemExit("Legacy rollback admission is closed; see Scripts/Testing/SUPERVISION.md")

"""Migration and compatible-binary rollback rehearsal (TASK-572 / FIND-ROLLBACK).

Everything happens inside one fresh private directory under /private/tmp. The
rehearsal never opens a production store, never launches the app, and never
opens a newer schema with an older binary in place.

Steps, each recorded with exit codes, outputs and SHA-256 hashes:
  1. Export the compatible baseline source (a git ref, default HEAD) and copy
     the candidate inputs; build one small "store-probe" executable against
     each DiskStewardCore. The probe only uses public API that both share.
  2. The baseline probe creates a synthetic old-schema store and seeds it.
  3. The baseline probe takes a SQLite-consistent backup (backup API, committed
     WAL included) into a separate directory; integrity is validated by both the
     probe and the sqlite3 CLI. The backup is never opened again in place.
  4. For every migration checkpoint the candidate probe migrates a fresh copy of
     the backup, is interrupted at that checkpoint, and the next open recovers
     and completes; each result is validated (schema, integrity, row counts).
  5. The baseline probe opens a scratch copy of the migrated store and must
     refuse it explicitly; the copy's hash must be unchanged afterwards.
  6. Rollback: the backup is restored into a separate directory, the baseline
     probe opens it (compatible), and the candidate probe migrates it forward
     again, proving rollback followed by upgrade.

Usage: rehearse_migration_rollback.py --output /private/tmp/<new-leaf> [--baseline-ref HEAD] [--seed 300]

--negative-oracle runs the same rehearsal with the baseline probe standing in
for the candidate: nothing migrates, so the rehearsal must report failure
(schema not advanced, no refusal). It proves the rehearsal cannot pass vacuously.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

from verify_candidate import copy_inputs, input_manifest, manifest_digest

REPOSITORY = Path(__file__).resolve().parents[2]
CHECKPOINTS = ["after-consistent-copy", "after-shadow-validation", "before-atomic-switch", "after-atomic-switch"]
PROBE_SOURCE = r'''
import Foundation
import DiskStewardCore

struct Interrupted: Error {}

@main
struct StoreProbe {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else { fail("usage: store-probe <open|create|backup> <db> [--seed N] [--interrupt STAGE] [--destination PATH]", code: 64) }
        let command = arguments.removeFirst()
        guard !arguments.isEmpty else { fail("missing database path", code: 64) }
        let database = URL(fileURLWithPath: arguments.removeFirst())
        var seed = 0
        var interrupt: String? = nil
        var destination: URL? = nil
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            guard !arguments.isEmpty else { fail("missing value for \(flag)", code: 64) }
            let value = arguments.removeFirst()
            switch flag {
            case "--seed": seed = Int(value) ?? 0
            case "--interrupt": interrupt = value
            case "--destination": destination = URL(fileURLWithPath: value)
            default: fail("unknown flag \(flag)", code: 64)
            }
        }
        let stage = interrupt
        do {
            let store = try EvidenceStore(url: database, migrationCheckpoint: { reached in
                if let stage, reached == stage { throw Interrupted() }
            })
            if command == "create", seed > 0 {
                let base = Date(timeIntervalSince1970: 1_900_000_000)
                let events = (0..<seed).map { index in
                    EvidenceStoreEvent(
                        eventID: "rehearsal-\(index)", observedAt: base.addingTimeInterval(Double(index)), operation: .writeSummary,
                        path: "/rehearsal/fixture/segment-\(index % 17).bin", logicalDelta: 4_096, allocatedDelta: 4_096,
                        consumerCategory: "developer-cache", confidence: .inferred, isAnomaly: false)
                }
                try await store.insert(events)
            }
            if command == "backup" {
                guard let destination else { fail("backup needs --destination", code: 64) }
                try await store.backup(to: destination)
            }
            let diagnostics = try await store.diagnostics()
            let current = try await store.currentFiles()
            await store.close()
            let report: [String: Any] = [
                "ok": true, "command": command, "database": database.path,
                "schemaVersion": diagnostics.schemaVersion, "integrity": diagnostics.integrity, "journalMode": diagnostics.journalMode,
                "eventCount": diagnostics.eventCount, "snapshotCount": diagnostics.snapshotCount, "currentFileCount": current.count,
                "storageBytes": diagnostics.storageBytes, "retentionRunCount": diagnostics.retentionRunCount,
            ]
            emit(report); exit(0)
        } catch is Interrupted {
            emit(["ok": false, "command": command, "database": database.path, "interruptedAt": stage ?? ""]); exit(4)
        } catch {
            let message = String(describing: error)
            let refused = message.contains("newer than this application")
            emit(["ok": false, "command": command, "database": database.path, "error": message, "refusedNewerSchema": refused]); exit(refused ? 3 : 2)
        }
    }

    static func emit(_ report: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    static func fail(_ message: String, code: Int32) -> Never {
        emit(["ok": false, "error": message]); exit(code)
    }
}
'''


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def family_hashes(database):
    return {suffix or "main": (sha256(str(database) + suffix) if os.path.exists(str(database) + suffix) else None) for suffix in ("", "-wal", "-shm")}


def run(command, cwd, env, log, timeout):
    started = time.monotonic()
    with open(log, "ab") as stream:
        stream.write(("$ " + " ".join(command) + "\n").encode())
        process = subprocess.run(command, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        stream.write(process.stdout)
        stream.write(b"\n")
    text = process.stdout.decode(errors="replace")
    payload = None
    for line in reversed(text.splitlines()):
        if line.startswith("{"):
            try:
                payload = json.loads(line)
            except ValueError:
                payload = None
            break
    return {"command": command, "exitCode": process.returncode, "seconds": round(time.monotonic() - started, 3), "output": payload, "tail": text[-600:]}


def clean_environment(scratch):
    return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(scratch / "home"), "TMPDIR": str(scratch / "tmp"),
            "LANG": "en_US.UTF-8", "SWIFTPM_ENABLE_SANDBOX": "0", "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}


def write_probe(package_dir, dependency_dir):
    (package_dir / "Sources" / "store-probe").mkdir(parents=True, exist_ok=True)
    (package_dir / "Package.swift").write_text(
        "// swift-tools-version: 6.0\nimport PackageDescription\n"
        "let package = Package(name: \"store-probe\", platforms: [.macOS(.v13)],\n"
        f"    dependencies: [.package(name: \"DiskSteward\", path: \"{dependency_dir}\")],\n"
        "    targets: [.executableTarget(name: \"store-probe\", dependencies: [.product(name: \"DiskStewardCore\", package: \"DiskSteward\")])])\n")
    (package_dir / "Sources" / "store-probe" / "main.swift").write_text(PROBE_SOURCE)


def build_probe(package_dir, scratch, env, log):
    command = ["/usr/bin/swift", "build", "-c", "release", "--package-path", str(package_dir), "--cache-path", str(scratch / "cache"),
               "--config-path", str(scratch / "config"), "--security-path", str(scratch / "security"), "--disable-sandbox", "--jobs", "3"]
    result = run(command, package_dir, env, log, 1800)
    binary = package_dir / ".build" / "release" / "store-probe"
    if result["exitCode"] != 0 or not binary.exists():
        raise RuntimeError("probe build failed: " + result["tail"])
    return binary


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--baseline-ref", default="HEAD")
    parser.add_argument("--seed", type=int, default=300)
    parser.add_argument("--negative-oracle", action="store_true")
    args = parser.parse_args()
    output = Path(args.output)
    if not output.is_absolute() or not str(output).startswith("/private/tmp/") or output.exists():
        raise SystemExit("--output must be a new leaf under /private/tmp")
    output.mkdir(mode=0o700)
    for name in ("home", "tmp", "cache", "config", "security"):
        (output / name).mkdir()
    env = clean_environment(output)
    log = output / "rehearsal.log"
    report = {"schema": "disk-steward-rollback-rehearsal-v1", "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "output": str(output), "steps": []}

    baseline_dir = output / "baseline"
    baseline_dir.mkdir()
    baseline_sha = subprocess.run(["git", "rev-parse", args.baseline_ref], cwd=REPOSITORY, capture_output=True, text=True, check=True).stdout.strip()
    archive = subprocess.run(["git", "archive", "--format=tar", baseline_sha], cwd=REPOSITORY, capture_output=True, check=True).stdout
    subprocess.run(["/usr/bin/tar", "-x", "-C", str(baseline_dir)], input=archive, check=True)
    candidate_dir = output / "candidate"
    manifest = input_manifest(REPOSITORY)
    copy_inputs(REPOSITORY, candidate_dir, manifest)
    report["baseline"] = {"ref": args.baseline_ref, "commit": baseline_sha}
    report["candidate"] = {"inputSHA256": manifest_digest(manifest)}

    probes = {}
    for name, dependency in (("baseline", baseline_dir), ("candidate", candidate_dir)):
        package = output / f"probe-{name}"
        write_probe(package, dependency)
        started = time.monotonic()
        probes[name] = build_probe(package, output, env, log)
        report["steps"].append({"step": f"build-probe-{name}", "seconds": round(time.monotonic() - started, 1), "binary": str(probes[name]), "binarySHA256": sha256(probes[name])})
    if args.negative_oracle:
        probes["candidate"] = probes["baseline"]
        report["negativeOracle"] = "candidate probe replaced by the baseline probe; the rehearsal must fail"

    def probe(name, command, database, **flags):
        argv = [str(probes[name]), command, str(database)]
        for flag, value in flags.items():
            argv += ["--" + flag, str(value)]
        return run(argv, output, env, log, 600)

    def expect(step, result, exit_code, **checks):
        entry = {"step": step, **result}
        problems = []
        if result["exitCode"] != exit_code:
            problems.append(f"exit {result['exitCode']} != {exit_code}")
        payload = result.get("output") or {}
        for key, wanted in checks.items():
            if payload.get(key) != wanted:
                problems.append(f"{key}={payload.get(key)!r} != {wanted!r}")
        entry["problems"] = problems
        report["steps"].append(entry)
        return not problems

    ok = True
    # 2. synthetic old-schema fixture written by the compatible baseline
    fixture = output / "fixture" / "evidence.sqlite"
    fixture.parent.mkdir()
    created = probe("baseline", "create", fixture, seed=args.seed)
    ok &= expect("baseline-create-fixture", created, 0, ok=True, eventCount=args.seed, integrity="ok")
    old_version = (created.get("output") or {}).get("schemaVersion")
    report["oldSchemaVersion"] = old_version

    # 3. SQLite-consistent backup into a separate directory, validated twice
    backup = output / "backup" / "evidence.sqlite"
    backup.parent.mkdir()
    backed = probe("baseline", "backup", fixture, destination=backup)
    ok &= expect("baseline-backup", backed, 0, ok=True, eventCount=args.seed)
    cli = subprocess.run(["/usr/bin/sqlite3", str(backup), "PRAGMA integrity_check; PRAGMA user_version; SELECT COUNT(*) FROM events;"], capture_output=True, text=True, env=env)
    cli_lines = cli.stdout.split()
    report["steps"].append({"step": "sqlite3-validate-backup", "exitCode": cli.returncode, "output": cli_lines, "problems": [] if cli_lines == ["ok", str(old_version), str(args.seed)] else [f"unexpected {cli_lines}"]})
    ok &= cli_lines == ["ok", str(old_version), str(args.seed)]
    backup_hashes = family_hashes(backup)
    report["backupHashes"] = backup_hashes

    def fresh_copy(name):
        target = output / name / "evidence.sqlite"
        target.parent.mkdir()
        shutil.copyfile(backup, target)
        return target

    # 4. interrupted migrations at every checkpoint, then recovery
    new_version = None
    for stage in CHECKPOINTS:
        work = fresh_copy(f"work-{stage}")
        interrupted = probe("candidate", "open", work, interrupt=stage)
        ok &= expect(f"candidate-migrate-interrupted-{stage}", interrupted, 4, ok=False, interruptedAt=stage)
        recovered = probe("candidate", "open", work)
        ok &= expect(f"candidate-recover-{stage}", recovered, 0, ok=True, integrity="ok", eventCount=args.seed)
        new_version = (recovered.get("output") or {}).get("schemaVersion")
    work = fresh_copy("work-uninterrupted")
    migrated = probe("candidate", "open", work)
    ok &= expect("candidate-migrate-uninterrupted", migrated, 0, ok=True, integrity="ok", eventCount=args.seed)
    report["newSchemaVersion"] = new_version
    if not (isinstance(old_version, int) and isinstance(new_version, int) and new_version > old_version):
        ok = False
        report["steps"].append({"step": "schema-advanced", "problems": [f"old {old_version} new {new_version}"]})

    # 5. the old binary must refuse the newer schema explicitly and leave it untouched
    scratch = output / "scratch-newer" / "evidence.sqlite"
    scratch.parent.mkdir()
    shutil.copyfile(work, scratch)
    before = family_hashes(scratch)
    refused = probe("baseline", "open", scratch)
    ok &= expect("baseline-refuses-newer-schema", refused, 3, ok=False, refusedNewerSchema=True)
    after = family_hashes(scratch)
    untouched = before["main"] == after["main"]
    report["steps"].append({"step": "newer-schema-untouched-by-refusal", "before": before, "after": after, "problems": [] if untouched else ["main database file changed"]})
    ok &= untouched

    # 6. rollback: restore the backup elsewhere, old binary opens it, candidate migrates it forward again
    restore = fresh_copy("restore")
    rolled_back = probe("baseline", "open", restore)
    ok &= expect("baseline-opens-restored-backup", rolled_back, 0, ok=True, schemaVersion=old_version, integrity="ok", eventCount=args.seed)
    forward = probe("candidate", "open", restore)
    ok &= expect("candidate-migrates-restored-backup", forward, 0, ok=True, schemaVersion=new_version, integrity="ok", eventCount=args.seed)
    still = family_hashes(backup)
    report["steps"].append({"step": "backup-never-modified", "before": backup_hashes, "after": still, "problems": [] if still["main"] == backup_hashes["main"] else ["backup main file changed"]})
    ok &= still["main"] == backup_hashes["main"]

    report["passed"] = bool(ok)
    report["completedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    (output / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True))
    print(json.dumps({"passed": report["passed"], "oldSchemaVersion": old_version, "newSchemaVersion": new_version, "report": str(output / "report.json")}))
    if args.negative_oracle:
        return 0 if not ok else 1
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
