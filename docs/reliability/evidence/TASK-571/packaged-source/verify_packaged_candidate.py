"""Unsigned package verification, only for a freshly built candidate source copy.

There is intentionally no arbitrary-app argument and no normal launch mode.
The source runner calls this module after its isolated Swift tests pass.
"""
import fcntl
import json
import os
from pathlib import Path
import plistlib
import socket
import stat
import uuid

from verify_candidate import copy_inputs, input_manifest, manifest_digest, run_command, sha256


SMOKE_FIELDS = {
    "status": "launched", "activation_policy": "accessory", "isolated_smoke": True,
    "detail_sampling_paused": True, "watched_root_count": 0, "agent_access": "off",
    "ipc_service": "off", "settings_persistence": "ephemeral", "notifications_enabled": False,
}
GENERATED_INPUTS = ("DiskSteward.xcodeproj/", "Config/Packaging/DiskSteward-Info.plist")


def validate_generated_inputs(original, generated):
    def unchanged(entries):
        return [item for item in entries if not any(
            item["path"] == prefix or (prefix.endswith("/") and item["path"].startswith(prefix))
            for prefix in GENERATED_INPUTS)]
    if unchanged(original) != unchanged(generated):
        raise ValueError("Project generation modified non-generated candidate inputs")


def bundle_manifest(bundle):
    if bundle.resolve(strict=True) != bundle or not bundle.is_dir():
        raise ValueError("Bundle must be a canonical directory")
    entries, total = [], 0
    for count, path in enumerate(bundle.rglob("*"), 1):
        if count > 10000:
            raise ValueError("Bundle entry budget exceeded")
        metadata = path.lstat()
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise ValueError("Bundle must contain regular single-link files only")
        total += metadata.st_size
        if total > 512 * 1024**2:
            raise ValueError("Bundle byte budget exceeded")
        entries.append({"path": str(path.relative_to(bundle)), "bytes": metadata.st_size,
                        "mode": stat.S_IMODE(metadata.st_mode), "sha256": sha256(path)})
    return sorted(entries, key=lambda item: item["path"])


def validate_smoke(log, temporary, system_temporary=None):
    # Diagnostic lines may accompany AppKit startup, but exactly one JSON object
    # must carry the report. Reject missing, duplicate or wrong-typed fields.
    objects = [json.loads(line) for line in log.read_text().splitlines() if line.startswith("{")]
    if len(objects) != 1 or not isinstance(objects[0], dict):
        raise ValueError("Expected exactly one smoke report")
    report = objects[0]
    for key, value in SMOKE_FIELDS.items():
        if type(report.get(key)) is not type(value) or report[key] != value:
            raise ValueError("Unsafe or missing smoke field: " + key)
    support = Path(report.get("support_directory", ""))
    parents = {temporary.resolve()}
    if system_temporary is not None:
        parents.add(system_temporary.resolve(strict=True))
    try:
        nonce = uuid.UUID(support.name.removeprefix("ds-smoke-"))
    except ValueError as error:
        raise ValueError("Smoke scratch needs a UUID leaf") from error
    if (not support.is_absolute() or support.parent.resolve() not in parents
            or support.name.lower() != "ds-smoke-" + str(nonce) or support.exists() or support.is_symlink()):
        raise ValueError("Smoke scratch was not isolated and removed")
    return report


def helper_transcript():
    return "\n".join(json.dumps(message, separators=(",", ":")) for message in [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "isolated-candidate-check", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "ping"},
    ]) + "\n"


def validate_helper(log):
    frames = [json.loads(line) for line in log.read_text().splitlines()]
    if (len(frames) != 3 or any(not isinstance(frame, dict) for frame in frames)
            or [frame.get("id") for frame in frames] != [1, 2, 3]
            or any(frame.get("jsonrpc") != "2.0" or "error" in frame for frame in frames)):
        raise ValueError("Helper did not complete the exact initialization/list/ping transcript")
    initialized = frames[0].get("result", {})
    if (initialized.get("protocolVersion") != "2025-06-18"
            or initialized.get("serverInfo", {}).get("name") != "disk-witness-mcp"
            or frames[2].get("result") != {}):
        raise ValueError("Unexpected helper identity/protocol/ping result")
    catalog = frames[1].get("result", {}).get("tools", [])
    names = [tool.get("name") for tool in catalog]
    if (not catalog or "get_storage_summary" not in names or len(set(names)) != len(names)
            or any(not isinstance(name, str) or "delete" in name.lower() for name in names)
            or any(tool.get("annotations", {}).get("readOnlyHint") is not True
                   or tool.get("annotations", {}).get("destructiveHint") is not False for tool in catalog)):
        raise ValueError("Unexpected or non-read-only helper catalog")
    return {"status": "passed", "toolNames": names, "appConnectivity": "not-tested",
            "scope": "Bundled executable initialization, read-only catalog and ping; no evidence query."}


def file_identity(path):
    metadata = path.lstat()
    return (metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_size,
            sha256(path) if stat.S_ISREG(metadata.st_mode) else None)


