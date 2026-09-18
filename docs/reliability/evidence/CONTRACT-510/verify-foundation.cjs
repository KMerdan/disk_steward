// Read-only foundation verifier. Never launches the app or opens evidence stores.
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const assert = require('node:assert/strict');
const root = fs.realpathSync(process.argv[2]);
const runtime = fs.realpathSync(process.argv[3]);
const Ajv = require(path.join(root, 'promo/node_modules/ajv/dist/2020')).default;
const ajv = new Ajv({ strict: false, allErrors: true });
const read = file => JSON.parse(fs.readFileSync(path.join(root, file), 'utf8'));
const dir = 'docs/reliability/evidence/CONTRACT-510/';
function schema(file, name) {
  const validate = ajv.compile(JSON.parse(fs.readFileSync(path.join(runtime, 'schemas', name + '.schema.json'), 'utf8')));
  assert(validate(read(file)), JSON.stringify(validate.errors));
}
schema(dir + 'baseline.json', 'baseline');
schema(dir + 'assurance.json', 'assurance');
schema(dir + 'plan-005-r2-review.json', 'plan-review');
schema(dir + 'isolation-helper-job.json', 'helper-job');
const plan = read('.pyramid/plan.json');
const baseline = read(dir + 'baseline.json');
const assurance = read(dir + 'assurance.json');
assert.equal(read('.pyramid/project.json').mode, 'brownfield');
assert.equal(assurance.plan_id, plan.plan_id);
assert.equal(assurance.baseline_id, baseline.baseline_id);
assert.equal(assurance.baseline_revision, baseline.revision);
const assets = new Map(baseline.assets.map(a => [a.id, a]));
const executableKinds = ['implementation', 'research', 'contract', 'integration', 'risk-control', 'audit'];
const tasks = plan.nodes.filter(n => n.selection === 'primary' && executableKinds.includes(n.kind));
for (const task of tasks) {
  const impacts = assurance.impacts.filter(i => i.task_ids.includes(task.id) && i.status !== 'dismissed');
  assert(impacts.length > 0, task.id + ': no impact');
  for (const impact of impacts) {
    assert(assets.has(impact.asset_id), impact.id + ': unknown asset');
    assert(impact.evidence.length > 0 && impact.path.includes(task.id), impact.id + ': no trace');
    assert(assurance.inspections.some(i => i.required && i.task_ids.includes(task.id) && i.asset_ids.includes(impact.asset_id)), impact.id + ': no inspection');
  }
}
for (const relation of baseline.relations) assert(assets.has(relation.from) && assets.has(relation.to));
for (const h of baseline.history) assert(h.evidence.length > 0 && h.controls.length > 0);
for (const a of assets.values()) assert(a.locators.every(p => p !== '.' && p !== '**' && p !== '**/*'));
for (const i of assurance.inspections) assert(i.asset_ids.length <= 4 && i.task_ids.length <= 8);
// Glob matching for this inventory; ** and * both classify path text.
const matches = (file, glob) => new RegExp('^' + glob.split('*').map(s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$').test(file);
const changed = cp.execFileSync('git', ['diff', '--name-only'], { cwd: root, encoding: 'utf8' }).trim().split('\n');
const untracked = cp.execFileSync('git', ['ls-files', '--others', '--exclude-standard'], { cwd: root, encoding: 'utf8' }).trim().split('\n');
const productFiles = [...new Set([...changed, ...untracked])].filter(p => /^(Sources|Tests|Scripts|Config|Extensions|Schemas)\//.test(p));
for (const file of productFiles) assert([...assets.values()].some(a => a.locators.some(g => matches(file, g))), file + ': unmapped product path');
const text = fs.readFileSync(path.join(root, dir, 'safety-contract.md'), 'utf8');
for (const phrase of ['No deletion of monitored user files', '100k/1M', 'real wall-clock overnight', 'Before any storage migration', 'before execution', 'production stores/profiles remain unopened']) assert(text.includes(phrase), phrase);
for (const n of plan.nodes.filter(n => n.kind === 'audit')) assert.equal(n.acceptance_criteria[0].description, n.required_evidence[0].description, n.id + ': conflicting gate contract');
const finalGate = plan.nodes.find(n => n.id === 'GATE-579');
assert(finalGate.required_evidence[0].description.includes('real-time overnight'));
const open = assurance.findings.filter(f => f.status === 'open').length;
assert(open >= 7, 'Unresolved product risks must remain visible, not auto-accepted');
console.log(JSON.stringify({ status: 'passed', scope: 'foundation contract and static source inventory only', plan: plan.plan_id, revision: plan.revision, assets: assets.size, relations: baseline.relations.length, history: baseline.history.length, executableNodesCovered: tasks.length, impacts: assurance.impacts.length, inspections: assurance.inspections.length, classifiedChangedProductFiles: productFiles.length, unresolvedFindings: open, runtimeChecks: 'not run; isolation repairs and all later product acceptance remain required' }, null, 2));
