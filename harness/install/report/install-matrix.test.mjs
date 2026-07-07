import assert from "node:assert";
import { buildMatrix } from "./install-matrix.mjs";

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

console.log("install-matrix.test OK");
