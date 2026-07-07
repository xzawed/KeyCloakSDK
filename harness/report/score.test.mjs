import assert from "node:assert";
import { scoreLang, grade, feedback } from "./score.mjs";
// 만점 언어
const perfect = scoreLang({
  conformance: { passed: 20, failed: 0 }, security: { defended: 6, total: 6 },
  suite: { coverageLine: 100, coverageBranch: 95, lintClean: true, ran: true }, perf: null,
});
assert.strictEqual(perfect.functional, 100);
assert.strictEqual(perfect.security, 100);
assert.ok(perfect.overall >= 90 && grade(perfect.overall) === "A");
// 보안 결함 언어 → 보안 점수·피드백
const weak = scoreLang({
  conformance: { passed: 18, failed: 2 }, security: { defended: 4, total: 6 },
  suite: { coverageLine: 80, coverageBranch: 70, lintClean: true, ran: true }, perf: null,
});
assert.ok(weak.security < 70, "security should reflect 4/6");
const fb = feedback(weak, { security: { probes: [{ name: "alg=none rejected", defended: false }] } });
assert.ok(fb.some(f => /보안|alg=none/.test(f)), "should recommend fixing the failed probe");
console.log("score.test OK");
