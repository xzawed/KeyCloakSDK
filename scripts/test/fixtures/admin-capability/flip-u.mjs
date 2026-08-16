#!/usr/bin/env node
// 표의 한 언어 × users 셀에서 U(4번째 표기)만 뒤집는다. 자가테스트 입력용.
import { readFileSync } from "node:fs";

const PRESENT = "\u2705";
const ABSENT = "\u2014";
const ZWSP = "\u200B";

const [, , doc, lang, want] = process.argv;
if (!doc || !lang || (want !== "present" && want !== "absent")) {
  console.error("usage: flip-u.mjs <doc> <Lang> present|absent");
  process.exit(2);
}

const text = readFileSync(doc, "utf8");
const start = text.indexOf("### Direct coverage");
const slice = start >= 0 ? text.slice(start) : text;
const re = new RegExp(`^(\\| \\*\\*${lang.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\*\\*[^|]*\\| )([^|]+)\\|`, "m");
const m = slice.match(re);
if (!m) {
  console.error(`no row for ${lang}`);
  process.exit(2);
}
const raw = m[2];
const marks = [...raw.replaceAll(ZWSP, "").trim()].filter((ch) => ch === PRESENT || ch === ABSENT);
if (marks.length !== 5) {
  console.error(`users cell for ${lang} is not 5 marks: ${JSON.stringify(raw)}`);
  process.exit(2);
}
marks[3] = want === "present" ? PRESENT : ABSENT;
const rebuilt = marks
  .map((ch, i) => (ch === ABSENT && marks[i + 1] === ABSENT ? ABSENT + ZWSP : ch))
  .join("");
if (start < 0) {
  console.error("### Direct coverage not found");
  process.exit(2);
}
process.stdout.write(text.slice(0, start) + slice.replace(re, `$1${rebuilt} |`));
