# Copy the candidate inputs into a fresh snapshot outside the repository and run
# a filtered suite there. The worktree is never built or written to.
# Usage: run-focused.py <filter-regex>
import importlib.util, json, sys, tempfile
from pathlib import Path
repo = Path('/Users/merdankiji/localGit/disk_steward')
loader = importlib.util.spec_from_file_location('candidate', repo / 'Scripts/Testing/verify_candidate.py')
candidate = importlib.util.module_from_spec(loader); loader.loader.exec_module(candidate)
scratch = Path(tempfile.mkdtemp(prefix='ds-check-', dir='/private/tmp'))
snapshot = scratch / 'project'
manifest = candidate.input_manifest(repo)
candidate.copy_inputs(repo, snapshot, manifest)
env = candidate.clean_environment(scratch)
command = ['/usr/bin/swift', 'test', '--cache-path', str(scratch / 'cache'), '--config-path', str(scratch / 'config'),
           '--security-path', str(scratch / 'security'), '--disable-sandbox', '--jobs', '2', '--filter', sys.argv[1]]
print(str(scratch), flush=True)
result = candidate.run_command(command, snapshot, env, scratch / 'tests.log', int(sys.argv[2]) if len(sys.argv) > 2 else 1800)
result['inputSHA256'] = candidate.manifest_digest(manifest)
result['repositoryUnchanged'] = candidate.input_manifest(repo) == manifest
(scratch / 'result.json').write_text(json.dumps({k: v for k, v in result.items() if k != 'inputManifest'}, indent=1))
print(json.dumps({k: result[k] for k in ('passed', 'inputSHA256', 'repositoryUnchanged')}), flush=True)
sys.exit(0 if result['passed'] else 1)
