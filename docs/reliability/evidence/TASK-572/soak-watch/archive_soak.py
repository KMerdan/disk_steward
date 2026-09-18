# Archive a finished supervised soak under docs/reliability/evidence/TASK-572/soak-runs/<name>/
# and print the peaks. Usage: archive-572-soak.py <root> <name>
import json, shutil, sys
from pathlib import Path
root, name = Path(sys.argv[1]), sys.argv[2]
dest = Path('/Users/merdankiji/localGit/disk_steward/docs/reliability/evidence/TASK-572/soak-runs') / name
dest.mkdir(parents=True, exist_ok=True)
for f in ('soak.log', 'result.json', 'soak-supervision.json', 'soak-samples.jsonl', 'fixture-supervision.json', 'fixture.json', 'fixture.log'):
    if (root / f).exists(): shutil.copy2(root / f, dest / f)
rows = [json.loads(l) for l in (root / 'soak.log').read_text(errors='replace').splitlines() if l.startswith('{')]
cycles = [r for r in rows if r.get('kind') == 'cycle']
final = json.loads((root / 'result.json').read_text()) if (root / 'result.json').exists() else {}
sup = json.loads((root / 'soak-supervision.json').read_text()) if (root / 'soak-supervision.json').exists() else {}
last = cycles[-1] if cycles else {}
summary = {'schema': 'disk-steward-soak-archive-v1', 'root': str(root), 'name': name, 'status': final.get('status'), 'supervisorReason': sup.get('reason'), 'supervisorExit': sup.get('exitCode'),
           'seconds': sup.get('seconds'), 'cycles': last.get('cycles'), 'elapsedSeconds': last.get('elapsedSeconds'),
           'peaks': {k: max((r.get(k) or 0) for r in cycles) for k in ('peakInProcessRSSBytes', 'peakSampledDatabaseFamilyBytes', 'peakSampledWALBytes', 'peakOpenDescriptors', 'peakCPUPercent', 'peakCommittedBytes', 'peakExportBytes', 'peakDurableFrontierRows', 'maxCycleSeconds', 'maxExportSeconds', 'maxPublicationSeconds', 'maxQuerySeconds', 'maxRetentionSeconds')},
           'supervisorPeaks': {k: sup.get(k) for k in ('peakProcessGroupRSSBytes', 'peakSampledWALBytes', 'peakSampledDatabaseFamilyBytes', 'peakExportBytes')},
           'totals': {k: last.get(k) for k in ('created', 'modified', 'deleted', 'exports', 'exportRefusals', 'forcedEvictions', 'mismatches', 'mutationMismatches', 'consumers', 'expectedFiles', 'growthItems', 'detailCoverage', 'generationStatus', 'admission', 'lastAdmission', 'error', 'limitations')},
           'retentionRuns': final.get('retentionRuns', last.get('retentionRuns')), 'final': final}
(dest / 'summary.json').write_text(json.dumps(summary, indent=1, sort_keys=True) + '\n')
print(json.dumps({k: v for k, v in summary.items() if k != 'final'}, indent=1))
