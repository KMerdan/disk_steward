# Disposable mutation check: copy the current candidate, apply the named
# snapshot-only replacements, and run the filtered tests. The real worktree is
# never modified. Usage: task552-run-mutation.py <spec.json> <filter>
import importlib.util, json, sys, tempfile
from pathlib import Path
repo = Path('/Users/merdankiji/localGit/disk_steward')
spec_path, test_filter = Path(sys.argv[1]), sys.argv[2]
spec = json.loads(spec_path.read_text())
loader = importlib.util.spec_from_file_location('candidate', repo / 'Scripts/Testing/verify_candidate.py')
candidate = importlib.util.module_from_spec(loader); loader.loader.exec_module(candidate)
scratch = Path(tempfile.mkdtemp(prefix='ds552-check-', dir='/private/tmp'))
snapshot = scratch / 'project'
base_manifest = candidate.input_manifest(repo)
candidate.copy_inputs(repo, snapshot, base_manifest)
for mutation in spec['mutations']:
    target = snapshot / mutation['file']
    source = target.read_text()
    for old, new in mutation['replacements']:
        assert source.count(old) == 1, (mutation['file'], old[:80])
        source = source.replace(old, new)
    target.write_text(source)
manifest = candidate.input_manifest(snapshot)
env = candidate.clean_environment(scratch)
command = ['/usr/bin/swift', 'test', '--cache-path', str(scratch / 'cache'), '--config-path', str(scratch / 'config'), '--security-path', str(scratch / 'security'), '--disable-sandbox', '--jobs', '2', '--filter', test_filter]
print(str(scratch), flush=True)
result = candidate.run_command(command, snapshot, env, scratch / 'tests.log', 300)
result['baseInputSHA256'] = candidate.manifest_digest(base_manifest)
result['inputSHA256'] = candidate.manifest_digest(manifest)
result['inputManifest'] = manifest
result['mutation'] = spec
result['sourceUnchanged'] = candidate.input_manifest(snapshot) == manifest
result['repositoryUnchanged'] = candidate.input_manifest(repo) == base_manifest
with (scratch / 'result.json').open('x') as stream: json.dump(result, stream, indent=2)
print(json.dumps({k: v for k, v in result.items() if k not in ('inputManifest', 'mutation')}), flush=True)
sys.exit(0 if result['passed'] else 1)
