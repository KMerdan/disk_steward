# Build a fixture whose files sit behind classified objects, then run the opt-in
# scale case against it in an isolated snapshot. Usage: object-scale.py <objects> <files-per-object>
import importlib.util, json, os, sys, tempfile, uuid, time
from pathlib import Path
raise SystemExit('Object-scale admission closed by TASK-616 before fixture creation: fixture construction needs its own supervised quotas. See Scripts/Testing/SUPERVISION.md')
repo = Path('/Users/merdankiji/localGit/disk_steward')
objects, per_object = int(sys.argv[1]), int(sys.argv[2])
root = Path(tempfile.mkdtemp(prefix='ds612-scale.', dir='/private/tmp'))
os.chmod(root, 0o700)
token = str(uuid.uuid4()); (root / 'owner-token').write_text(token)
tree = root / 'tree'; (root / 'store').mkdir()
started = time.monotonic(); behind = 0
for index in range(objects):
    project = tree / f'project-{index}'
    (project / 'src').mkdir(parents=True)
    (project / 'package.json').write_text('{}')
    for ordinary in range(20):
        (project / 'src' / f'file-{ordinary}.js').write_text('0')
    node_modules = project / 'node_modules'
    for package in range(per_object // 50):
        directory = node_modules / f'dep-{package}'
        directory.mkdir(parents=True)
        (directory / 'package.json').write_text('{}'); behind += 1
        for leaf in range(49):
            (directory / f'file-{leaf}.js').write_text('0'); behind += 1
print(json.dumps({'fixture': str(root), 'entriesBehindObjects': behind, 'buildSeconds': round(time.monotonic() - started, 1)}), flush=True)

loader = importlib.util.spec_from_file_location('candidate', repo / 'Scripts/Testing/verify_candidate.py')
candidate = importlib.util.module_from_spec(loader); loader.loader.exec_module(candidate)
scratch = Path(tempfile.mkdtemp(prefix='ds612-run.', dir='/private/tmp'))
snapshot = scratch / 'project'
manifest = candidate.input_manifest(repo)
candidate.copy_inputs(repo, snapshot, manifest)
env = candidate.clean_environment(scratch)
env.update({'DISK_STEWARD_OBJECT_SCALE': 'v1', 'DISK_STEWARD_OBJECT_SCALE_ROOT': str(root),
            'DISK_STEWARD_OBJECT_SCALE_TOKEN': token, 'DISK_STEWARD_OBJECT_SCALE_BEHIND': str(behind)})
command = ['/usr/bin/swift', 'test', '--cache-path', str(scratch / 'cache'), '--config-path', str(scratch / 'config'),
           '--security-path', str(scratch / 'security'), '--disable-sandbox', '--jobs', '2',
           '--filter', 'ObjectScanScaleTests']
result = candidate.run_command(command, snapshot, env, scratch / 'tests.log', 3600)
result['inputSHA256'] = candidate.manifest_digest(manifest)
result['fixture'] = {'root': str(root), 'entriesBehindObjects': behind, 'objects': objects}
(scratch / 'result.json').write_text(json.dumps({k: v for k, v in result.items() if k != 'inputManifest'}, indent=1))
print(str(scratch), flush=True)
print((root / 'result.json').read_text() if (root / 'result.json').exists() else 'no result.json', flush=True)
sys.exit(0 if result['passed'] else 1)
