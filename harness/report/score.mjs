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
  const line = su.coverageLine || 0, branch = su.coverageBranch || 0, lint = su.lintClean ? 100 : 0;
  // branch coverage는 언어별 suite 스크립트가 실제로 파싱하는 경우에만 신뢰 가능한 신호다(go/php/rust/ruby는
  // 미파싱 → 0). 0을 "실측 0%"로 벌점 처리하면 미측정 언어가 부당하게 불리해지므로, branch가 0/falsy(미측정)일 때는
  // line+lint만으로 가중하고, branch가 실측(>0)된 언어만 branch-가중 공식을 적용한다.
  const coverage = su.ran
    ? (branch > 0
        ? Math.min(100, line * 0.6 + branch * 0.3 + lint * 0.1)
        : Math.min(100, line * 0.9 + lint * 0.1))
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
  if (dims.coverage < 80) {
    const branchMeasured = (signals.suite?.coverageBranch || 0) > 0;
    const advice = branchMeasured ? "미커버 브랜치 보강 또는 린트 정리" : "라인 커버리지 보강 또는 린트 정리";
    out.push(`커버리지·품질 ${dims.coverage}점 — ${advice}.`);
  }
  if (dims.perfiso < 80) out.push(`성능·동형성 ${dims.perfiso}점 — 계약 엔드포인트 완전성 또는 상대 성능 개선.`);
  if (!out.length) out.push("보완사항 없음 — 만점 근접.");
  return out;
}

function loadSignals(lang) {
  const rd = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } };
  // k6 handleSummary(scenarios.js)는 `/report/${LANG}.json`에 쓰고 aggregate.mjs도 `./${lang}.json`을
  // 읽는다 — perf가 아직 연동 전(perf:null)이라도 파일명은 그 두 소비자와 일치시켜 향후 연동 시 어긋나지 않게 한다.
  const perfRaw = rd(`report/${lang}.json`); // k6 handleSummary(있으면)
  return {
    conformance: rd(`report/signals/${lang}.conformance.json`),
    security: rd(`report/signals/${lang}.security.json`),
    suite: rd(`report/signals/${lang}.suite.json`),
    _perfRaw: perfRaw,
  };
}

// k6 summary(report/<lang>.json)의 validate_duration p95(낮을수록 우수)를 perf 원천으로 쓴다 — validate는
// SDK의 핵심 JWT 검증 경로라 "SDK-in-idiomatic-app" 비용을 가장 대표한다. 미측정(파일·메트릭 부재)이면
// null → perf 미반영(iso만). k6 summary의 백분위 키는 `p(95)`(괄호 포함)다.
function validateP95(perfRaw) {
  const v = perfRaw?.metrics?.validate_duration?.values;
  if (!v) return null;
  const p = v["p(95)"] ?? v.p95;
  return (typeof p === "number" && p > 0) ? p : null;
}

function main() {
  const langs = process.argv.slice(2);
  const rows = langs.map(lang => ({ lang, sig: loadSignals(lang) }));
  // 성능 상대 점수(k6 연동): validate p95를 언어간 상대로 환산 — 최우수(최소) p95=100점, k배 느리면 100/k점.
  // 절대 임계가 아니라 상대이므로 k6 데이터가 있는 언어끼리만 비교하고, 없는 언어는 perf=null(→ iso만,
  // 미측정 무벌점 — 커버리지 branch 폴백과 동일 철학). 단일 언어만 측정돼도 자기 자신이 최우수라 100점.
  const p95s = rows.map(r => validateP95(r.sig._perfRaw)).filter(v => v != null);
  const bestP95 = p95s.length ? Math.min(...p95s) : null;
  rows.forEach(r => {
    const p = validateP95(r.sig._perfRaw);
    const perf = (bestP95 != null && p != null) ? Math.min(100, (bestP95 / p) * 100) : null;
    r.dims = scoreLang({ ...r.sig, perf });
  });
  rows.sort((a, b) => b.dims.overall - a.dims.overall);
  let md = "# 언어별 종합 스코어카드 (SCORECARD)\n\n";
  md += "| 순위 | 언어 | 기능(30%) | 보안(30%) | 커버리지(20%) | 성능·동형(20%) | **종합** | 등급 |\n|---|---|---|---|---|---|---|---|\n";
  rows.forEach((r, i) => { const d = r.dims; md += `| ${i + 1} | ${r.lang} | ${d.functional} | ${d.security} | ${d.coverage} | ${d.perfiso} | **${d.overall}** | ${grade(d.overall)} |\n`; });
  md += "\n> 가중: 기능30·보안30·커버리지20·성능/동형성20. 등급 A≥90·B≥80·C≥70·D<70. 성능은 언어간 상대(절대 임계 아님), 나머지 절대 기준. 커버리지는 branch coverage가 실측(>0)된 언어만 branch-가중(line60·branch30·lint10), 미측정 언어(go/php/rust/ruby 등)는 line-가중(line90·lint10)으로 폴백해 미측정을 0%로 벌점하지 않는다.\n> **성능·동형(20%) = perf(validate p95 언어간 상대, 50%) + 동형성(계약 완전성 근사, 50%)**. k6 summary(report/<lang>.json)의 validate_duration p95를 최우수(최소) 대비 상대점수화(최우수=100점·k배 느리면 100/k점)해 반영한다. k6 미측정 언어는 동형성만 반영(무벌점 — 커버리지 branch 폴백과 동일 철학).\n> **보안 30%는 HTTP 레벨 적대적 프로브(alg=none·RS/HS confusion·미지/무-kid·malformed·마스킹·flood)를 측정한다** — aud/iss/exp claim-level 검증은 각 SDK 자체 단위테스트(커버리지 차원)가 커버(realm-서명 토큰 필요로 프로브 범위 밖).\n\n## 언어별 보완 피드백\n\n";
  rows.forEach(r => { md += `### ${r.lang} (${grade(r.dims.overall)}, ${r.dims.overall}점)\n`; feedback(r.dims, r.sig).forEach(f => md += `- ${f}\n`); md += "\n"; });
  fs.writeFileSync("report/SCORECARD.md", md);
  console.log("wrote report/SCORECARD.md");
}
// Windows: process.argv[1] is a raw path (backslashes) — comparing it against
// import.meta.url (a file:// URL with forward slashes) via naive string concat
// never matches, so main() silently never runs. pathToFileURL normalizes both
// sides to the same URL form on every platform.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
