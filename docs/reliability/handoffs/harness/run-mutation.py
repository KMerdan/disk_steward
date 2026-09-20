# Copy the candidate, apply snapshot-only replacements, run a filtered suite.
# The worktree is never modified. Usage: run-mutation.py <spec.json> <filter>
import importlib.util, json, sys, tempfile
from pathlib import Path
repo = Path('/Users/merdankiji/localGit/disk_steward')
spec = json.loads(Path(sys.argv[1]).read_text())
loader = importlib.util.spec_from_file_location('candidate', repo / 'Scripts/Testing/verify_candidate.py')
candidate = importlib.util.module_from_spec(loader); loader.loader.exec_module(candidate)
scratch = Path(tempfile.mkdtemp(prefix='ds-mutation-', dir='/private/tmp'))
snapshot = scratch / 'project'
base = candidate.input_manifest(repo)
candidate.copy_inputs(repo, snapshot, base)
for mutation in spec['mutations']:
    target = snapshot / mutation['file']
    if target.resolve() != target or snapshot not in target.parents or not target.is_file():
        raise ValueError('Mutation target must be a regular file within the isolated snapshot')
    source = target.read_text()
    for old, new in mutation['replacements']:
        assert source.count(old) == 1, (mutation['file'], old[:70])
        source = source.replace(old, new)
    target.write_text(source)
env = candidate.clean_environment(scratch)
command = ['/usr/bin/swift', 'test', '--cache-path', str(scratch / 'cache'), '--config-path', str(scratch / 'config'),
           '--security-path', str(scratch / 'security'), '--disable-sandbox', '--jobs', '2', '--filter', sys.argv[2]]
print(str(scratch), flush=True)
result = candidate.run_command(command, snapshot, env, scratch / 'tests.log', 1800)
result['baseInputSHA256'] = candidate.manifest_digest(base)
result['repositoryUnchanged'] = candidate.input_manifest(repo) == base
result['mutation'] = spec
(scratch / 'result.json').write_text(json.dumps({k: v for k, v in result.items() if k != 'inputManifest'}, indent=1))
print(json.dumps({k: result[k] for k in ('passed', 'baseInputSHA256', 'repositoryUnchanged')}), flush=True)
sys.exit(0 if result['passed'] else 1)
