import importlib.util
import json
from pathlib import Path
spec = importlib.util.spec_from_file_location('candidate', '/Users/merdankiji/localGit/disk_steward/Scripts/Testing/verify_candidate.py')
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)
scratch = Path('/private/tmp/ds552-check-wptwjrrx')
command = ['/usr/bin/swift', 'test', '--cache-path', str(scratch/'cache'), '--config-path', str(scratch/'config'), '--security-path', str(scratch/'security'), '--disable-sandbox', '--jobs', '2', '--filter', 'AuthoritativeMCPReadModelTests.testTaskImpact']
result = candidate.run_command(command, scratch/'project', candidate.clean_environment(scratch), scratch/'diagnostic.log', 120)
print(json.dumps(result))
