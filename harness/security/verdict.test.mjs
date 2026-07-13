import assert from "node:assert";
import { classify, isDefended, REJECT_STATUSES } from "./verdict.mjs";

// 정상 거부 — Keycloak 검증 실패는 401, 잘못된 요청은 400.
assert.strictEqual(classify(401), "rejected");
assert.strictEqual(classify(400), "rejected");
assert.ok(isDefended(401));
assert.ok(isDefended(400));

// 통과 = BYPASS. 공격 토큰이 수락됐다.
assert.strictEqual(classify(200), "accepted");
assert.ok(!isDefended(200));

// 5xx = 크래시. 프로브가 앱을 죽였다 — 방어가 아니다.
assert.strictEqual(classify(500), "crashed");
assert.strictEqual(classify(502), "crashed");
assert.ok(!isDefended(500), "500은 방어 성공이 아니다");

// 그 밖의 상태(404 라우팅 실수, 429 등)는 방어로 세지 않는다.
assert.strictEqual(classify(404), "unexpected");
assert.ok(!isDefended(404));

assert.deepStrictEqual(REJECT_STATUSES, [400, 401]);

console.log("verdict.test.mjs: 모든 assert 통과");
