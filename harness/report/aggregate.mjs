// Usage: node aggregate.mjs go [dotnet node python java] → report/RESULTS.md
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const langs = process.argv.slice(2);
const rows = [];
let anyFail = false;

for (const lang of langs) {
  const f = new URL(`./${lang}.json`, import.meta.url);
  if (!existsSync(f)) { rows.push({ lang, missing: true }); anyFail = true; continue; }
  const d = JSON.parse(readFileSync(f, 'utf8'));
  const m = d.metrics || {};
  const val = (n, k) => (m[n]?.values?.[k] ?? null);
  const checksRate = val('checks', 'rate');
  const pass = checksRate === 1;
  if (!pass) anyFail = true;
  rows.push({
    lang, pass, checksRate,
    validateP95: val('validate_duration', 'p(95)'),
    adminP95: val('admin_crud_duration', 'p(95)'),
    rps: val('http_reqs', 'rate'),
    errRate: val('http_req_failed', 'rate'),
  });
}

const n = (x, d = 2) => (x == null ? '—' : Number(x).toFixed(d));
let md = `# 하네스 실측 결과 (RESULTS)\n\n## 기능 정확성 게이트\n\n| 언어 | checks PASS율 | 게이트 |\n|---|---|---|\n`;
for (const r of rows) md += `| ${r.lang} | ${r.missing ? 'MISSING' : (100 * r.checksRate).toFixed(0) + '%'} | ${r.pass ? '✅' : '❌'} |\n`;
md += `\n## 성능 실측 (언어간 비교)\n\n| 언어 | validate p95(ms) | admin CRUD p95(ms) | RPS | 오류율 |\n|---|---|---|---|---|\n`;
for (const r of rows) if (!r.missing) md += `| ${r.lang} | ${n(r.validateP95)} | ${n(r.adminP95)} | ${n(r.rps)} | ${n(100 * r.errRate)}% |\n`;
md += `\n> 성능은 실측·비교용(임계값 강제 아님). 기능 게이트만 PASS/FAIL.\n`;

writeFileSync(new URL('./RESULTS.md', import.meta.url), md);
console.log(md);
process.exit(anyFail ? 1 : 0);
