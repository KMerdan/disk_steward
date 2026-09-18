import importlib.util
import shutil
import json
from pathlib import Path
import sys
import tempfile

repo = Path('/private/tmp/ds-ci-n2xldgm4/project')
spec = importlib.util.spec_from_file_location('candidate', repo / 'Scripts/Testing/verify_candidate.py')
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)
scratch = Path(tempfile.mkdtemp(prefix='ds552-check-', dir='/private/tmp'))
snapshot = scratch / 'project'
manifest = candidate.input_manifest(repo)
candidate.copy_inputs(repo, snapshot, manifest)
shutil.copy2('/Users/merdankiji/localGit/disk_steward/Tests/DiskStewardAppTests/IPC/EvidenceQueryPrivacyIPCIntegrationTests.swift', snapshot / 'Tests/DiskStewardAppTests/IPC/EvidenceQueryPrivacyIPCIntegrationTests.swift')
manifest = candidate.input_manifest(snapshot)
env = candidate.clean_environment(scratch)
command = ['/usr/bin/swift', 'test', '--cache-path', str(scratch / 'cache'), '--config-path', str(scratch / 'config'), '--security-path', str(scratch / 'security'), '--disable-sandbox', '--jobs', '2', '--filter', sys.argv[1]]
print(str(scratch), flush=True)
result = candidate.run_command(command, snapshot, env, scratch / 'tests.log', 240)
result['inputSHA256'] = candidate.manifest_digest(manifest)
result['inputManifest'] = manifest
result['sourceUnchanged'] = candidate.input_manifest(snapshot) == manifest
with (scratch / 'result.json').open('x') as stream:
    json.dump(result, stream, indent=2)
print(json.dumps({k:v for k,v in result.items() if k != 'inputManifest'}), flush=True)
sys.exit(0 if result['passed'] else 1)
