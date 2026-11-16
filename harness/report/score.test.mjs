import assert from "node:assert";
import { scoreLang, grade, feedback } from "./score.mjs";
// 만점 언어
const perfect = scoreLang({
  conformance: { passed: 20, failed: 0 }, security: { defended: 6, total: 6 },
  suite: { coverageLine: 100, coverageBranch: 95, lintClean: true, ran: true, testsPassed: true, unit: 42 }, perf: null,
});
assert.strictEqual(perfect.functional, 100);
assert.strictEqual(perfect.security, 100);
assert.ok(perfect.overall >= 90 && grade(perfect.overall) === "A");
// 보안 결함 언어 → 보안 점수·피드백
const weak = scoreLang({
  conformance: { passed: 18, failed: 2 }, security: { defended: 4, total: 6 },
  suite: { coverageLine: 80, coverageBranch: 70, lintClean: true, ran: true, testsPassed: true, unit: 42 }, perf: null,
});
assert.ok(weak.security < 70, "security should reflect 4/6");
const fb = feedback(weak, { security: { probes: [{ name: "alg=none rejected", defended: false }] } });
assert.ok(fb.some(f => /alg=none/.test(f)), "should name the failed probe");

// 결측 신호(missing-signal) — signals가 전부 비어 있어도 크래시 없이 전항목 0점으로 우아하게 강등돼야 한다.
const missing = scoreLang({ conformance: null, security: null, suite: { ran: false } });
assert.strictEqual(missing.functional, 0);
assert.strictEqual(missing.security, 0);
assert.strictEqual(missing.coverage, 0);
assert.strictEqual(missing.perfiso, 0);
assert.strictEqual(missing.overall, 0);
assert.strictEqual(grade(missing.overall), "D");

const missingAll = scoreLang({});
assert.strictEqual(missingAll.overall, 0);
assert.strictEqual(grade(missingAll.overall), "D");
assert.doesNotThrow(() => feedback(missingAll, {}));

// 커버리지 공정성 — branch coverage 미측정(0/falsy) 언어는 line+lint만으로 가중해야 한다(go 예시: line 95.2, branch 0).
const branchUnmeasured = scoreLang({
  suite: { coverageLine: 95.2, coverageBranch: 0, lintClean: true, ran: true, testsPassed: true, unit: 42 },
});
assert.strictEqual(branchUnmeasured.coverage, Math.round(95.2 * 0.9 + 10));
const fbUnmeasured = feedback(branchUnmeasured, { suite: { coverageLine: 95.2, coverageBranch: 0, lintClean: true, ran: true } });
assert.ok(!fbUnmeasured.some(f => /브랜치/.test(f)), "should not tell a branch-unmeasured language to add branch tests");

// branch coverage가 실측(>0)된 언어는 여전히 branch-가중 공식을 쓴다.
const branchMeasured = scoreLang({
  suite: { coverageLine: 100, coverageBranch: 94.31, lintClean: true, ran: true, testsPassed: true, unit: 42 },
});
assert.strictEqual(branchMeasured.coverage, Math.round(100 * 0.6 + 94.31 * 0.3 + 10));

// ── 테스트가 실패하면 커버리지 크레딧을 주지 않는다 (PR 0, I1) ─────────────────
// suite 스크립트가 단위테스트 종료코드를 버리던 시절에는 테스트가 깨져도 coverageLine이
// 그대로 보고되어 만점이 유지됐다. testsPassed:false면 커버리지 차원은 0이어야 한다.
const testsFailed = scoreLang({
  conformance: { passed: 20, failed: 0 }, security: { defended: 6, total: 6 },
  suite: { coverageLine: 100, coverageBranch: 95, lintClean: true, ran: true, testsPassed: false, unit: 42 },
  perf: null,
});
assert.strictEqual(testsFailed.coverage, 0, "테스트 실패 시 커버리지 0점이어야 한다");

const testsPassed = scoreLang({
  conformance: { passed: 20, failed: 0 }, security: { defended: 6, total: 6 },
  suite: { coverageLine: 100, coverageBranch: 95, lintClean: true, ran: true, testsPassed: true, unit: 42 },
  perf: null,
});
assert.ok(testsPassed.coverage >= 90, "테스트 통과 시 커버리지 크레딧이 주어져야 한다");

// testsPassed 필드가 아예 없는(구버전) 신호도 크레딧을 받지 못한다 — fail-closed.
const legacySignal = scoreLang({
  conformance: { passed: 20, failed: 0 }, security: { defended: 6, total: 6 },
  suite: { coverageLine: 100, coverageBranch: 95, lintClean: true, ran: true, unit: 42 },
  perf: null,
});
assert.strictEqual(legacySignal.coverage, 0, "testsPassed 부재 신호는 fail-closed여야 한다");

// ── 돈 시험이 0 개인 「통과」도 크레딧이 없다 ─────────────────────────────────────
// 테스트 명령이 아무것도 못 찾고 0 으로 끝나거나 스크립트가 요약 줄을 못 읽으면 testsPassed:true · unit 0 이 된다 —
// 돌지 않은 스위트와 구분되지 않는다(PR 0 에서 dotnet · php 스위트가 실제로 0 개로 돌았다). 판정은 run-suite.sh 와 같다.
for (const unit of [0, undefined, "42", 1.5]) {
  const vacuous = scoreLang({
    conformance: { passed: 20, failed: 0 }, security: { defended: 6, total: 6 },
    suite: { coverageLine: 100, coverageBranch: 95, lintClean: true, ran: true, testsPassed: true, unit },
    perf: null,
  });
  assert.strictEqual(vacuous.coverage, 0, `unit ${JSON.stringify(unit)} 인 통과에 커버리지 크레딧을 줬다`);
}

console.log("score.test OK");
