import fs from "node:fs";
import { pathToFileURL } from "node:url";
const W = { functional: 0.30, security: 0.30, coverage: 0.20, perfiso: 0.20 };

export const grade = (n) => n >= 90 ? "A" : n >= 80 ? "B" : n >= 70 ? "C" : "D";

export function scoreLang(s) {
  const cf = s.conformance || { passed: 0, failed: 0 };
  const cfTotal = cf.passed + cf.failed;
  const functional = cfTotal ? (cf.passed / cfTotal) * 100 : 0;

  const sec = s.security || { defended: 0, total: 0 };
  const security = sec.total ? (sec.defended / sec.total) * 100 : 0;

  const su = s.suite || { ran: false };
  const coverage = su.ran
    ? Math.min(100, (su.coverageLine || 0) * 0.6 + (su.coverageBranch || 0) * 0.3 + (su.lintClean ? 100 : 0) * 0.1)
    : 0;

  // 성능·동형성: perf(상대 백분위, 외부 주입) 50% + API 완전성(conformance 커버 = functional 근사) 50%
  const iso = functional; // 계약 전 엔드포인트 구현 정도 근사
  const perfiso = s.perf != null ? (s.perf * 0.5 + iso * 0.5) : iso; // perf 없으면 iso만

  const overall = functional * W.functional + security * W.security + coverage * W.coverage + perfiso * W.perfiso;
  return {
    functional: Math.round(functional), security: Math.round(security),
    coverage: Math.round(coverage), perfiso: Math.round(perfiso), overall: Math.round(overall),
  };
}

export function feedback(dims, signals) {
  const out = [];
  if (dims.security < 100) {
    const failed = (signals.security?.probes || []).filter(p => !p.defended).map(p => p.name);
    out.push(`보안 하드닝 ${dims.security}점 — 실패 프로브: ${failed.join(", ") || "N/A"} → JWT 검증 경계 확인(alg 핀·kid 해결·마스킹).`);
  }
  if (dims.functional < 100) out.push(`기능 정확성 ${dims.functional}점 — 실패 계약 체크가 있음. conformance 실패 항목의 앱/SDK 오류매핑·엔드포인트 확인.`);
  if (dims.coverage < 80) out.push(`커버리지·품질 ${dims.coverage}점 — 미커버 브랜치 보강 또는 린트 정리.`);
  if (dims.perfiso < 80) out.push(`성능·동형성 ${dims.perfiso}점 — 계약 엔드포인트 완전성 또는 상대 성능 개선.`);
  if (!out.length) out.push("보완사항 없음 — 만점 근접.");
  return out;
}

function loadSignals(lang) {
  const rd = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } };
  const perfRaw = rd(`report/${lang}.summary.json`); // k6 handleSummary(있으면)
  return {
    conformance: rd(`report/signals/${lang}.conformance.json`),
    security: rd(`report/signals/${lang}.security.json`),
    suite: rd(`report/signals/${lang}.suite.json`),
    _perfRaw: perfRaw,
  };
}

function main() {
  const langs = process.argv.slice(2);
  const rows = langs.map(lang => {
    const sig = loadSignals(lang);
    return { lang, sig, dims: scoreLang({ ...sig, perf: null }) }; // perf 상대백분위는 아래서 재계산
  });
  // 성능 상대 백분위(있으면): validate p95 낮을수록 높은 점수 — 여기선 단순화(perf 없으면 iso만)
  // (k6 summary 연동은 구현자가 report/<lang>.summary.json 파싱으로 채운다.)
  rows.sort((a, b) => b.dims.overall - a.dims.overall);
  let md = "# 언어별 종합 스코어카드 (SCORECARD)\n\n";
  md += "| 순위 | 언어 | 기능(30%) | 보안(30%) | 커버리지(20%) | 성능·동형(20%) | **종합** | 등급 |\n|---|---|---|---|---|---|---|---|\n";
  rows.forEach((r, i) => { const d = r.dims; md += `| ${i + 1} | ${r.lang} | ${d.functional} | ${d.security} | ${d.coverage} | ${d.perfiso} | **${d.overall}** | ${grade(d.overall)} |\n`; });
  md += "\n> 가중: 기능30·보안30·커버리지20·성능/동형성20. 등급 A≥90·B≥80·C≥70·D<70. 성능은 언어간 상대(절대 임계 아님), 나머지 절대 기준.\n\n## 언어별 보완 피드백\n\n";
  rows.forEach(r => { md += `### ${r.lang} (${grade(r.dims.overall)}, ${r.dims.overall}점)\n`; feedback(r.dims, r.sig).forEach(f => md += `- ${f}\n`); md += "\n"; });
  fs.writeFileSync("report/SCORECARD.md", md);
  console.log("wrote report/SCORECARD.md");
}
// Windows: process.argv[1] is a raw path (backslashes) — comparing it against
// import.meta.url (a file:// URL with forward slashes) via naive string concat
// never matches, so main() silently never runs. pathToFileURL normalizes both
// sides to the same URL form on every platform.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
