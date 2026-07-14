import assert from "node:assert";
import { buildMatrix, failedLangs } from "./install-matrix.mjs";

// all-green go
const md = buildMatrix([
  { lang: "go", artifactBuilt: true, published: true, installed: true, quickstartOk: true, appBoot: true, conformance: { passed: 26, failed: 0 }, security: { defended: 9, total: 9 } },
  // 부분실패(rust): installed:false + error 사유
  { lang: "rust", artifactBuilt: true, published: true, installed: false, quickstartOk: false, appBoot: false, conformance: { passed: 0, failed: 0 }, security: { defended: 0, total: 0 }, error: "cargo build --offline: unresolved source" },
  // 결측 필드(ruby) — conformance/security 등 일부 누락돼도 무크래시
  { lang: "ruby", artifactBuilt: true, published: false, installed: false, quickstartOk: false, appBoot: false },
]);

// 언어당 1행 — 헤더 구분선을 빼면 정확히 3개 언어 행
const dataRows = md.split("\n").filter(l => /^\|\s*(go|rust|ruby)\s*\|/.test(l));
assert.strictEqual(dataRows.length, 3, "expected exactly one row per language");

// 각 단계 ✓/✗ + conformance/security p/n 렌더
assert.match(md, /\|\s*go\s*\|.*26\/26.*9\/9/);
assert.match(md, /\|\s*rust\s*\|.*✗.*unresolved source/);

// 결측 신호는 무크래시 + 결측 항목은 ✗(부재=미달성)로 렌더
assert.match(md, /\|\s*ruby\s*\|/);

// ── failedLangs: 매트릭스 판정이 install-all 잡의 종료코드를 결정한다 (PR 0) ──────────
// 모든 단계가 ✓인 언어는 실패가 아니다.
const okLang = {
  lang: "go", artifactBuilt: true, published: true, installed: true,
  quickstartOk: true, appBoot: true,
  conformance: { passed: 26, failed: 0 }, security: { defended: 9, total: 9 },
};
assert.deepStrictEqual(failedLangs([okLang]), []);

// publish에서 죽은 언어는 실패다 (2026-07-08·07-09 CI의 java/php).
const publishFailed = {
  lang: "java", artifactBuilt: false, published: false, installed: false,
  quickstartOk: false, appBoot: false,
  conformance: { passed: 0, failed: 0 }, security: { defended: 0, total: 0 },
  error: "publish: publish/java.sh 실패",
};
assert.deepStrictEqual(failedLangs([publishFailed]), ["java"]);

// 설치·부팅은 됐지만 conformance가 깨진 언어도 실패다.
const conformanceFailed = {
  lang: "node", artifactBuilt: true, published: true, installed: true,
  quickstartOk: true, appBoot: true,
  conformance: { passed: 25, failed: 1 }, security: { defended: 9, total: 9 },
};
assert.deepStrictEqual(failedLangs([conformanceFailed]), ["node"]);

// 보안 프로브가 하나라도 뚫린 언어도 실패다.
const securityFailed = {
  lang: "php", artifactBuilt: true, published: true, installed: true,
  quickstartOk: true, appBoot: true,
  conformance: { passed: 26, failed: 0 }, security: { defended: 8, total: 9 },
};
assert.deepStrictEqual(failedLangs([securityFailed]), ["php"]);

// 여러 언어가 섞여도 실패 언어만 뽑는다.
assert.deepStrictEqual(failedLangs([okLang, publishFailed, conformanceFailed]), ["java", "node"]);

// kotlin은 9번째 언어다. LANG_ORDER에 없으면 "미상 언어"로 맨 끝에 정렬된다(PR #26 누락).
const orderRows = buildMatrix([
  { lang: "kotlin", artifactBuilt: true, published: true, installed: true, quickstartOk: true, appBoot: true, conformance: { passed: 26, failed: 0 }, security: { defended: 9, total: 9 } },
  { lang: "go", artifactBuilt: true, published: true, installed: true, quickstartOk: true, appBoot: true, conformance: { passed: 26, failed: 0 }, security: { defended: 9, total: 9 } },
]);
const goIdx = orderRows.indexOf("| go |");
const kotlinIdx = orderRows.indexOf("| kotlin |");
assert.ok(goIdx > 0 && kotlinIdx > goIdx, "go가 kotlin보다 먼저 정렬되어야 한다(LANG_ORDER 등재 확인)");

console.log("install-matrix.test OK");