def verify_package(snapshot, scratch, output, environment, manifest, xcodegen, report, checks):
    generator = xcodegen.resolve(strict=True)
    if not xcodegen.is_absolute() or not generator.is_file() or not os.access(generator, os.X_OK):
        raise ValueError("XcodeGen needs an absolute executable path")
    package_source = scratch / "package-source"
    copy_inputs(snapshot, package_source, manifest)
    report.update({"configuration": "CI", "distributionReady": False, "sourceSHA256": manifest_digest(manifest),
                   "generator": {"path": str(generator), "sha256": sha256(generator)},
                   "signing": "disabled", "notarization": "not-tested"})

    def stage(label, command, seconds=60, stdin_path=None, env=None):
        print("Verifying " + label, flush=True)
        check = run_command(command, package_source, env or environment, output / (label + ".log"),
                            seconds, stdin_path=stdin_path)
        check["stage"] = label
        checks.append(check)
        if not check["passed"]:
            raise ValueError("Verification failed at " + label + "; inspect its log")
        return output / (label + ".log")

    stage("package-generator", [str(generator), "--version"])
    stage("package-toolchain", ["/usr/bin/xcodebuild", "-version"])
    # Foundation may use the OS account's temporary directory instead of TMPDIR.
    # Read its authoritative value before launch; never trust a report-provided
    # parent or remove a directory named by the child.
    temporary_log = stage("package-system-temporary", ["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"])
    system_temporary = Path(temporary_log.read_text().strip())
    if not system_temporary.is_absolute() or not system_temporary.is_dir():
        raise ValueError("Cannot establish the OS temporary directory")
    stage("package-project", [str(generator), "generate", "--no-env", "--spec", "Config/Packaging/project.yml",
                              "--project-root", str(package_source), "--project", str(package_source),
                              "--cache-path", str(scratch / "xcodegen-cache")])
    generated = input_manifest(package_source)
    validate_generated_inputs(manifest, generated)
    report["generatedInputManifest"] = generated
    report["generatedInputSHA256"] = manifest_digest(generated)
    derived = scratch / "derived-data"
    stage("package-build", ["/usr/bin/xcodebuild", "-quiet", "-project", "DiskSteward.xcodeproj",
                           "-scheme", "DiskSteward", "-configuration", "CI", "-destination", "platform=macOS",
                           "-derivedDataPath", str(derived), "-clonedSourcePackagesDirPath", str(scratch / "xcode-packages"),
                           "-disableAutomaticPackageResolution", "-jobs", "2", "CODE_SIGNING_ALLOWED=NO",
                           "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "DEVELOPMENT_TEAM=",
                           "COMPILER_INDEX_STORE_ENABLE=NO", "build"], 600)
    bundle = derived / "Build/Products/CI/Disk Steward.app"
    identity = bundle_manifest(bundle)
    report.update({"path": str(bundle), "bundleManifest": identity, "bundleSHA256": manifest_digest(identity)})
    with (bundle / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if (info.get("CFBundleIdentifier") != "com.marudankiji.disksteward"
            or info.get("CFBundleExecutable") != "Disk Steward" or info.get("LSUIElement") is not True):
        raise ValueError("Unexpected packaged app identity")
    report["bundleInfo"] = {key: info.get(key) for key in (
        "CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion")}
    binary = bundle / "Contents/MacOS/Disk Steward"
    helper = bundle / "Contents/Helpers/disk-witness-mcp"
    for label, path in (("app", binary), ("helper", helper)):
        if not path.is_file() or not os.access(path, os.X_OK):
            raise ValueError("Missing packaged executable: " + label)
        stage("package-architecture-" + label, ["/usr/bin/lipo", "-archs", str(path)])

    fixture = scratch / "sentinel"
    fixture.mkdir(mode=0o700)
    sentinels = []
    for relative in ("evidence.sqlite", "monitoring-settings-v1", "monitoring-safety-v1", "agent-access.json",
                     "exports/retained.json", "codex/config.toml", "claude/config.json", "cursor/mcp.json"):
        path = fixture / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("x") as stream:
            stream.write("untouched-" + relative)
        sentinels.append(path)
    endpoint = fixture / "ipc.sock"
    lease = fixture / "application.lock"
    with lease.open("x+") as lock, socket.socket(socket.AF_UNIX) as listener:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        listener.bind(str(endpoint))
        listener.listen(1)
        listener.settimeout(0.05)
        identities = [file_identity(path) for path in sentinels + [endpoint, lease]]
        smoke_environment = dict(environment, DISK_STEWARD_SUPPORT_DIRECTORY=str(fixture),
                                 DISK_STEWARD_SOCKET_PATH=str(endpoint), DISK_STEWARD_CAPTURE_DIR=str(fixture),
                                 DISK_STEWARD_GATE_EVIDENCE=str(fixture))
        smoke_log = stage("package-smoke", [str(binary), "--ui-smoke"], env=smoke_environment)
        report["smoke"] = validate_smoke(smoke_log, Path(environment["TMPDIR"]), system_temporary)
        transcript = scratch / "helper-transcript.jsonl"
        with transcript.open("x") as stream:
            stream.write(helper_transcript())
        # Even protocol-only requests target a non-existent private socket.
        report["helperProtocol"] = validate_helper(stage("package-helper", [str(helper)], stdin_path=transcript))
        if identities != [file_identity(path) for path in sentinels + [endpoint, lease]]:
            raise ValueError("Packaged verification modified sentinel state")
        try:
            connection, _ = listener.accept()
        except socket.timeout:
            pass
        else:
            connection.close()
            raise ValueError("Smoke unexpectedly connected to sentinel IPC")
        with lease.open("r+") as contender:
            try:
                fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                raise ValueError("Sentinel lifetime lease was not preserved")
        report["sentinelPreserved"] = True
    if input_manifest(package_source) != generated or bundle_manifest(bundle) != identity:
        raise ValueError("Packaged inputs/artifact changed during verification")
    report["status"] = "passed"
