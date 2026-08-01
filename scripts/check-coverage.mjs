#!/usr/bin/env node
// cobertura 커버리지 게이트 — 임계값을 비교하기 **전에** "측정이 실제로 일어났는가"를 먼저 판정한다.
//
// 왜 별도 가드인가: coverlet의 내장 `/p:Threshold` 게이트는 히트가 하나도 수집되지 않은 실행을
// `0%`로 보고하고 "The minimum line coverage is below the specified 90"으로 실패시킨다. 이 문구는
// 진짜 커버리지 하락과 **구분이 불가능**하다. 실제로 dotnet-ci가 이 문구로 한 번 실패했는데
// (run 30676360497), 같은 커밋을 재실행하니 96.68%로 통과했다 — 코드가 아니라 계측이 실패한
// 것이었다. 그 로그를 본 사람은 테스트를 더 쓰러 가게 된다(고칠 것이 없는데도).
//
// 판별자는 **분모와 분자를 분리해서 보는 것**이다. cobertura 루트는 둘을 따로 들고 있다:
//   lines-valid   = 계측된 라인 수(분모)  ·  lines-covered = 히트된 라인 수(분자)
// 단순히 `line-rate == 0`을 보면 이 둘을 구분할 수 없다. 세 상태로 나눈다:
//   (1) 리포트 부재 또는 lines-valid == 0  → 아무것도 계측되지 않음      = 측정 실패
//   (2) lines-valid > 0 이고 lines-covered == 0 → 분모는 있는데 히트 0   = 측정 실패
//   (3) 그 외                                                            → 진짜 수치, 임계값 비교
// (2)가 핵심이다. 테스트가 통과했는데 히트가 0인 것은 하락으로는 성립할 수 없다(테스트가 코드를
// 한 줄도 실행하지 않고 통과할 수는 없다) — 오탐 0의 판별자다.
//
// harness/suites/{ruby,rust,dotnet}.sh의 "측정 실패를 0으로 접지 않는다" 원칙과 같은 계열이다.
import fs from "node:fs";
import path from "node:path";

const argv = process.argv.slice(2);
const target = argv.find((a) => !a.startsWith("--"));
const numArg = (name, dflt) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] != null ? Number(argv[i + 1]) : dflt;
};
const minLine = numArg("--min-line", 0);
const minBranch = numArg("--min-branch", 0);

const fail = (code, lines) => {
  console.error(`::error::${code}`);
  for (const l of lines) console.error(`  ${l}`);
  process.exit(1);
};

if (!target) fail("coverage-measurement-failed", ["리포트 경로 인자가 없다."]);

// collector(`--collect:"XPlat Code Coverage"`)는 msbuild 통합과 달리 고정 경로가 아니라
// `TestResults/<랜덤 guid>/coverage.cobertura.xml`에 쓴다 — 그래서 디렉터리를 받아 훑는다.
function findReports(p) {
  if (!fs.existsSync(p)) return [];
  if (fs.statSync(p).isFile()) return [p];
  const out = [];
  for (const e of fs.readdirSync(p, { withFileTypes: true })) {
    const full = path.join(p, e.name);
    if (e.isDirectory()) out.push(...findReports(full));
    else if (e.name.endsWith("cobertura.xml")) out.push(full);
  }
  return out;
}

const reports = findReports(target);
if (reports.length === 0) {
  fail("coverage-measurement-failed", [
    `cobertura 리포트를 찾지 못했다: ${target}`,
    "테스트는 돌았는데 리포트가 없다면 커버리지 수집 자체가 실패한 것이다 — 게이트를 통과시키지 않는다.",
  ]);
}

// 여러 테스트 프로젝트가 각자 리포트를 내면 비율이 아니라 **분자/분모를 합산**해야 한다
// (비율 평균은 프로젝트 크기를 무시해 틀린다).
const sum = { lc: 0, lv: 0, bc: 0, bv: 0 };
for (const f of reports) {
  const head = fs.readFileSync(f, "utf8").slice(0, 4096);
  const attr = (n) => {
    const m = head.match(new RegExp(`${n}="([0-9]+)"`));
    return m ? Number(m[1]) : null;
  };
  const lv = attr("lines-valid");
  if (lv == null) {
    fail("coverage-measurement-failed", [
      `cobertura 루트에서 lines-valid를 읽지 못했다: ${f}`,
      "리포트 형식이 바뀌었을 가능성 — 0으로 접지 않고 시끄럽게 실패한다.",
    ]);
  }
  sum.lc += attr("lines-covered") ?? 0;
  sum.lv += lv;
  sum.bc += attr("branches-covered") ?? 0;
  sum.bv += attr("branches-valid") ?? 0;
}

const where = reports.map((r) => `  - ${r}`).join("\n");

// (1) 분모가 없다 = 아무것도 계측되지 않았다.
if (sum.lv === 0) {
  fail("coverage-measurement-failed", [
    "계측된 라인이 0개다(lines-valid=0) — 커버리지가 낮은 것이 아니라 측정이 안 된 것이다.",
    "임계값을 낮추지 말 것. 계측 파이프라인을 확인하라.",
    ...reports.map((r) => `리포트: ${r}`),
  ]);
}

// (2) 분모는 있는데 분자가 0 = 히트가 수집되지 않았다(테스트는 통과했는데).
if (sum.lc === 0) {
  fail("coverage-measurement-failed", [
    `계측은 됐는데(lines-valid=${sum.lv}) 히트가 0이다(lines-covered=0).`,
    "테스트가 통과한 실행에서 이 조합은 커버리지 하락으로는 성립할 수 없다 — 측정 실패다.",
    "임계값을 낮추거나 테스트를 추가하지 말 것. 커버리지 수집기가 결과를 flush하지 못한 것이다.",
    ...reports.map((r) => `리포트: ${r}`),
  ]);
}

// (3) 진짜 수치.
const linePct = (sum.lc / sum.lv) * 100;
// 분기가 없는 코드베이스에서 branches-valid=0은 정상이다 — 0%로 벌점하지 않는다.
const branchPct = sum.bv > 0 ? (sum.bc / sum.bv) * 100 : null;
const f2 = (n) => n.toFixed(2);

const problems = [];
if (linePct < minLine) problems.push(`라인 ${f2(linePct)}% < ${minLine}% (${sum.lc}/${sum.lv})`);
if (branchPct != null && branchPct < minBranch) {
  problems.push(`브랜치 ${f2(branchPct)}% < ${minBranch}% (${sum.bc}/${sum.bv})`);
}

if (problems.length > 0) {
  fail("coverage-regression", [
    ...problems,
    "측정은 정상이다(히트 > 0) — 이건 진짜 커버리지 하락이다.",
  ]);
}

console.log(
  `커버리지 OK — 라인 ${f2(linePct)}% (${sum.lc}/${sum.lv}), ` +
    (branchPct != null ? `브랜치 ${f2(branchPct)}% (${sum.bc}/${sum.bv})` : "브랜치 없음") +
    `, 임계 ${minLine}/${minBranch}`,
);
// 분기 여유를 절대 개수로도 알린다 — 백분율만 보면 분모가 작을 때 여유를 과대평가한다
// (분모 50이면 브랜치 1개가 2%p라 "5%p 여유"가 실제로는 2개짜리 여유다).
if (branchPct != null && sum.bv > 0) {
  const needed = Math.ceil((minBranch / 100) * sum.bv);
  console.log(`  브랜치 여유: ${sum.bc - needed}개 (임계 충족에 ${needed}/${sum.bv} 필요)`);
}
console.log(`리포트:\n${where}`);
