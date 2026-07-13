import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// 고정 언어 순서(결정적 출력 — Date/random 사용 불가) + 미지정 언어는 알파벳순으로 뒤에 붙는다.
const LANG_ORDER = ["go", "dotnet", "node", "python", "java", "php", "rust", "ruby", "kotlin"];

const mark = (v) => (v ? "✓" : "✗");
// conformance는 {passed,failed}, security는 {defended,total} 형태라 필드명이 다르다 — 결측(undefined)이면 0/0.
const ratio = (r) => {
  if (!r) return "0/0";
  const p = r.passed ?? r.defended ?? 0;
  let n = r.total;
  if (n == null) n = r.passed != null ? r.passed + (r.failed ?? 0) : 0;
  return `${p}/${n}`;
};

/**
 * 매트릭스의 어느 셀이라도 ✗ 이거나 conformance/security가 만점이 아닌 언어를 실패로 본다.
 * 매트릭스가 결과 담체다 — 이 판정이 install-all 잡의 종료코드를 결정한다.
 *
 * @param {Array<object>} signals
 * @returns {string[]} 실패한 언어 이름(신호 순서 유지)
 */
export function failedLangs(signals) {
  return signals
    .filter((s) => {
      const stages = [s.artifactBuilt, s.published, s.installed, s.quickstartOk, s.appBoot];
      if (stages.some((v) => v !== true)) return true;
      const cf = s.conformance ?? { passed: 0, failed: 0 };
      if ((cf.failed ?? 0) > 0 || (cf.passed ?? 0) === 0) return true;
      const sec = s.security ?? { defended: 0, total: 0 };
      if ((sec.total ?? 0) === 0 || (sec.defended ?? 0) < sec.total) return true;
      return false;
    })
    .map((s) => s.lang);
}

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

  // --strict: 매트릭스에 ✗가 하나라도 있으면 exit 1. 부분실패 격리(다른 언어를 계속 검증)는
  // 유지하되, 잡 종료코드로는 반드시 드러나야 한다. 이 플래그가 없던 시절 install-all 잡은
  // java/php가 publish 단계에서 죽어도 success로 표시됐다(2026-07-08·07-09 실측).
  if (process.argv.includes("--strict")) {
    const failed = failedLangs(signals);
    if (failed.length > 0) {
      console.error(`[install-matrix] 실패한 언어: ${failed.join(", ")}`);
      process.exit(1);
    }
    console.log(`[install-matrix] ${signals.length}개 언어 전부 통과`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
