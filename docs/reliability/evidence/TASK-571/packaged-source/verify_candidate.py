#!/usr/bin/env python3
"""Credential-free source verification; never installs, signs or launches normally.

Isolation prevents accidental test interference, not malicious source execution.
Run untrusted pull requests only on disposable hosted runners, never self-hosted.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time


INPUTS = ("Package.swift", "Sources", "Tests", "Config", "Scripts", "DiskSteward.xcodeproj",
          "Integrations", "Schemas", "Fixtures", "Resources", "Extensions", "docs/architecture",
          "docs/release", ".github/workflows")
SENTINEL_TEST = "testSmokeStartupPreservesLiveFixtureEndpointAndAllSentinelState"
MAX_INPUT_ENTRIES = 10000
UPGRADE_TESTS = (
    "testHistoricalOccurrenceBoundsMigrateWithoutInventingLowerEvidence",
    "testActualV5AndV6BackfillAcrossBatchBoundaryWithoutReplayingUnprovenMembership",
    "testActualHistoricalSchemasRecoverAtEveryAtomicMigrationCheckpoint",
    "testActualHistoricalSchemasRemainIntactWhenMigrationHasNoHeadroom",
)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def input_manifest(repository):
    entries, total, visited = [], 0, 0
    for relative in INPUTS:
        base = repository / relative
        if not base.exists():
            raise ValueError("Missing candidate input: " + relative)
        if base.resolve() != base or base.is_symlink():
            raise ValueError("Candidate input path must not contain symlinks: " + relative)
        paths = [base] if base.is_file() else base.rglob("*")
        for path in paths:
            visited += 1
            if visited > MAX_INPUT_ENTRIES:
                raise ValueError("Candidate input budget exceeded")
            metadata = path.lstat()
            if stat.S_ISDIR(metadata.st_mode):
                continue
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                raise ValueError("Candidate inputs must be regular single-link files: " + str(path))
            total += metadata.st_size
            if metadata.st_size > 8 * 1024**2 or total > 64 * 1024**2:
                raise ValueError("Candidate input budget exceeded")
            entries.append({"path": str(path.relative_to(repository)), "bytes": metadata.st_size,
                            "mode": stat.S_IMODE(metadata.st_mode), "sha256": sha256(path)})
    return sorted(entries, key=lambda entry: entry["path"])


def manifest_digest(entries):
    return hashlib.sha256(json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def copy_inputs(repository, destination, manifest):
    destination.mkdir(mode=0o700)
    for entry in manifest:
        target = destination / entry["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(repository / entry["path"], target)
        target.chmod(entry["mode"])
    if input_manifest(destination) != manifest or input_manifest(repository) != manifest:
        raise ValueError("Candidate inputs changed during snapshot")


def clean_environment(scratch):
    # Deliberately no inherited credentials, native-client/scale opt-ins, export
    # destinations, signing identities, user shell PATH or developer overrides.
    temporary = scratch / "temporary"
    temporary.mkdir(mode=0o700, exist_ok=True)
    return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": str(temporary),
            # XcodeGen requires USER. Derive the account identity, never inherit
            # a caller override; no home directory or credentials are forwarded.
            "USER": pwd.getpwuid(os.getuid()).pw_name,
            "CLANG_MODULE_CACHE_PATH": str(scratch / "module-cache"),
            "PYTHONDONTWRITEBYTECODE": "1", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            # Fail closed if a test mistakenly launches normal application mode.
            "DISK_STEWARD_SUPPORT_DIRECTORY": str(scratch / "normal-launch-forbidden"),
            "DISK_STEWARD_SOCKET_PATH": str(scratch / "never-listening.sock")}


def run_command(command, cwd, environment, log, seconds, maximum_log_bytes=8 * 1024**2, stdin_path=None):
    started = time.monotonic()
    reason = None
    retained = 0
    with log.open("xb") as output:
        # Small owned transcript files avoid a blocking pipe write before output
        # draining starts. The helper receives EOF after the transcript.
        source = stdin_path.open("rb") if stdin_path else None
        try:
            child = subprocess.Popen(command, cwd=cwd, env=environment,
                                     stdin=source if source else subprocess.DEVNULL,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        finally:
            if source:
                source.close()
        selector = selectors.DefaultSelector()
        selector.register(child.stdout, selectors.EVENT_READ)
        try:
            while True:
                if time.monotonic() - started >= seconds:
                    reason = "timeout"
                    break
                if selector.select(timeout=0.05):
                    data = os.read(child.stdout.fileno(), 65536)
                    if not data:
                        break
                    remaining = maximum_log_bytes - retained
                    output.write(data[:remaining])
                    retained += min(len(data), remaining)
                    if len(data) > remaining:
                        reason = "output-limit"
                        break
            if reason is None:
                try:
                    child.wait(timeout=max(0.01, seconds - (time.monotonic() - started)))
                except subprocess.TimeoutExpired:
                    reason = "timeout"
        finally:
            selector.close()
            child.stdout.close()
            # Own session only, including an accidentally retained descendant.
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait(timeout=5)
    return {"command": command, "exitCode": child.returncode, "stopReason": reason,
            "seconds": time.monotonic() - started, "log": log.name,
            "logSHA256": sha256(log), "passed": child.returncode == 0 and reason is None}


def sentinel_passed(log):
    # A discovered/skipped test name is not evidence that the scenario ran.
    return re.search(r"Test Case [^\n]*\b" + SENTINEL_TEST + r"[^\n]* passed", log.read_text()) is not None


def upgrade_evidence(log, repository):
    content = log.read_text()
    missing = [name for name in UPGRADE_TESTS if re.search(
        r"Test Case [^\n]*HistoricalMigrationTests[ .]" + name + r"[\]' ]+ passed", content) is None]
    if missing:
        raise ValueError("Required synthetic upgrade tests did not pass: " + ", ".join(missing))
    sources = ("Tests/DiskStewardCoreTests/EvidenceStore/HistoricalMigrationTests.swift",
               "Tests/DiskStewardCoreTests/EvidenceStore/HistoricalEvidenceSchema.swift")
    return {"status": "passed", "passedCases": list(UPGRADE_TESTS),
            "fixtureSourceHashes": {path: sha256(repository / path) for path in sources},
            "scope": "Synthetic v5/v6 forward upgrade, 513 staged rows, four interruption boundaries, no-headroom refusal.",
            "rollback": "not-verified",
            "limitations": ["No old executable is launched; interrupted forward recovery is not downgrade rollback.",
                            "No near-cap, real user database or large conversion is exercised by these cases.",
                            "Current migration does not itself retain the pre-upgrade database after a successful switch."]}


def create_output(path, repository):
    if not path.is_absolute() or path.parent.resolve(strict=True) != path.parent:
        raise ValueError("Output needs an absolute canonical existing parent")
    if path == repository or repository in path.parents or path in repository.parents:
        raise ValueError("Output must be outside the source checkout")
    path.mkdir(mode=0o700)  # Exclusive: never overwrite or follow an existing leaf.
    return path


def compatibility_notes(repository):
    source = (repository / "Sources/DiskStewardCore/EvidenceStore/EvidenceStore.swift").read_text()
    package = (repository / "Package.swift").read_text()
    return {"declaredMacOSMajorVersions": re.findall(r"\.macOS\(\.v(\d+)\)", package),
            "schemaVersionAssignments": sorted(set(map(int, re.findall(r"PRAGMA user_version\s*=\s*(\d+)", source)))),
            "interpretation": "Source declarations only; not a backwards-compatibility guarantee.",
            "rollbackStatus": "not-verified",
            "rollbackPrerequisites": ["Consistent old-schema backup with measured free-space headroom.",
                                      "Exact old and new binary hashes and supported schema contract.",
                                      "Interruption, failed conversion and old-binary restore rehearsals on synthetic stores.",
                                      "Never open a new schema with an old binary absent verified compatibility."]}


def verify(repository, output, xcodegen=None):
    environment = clean_environment(output)
    report = {"schema": "disk-steward-candidate-verification-v1", "status": "failed",
              "releaseReadiness": "not-assessed", "checks": [], "artifacts": [],
              "packagedApp": "not-tested", "notarization": "not-tested",
              "limitations": ["No installation, production evidence access, native-client setup or EndpointSecurity activation.",
                              "Fixture isolation is not a security sandbox for hostile source.",
                              "Passing CI does not replace scale, overnight, native-client, packaged-app or rollback gates."]}
    scratch = Path(tempfile.mkdtemp(prefix="ds-ci-", dir="/private/tmp"))
    report["scratch"] = str(scratch)
    try:
        if shutil.disk_usage(scratch).free < 8 * 1024**3:
            raise ValueError("Verification needs at least 8 GiB free scratch space")
        manifest = input_manifest(repository)
        report["inputManifest"] = manifest
        report["inputSHA256"] = manifest_digest(manifest)
        report["revision"] = subprocess.check_output(["/usr/bin/git", "rev-parse", "HEAD"], cwd=repository,
                                                     env=environment, text=True, timeout=5).strip()
        report["dirtyWorktree"] = bool(subprocess.check_output(["/usr/bin/git", "status", "--porcelain", "--untracked-files=normal"],
                                                              cwd=repository, env=environment, timeout=5))
        snapshot = scratch / "project"
        copy_inputs(repository, snapshot, manifest)
        report["compatibility"] = compatibility_notes(snapshot)
        swift_paths = ["--cache-path", str(scratch / "swift-cache"),
                       "--config-path", str(scratch / "swift-config"),
                       "--security-path", str(scratch / "swift-security")]
        stages = [
            ("harness", [sys.executable, "-m", "unittest", "discover", "-s", "Scripts/Testing", "-p", "test_*.py"], 30),
            ("toolchain", ["/usr/bin/swift", "--version"], 30),
            ("manifest", ["/usr/bin/swift", "package"] + swift_paths + ["dump-package"], 60),
            ("entitlements", ["/usr/bin/plutil", "-lint", "Config/Entitlements/DiskStewardApp.entitlements", "Config/Entitlements/DiskStewardEndpoint.entitlements"], 30),
            ("build", ["/usr/bin/swift", "build"] + swift_paths + ["--disable-sandbox", "--jobs", "2"], 600),
            ("tests", ["/usr/bin/swift", "test"] + swift_paths + ["--disable-sandbox", "--jobs", "2"], 300),
        ]
        for label, command, timeout in stages:
            print("Verifying " + label, flush=True)
            check = run_command(command, snapshot, environment, output / (label + ".log"), timeout)
            check["stage"] = label
            report["checks"].append(check)
            if not check["passed"]:
                raise ValueError("Verification failed at " + label + "; inspect its log")
        report["sentinelPreserved"] = sentinel_passed(output / "tests.log")
        if not report["sentinelPreserved"]:
            raise ValueError("Required live-endpoint/sentinel smoke scenario did not pass")
        report["syntheticUpgrade"] = upgrade_evidence(output / "tests.log", snapshot)
        for name in ("DiskStewardApp", "disk-witness-mcp"):
            binary = (snapshot / ".build/debug" / name).resolve(strict=True)
            if snapshot not in binary.parents or not binary.is_file():
                raise ValueError("Unexpected build artifact")
            report["artifacts"].append({"product": name, "sha256": sha256(binary), "bytes": binary.stat().st_size,
                                        "configuration": "debug", "distributionReady": False})
        if xcodegen is not None:
            from verify_packaged_candidate import verify_package
            report["packagedApp"] = {"status": "failed"}
            verify_package(snapshot, scratch, output, environment, manifest, xcodegen,
                           report["packagedApp"], report["checks"])
        if input_manifest(repository) != manifest or input_manifest(snapshot) != manifest:
            raise ValueError("Candidate inputs changed during verification")
        report["status"] = "passed"
    except Exception as error:
        report["error"] = str(error)
    finally:
        # Retain exact logs/report on failure; the owned scratch path is explicit.
        with (output / "candidate.json").open("x") as stream:
            json.dump(report, stream, indent=2, sort_keys=True)
            stream.write("\n")
    return report["status"] == "passed"


def main():
    def cancel(_signal, _frame):
        raise InterruptedError("Verification cancelled")

    signal.signal(signal.SIGTERM, cancel)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New output directory outside the source checkout")
    parser.add_argument("--xcodegen", type=Path, help="Absolute XcodeGen executable; also build and smoke-test an unsigned CI app")
    arguments = parser.parse_args()
    repository = Path(__file__).resolve().parents[2]
    output = create_output(arguments.output, repository)
    success = verify(repository, output, arguments.xcodegen)
    print("Candidate evidence: " + str(output / "candidate.json"))
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
