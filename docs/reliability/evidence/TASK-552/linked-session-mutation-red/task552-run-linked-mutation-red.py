# Disposable mutation check: copy the current candidate, break get_provenance's
# session projection ONLY inside the snapshot, and confirm the linked-session
# privacy test detects it. The real worktree is never modified.
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

repo = Path('/Users/merdankiji/localGit/disk_steward')
spec = importlib.util.spec_from_file_location('candidate', repo / 'Scripts/Testing/verify_candidate.py')
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)
scratch = Path(tempfile.mkdtemp(prefix='ds552-check-', dir='/private/tmp'))
snapshot = scratch / 'project'
base_manifest = candidate.input_manifest(repo)
candidate.copy_inputs(repo, snapshot, base_manifest)
target = snapshot / 'Sources/DiskStewardApp/IPC/AppEvidenceQueryBackend.swift'
source = target.read_text()
mutations = [
    ('            "task_context": detail == .full ? (registration.taskContext.map(JSONValue.string) ?? .null) : .null,\n',
     '            "task_context": registration.taskContext.map(JSONValue.string) ?? .null,\n'),
    ('            "task_context_withheld": .bool(detail != .full && registration.taskContext != nil),\n',
     '            "task_context_withheld": .bool(false),\n'),
]
for old, new in mutations:
    assert source.count(old) == 1, old
    source = source.replace(old, new)
target.write_text(source)
manifest = candidate.input_manifest(snapshot)
env = candidate.clean_environment(scratch)
command = ['/usr/bin/swift', 'test', '--cache-path', str(scratch / 'cache'), '--config-path', str(scratch / 'config'), '--security-path', str(scratch / 'security'), '--disable-sandbox', '--jobs', '2', '--filter', sys.argv[1]]
print(str(scratch), flush=True)
result = candidate.run_command(command, snapshot, env, scratch / 'tests.log', 240)
result['baseInputSHA256'] = candidate.manifest_digest(base_manifest)
result['inputSHA256'] = candidate.manifest_digest(manifest)
result['inputManifest'] = manifest
result['mutation'] = {'file': 'Sources/DiskStewardApp/IPC/AppEvidenceQueryBackend.swift', 'replacements': mutations}
result['sourceUnchanged'] = candidate.input_manifest(snapshot) == manifest
result['repositoryUnchanged'] = candidate.input_manifest(repo) == base_manifest
with (scratch / 'result.json').open('x') as stream:
    json.dump(result, stream, indent=2)
print(json.dumps({k: v for k, v in result.items() if k != 'inputManifest'}), flush=True)
sys.exit(0 if result['passed'] else 1)
