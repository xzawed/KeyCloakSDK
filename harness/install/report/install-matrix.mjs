import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// 고정 언어 순서(결정적 출력 — Date/random 사용 불가) + 미지정 언어는 알파벳순으로 뒤에 붙는다.
const LANG_ORDER = ["go", "dotnet", "node", "python", "java", "php", "rust", "ruby"];

const mark = (v) => (v ? "✓" : "✗");
// conformance는 {passed,failed}, security는 {defended,total} 형태라 필드명이 다르다 — 결측(undefined)이면 0/0.
const ratio = (r) => {
  if (!r) return "0/0";
  const p = r.passed ?? r.defended ?? 0;
  let n = r.total;
  if (n == null) n = r.passed != null ? r.passed + (r.failed ?? 0) : 0;
  return `${p}/${n}`;
};

function sortSignals(signals) {
  const rank = (lang) => {
    const i = LANG_ORDER.indexOf(lang);
    return i === -1 ? LANG_ORDER.length : i;
  };
  return [...signals].sort((a, b) => {
    const ra = rank(a.lang), rb = rank(b.lang);
    if (ra !== rb) return ra - rb;
    return a.lang.localeCompare(b.lang);
  });
}

export function buildMatrix(signals) {
  const rows = sortSignals(signals);
  let md = "# 설치·동작 검증 매트릭스 (INSTALL-MATRIX)\n\n";
  md += "| lang | artifact | publish | install | quickstart | app-boot | conformance | security | notes |\n";
  md += "|---|---|---|---|---|---|---|---|---|\n";
  rows.forEach((s) => {
    md += `| ${s.lang} | ${mark(s.artifactBuilt)} | ${mark(s.published)} | ${mark(s.installed)} | ${mark(s.quickstartOk)} | ${mark(s.appBoot)} | ${ratio(s.conformance)} | ${ratio(s.security)} | ${s.error ?? ""} |\n`;
  });
  return md;
}

function loadSignals(dir) {
  const signalsDir = path.join(dir, "signals");
  let files = [];
  try {
    files = fs.readdirSync(signalsDir).filter((f) => f.endsWith(".install.json"));
  } catch {
    console.warn(`install-matrix: signals directory not found: ${signalsDir}`);
    return [];
  }
  const signals = [];
  for (const file of files) {
    const full = path.join(signalsDir, file);
    try {
      const raw = fs.readFileSync(full, "utf8");
      signals.push(JSON.parse(raw));
    } catch (err) {
      console.warn(`install-matrix: skipping unreadable/unparseable signal file ${full}: ${err.message}`);
    }
  }
  return signals;
}

export function main() {
  const signals = loadSignals(__dirname);
  const md = buildMatrix(signals);
  const outPath = path.join(__dirname, "INSTALL-MATRIX.md");
  fs.writeFileSync(outPath, md);
  console.log(`wrote ${outPath}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
