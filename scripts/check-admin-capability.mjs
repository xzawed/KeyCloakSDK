#!/usr/bin/env node
// Admin capability matrix의 U(update) 열을 아홉 언어 소스와 대조한다.
//
// 표는 9언어 × 5리소스 × C/G/L/U/D = 225셀이지만 이 가드는 U 45셀만 본다.
// C/G/L 이름은 언어마다 갈린다(PHP import/all, Ruby list, Java findByClientId/search).
// U는 update / Update / UpdateAsync / update_<resource> 로 수렴한다.
//
// ⚠️ **L열로 넓히는 것은 이미 기각됐다** — 되살릴 조건이 오기 전에 다시 만들지 않는다.
// 판정과 되살릴 조건: docs/governance/process.md §3 기각 표.
// 요지: 6개 PR·L셀 9개가 뒤집히는 동안 실제 드리프트 0건이었고, 225셀이 전부 ✅가 된 지금
// 남는 실패 모드는 removal뿐인데 그건 단위·E2E가 같은 커밋에서 먼저 깬다.
// 되살릴 조건은 **10번째 언어 행이 추가될 때**(손으로 25셀을 쓰는 그 순간).
//
// 기대값을 여기에 적지 않는다 — 표의 셀과 소스 선언을 같은 자리에서 읽어 비교한다.
import { existsSync, readFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";

const PRESENT = "\u2705";
const ABSENT = "\u2014";
const ZWSP = "\u200B";

const RESOURCES = ["users", "clients", "realms", "roles", "groups"];
const LANGS = {
  Ruby: "ruby",
  Java: "java",
  Kotlin: "kotlin",
  Python: "python",
  Node: "node",
  Go: "go",
  ".NET": "dotnet",
  PHP: "php",
  Rust: "rust",
};

const PASCAL = {
  users: "Users",
  clients: "Clients",
  realms: "Realms",
  roles: "Roles",
  groups: "Groups",
};
const SINGULAR = {
  users: "user",
  clients: "client",
  realms: "realm",
  roles: "role",
  groups: "group",
};

let rootArg = null;
let docArg = null;
let printSources = false;
for (const arg of process.argv.slice(2)) {
  if (arg.startsWith("--doc=")) {
    docArg = arg.slice("--doc=".length);
  } else if (arg === "--print-sources") {
    printSources = true;
  } else if (!arg.startsWith("--") && rootArg === null) {
    rootArg = arg;
  }
}

const ROOT = resolve(rootArg ?? ".");
const DOC = resolve(docArg ?? join(ROOT, "docs/guides/getting-started.md"));

function fail(msg) {
  console.error(`admin-capability: ${msg}`);
  process.exit(1);
}

function read(p) {
  try {
    return readFileSync(p, "utf8");
  } catch (e) {
    fail(`cannot read ${p}: ${e.message}`);
  }
}

function parseMarks(cell, where) {
  const marks = [...cell.replaceAll(ZWSP, "").trim()].filter(
    (ch) => ch === PRESENT || ch === ABSENT,
  );
  if (marks.length !== 5) {
    fail(`${where}: cell is not 5 C/G/L/U/D marks: ${JSON.stringify(cell)}`);
  }
  return {
    C: marks[0] === PRESENT,
    G: marks[1] === PRESENT,
    L: marks[2] === PRESENT,
    U: marks[3] === PRESENT,
    D: marks[4] === PRESENT,
  };
}

function parseTable(text) {
  const heading = text.indexOf("## Admin capability matrix");
  if (heading < 0) fail(`${DOC}: no "## Admin capability matrix" heading`);
  const direct = text.indexOf("### Direct coverage", heading);
  if (direct < 0) fail(`${DOC}: no "### Direct coverage" under the matrix`);
  const end = text.indexOf("C=create G=get L=list/find U=update D=delete", direct);
  if (end < 0) fail(`${DOC}: no C/G/L/U/D legend after the table`);
  const block = text.slice(direct, end);

  const rows = {};
  for (const line of block.split(/\r?\n/)) {
    const m = line.match(/^\| \*\*([^*]+)\*\*[^|]*\|(.*)\|$/);
    if (!m) continue;
    const label = m[1].trim();
    const lang = LANGS[label];
    if (!lang) fail(`${DOC}: unknown language row ${JSON.stringify(label)}`);
    const cells = m[2].split("|").map((c) => c.trim());
    if (cells.length !== 5) {
      fail(`${DOC}: ${label} row has ${cells.length} resource cells, want 5`);
    }
    rows[lang] = {};
    for (let i = 0; i < 5; i++) {
      rows[lang][RESOURCES[i]] = parseMarks(cells[i], `${label} ${RESOURCES[i]}`);
    }
  }

  const missing = Object.values(LANGS).filter((id) => !rows[id]);
  if (missing.length) fail(`${DOC}: missing language rows: ${missing.join(", ")}`);
  const seen = Object.keys(rows).length;
  if (seen !== 9) fail(`${DOC}: expected 9 language rows, got ${seen}`);
  return rows;
}

function hasDecl({ file, re, where }) {
  if (!existsSync(file)) fail(`${where}: source file missing: ${file}`);
  return re.test(read(file));
}

// (lang, resource) → 이 셀의 U를 판정하는 프로브들.
//
// 경로를 여기 한 자리에만 둔다 — 자가테스트(`--print-sources`)가 같은 목록을 읽어
// 임시 트리를 만들므로, 테스트가 경로를 손으로 다시 적는 2차 정의 자리가 생기지 않는다.
// python만 프로브가 둘이다(sync + aio 미러는 표에서 한 행이라 갈리면 안 된다).
function updateProbes(lang, resource) {
  const P = PASCAL[resource];
  const s = SINGULAR[resource];
  const at = (rel, re, where) => ({ file: join(ROOT, rel), re, where });
  switch (lang) {
    case "php":
      return [
        at(`php/src/Admin/${P}Resource.php`, /public function update\s*\(/, `php ${resource}`),
      ];
    case "go":
      return [
        at(
          `go/admin_${resource}.go`,
          new RegExp(`func \\([^)]*\\*${P}Resource\\) Update\\s*\\(`),
          `go ${resource}`,
        ),
      ];
    case "rust":
      return [
        at(
          "rust/src/admin.rs",
          new RegExp(`pub async fn update_${s}\\s*\\(`),
          `rust ${resource}`,
        ),
      ];
    case "java":
      return [
        at(
          `java/keycloak-sdk-admin/src/main/java/io/github/xzawed/keycloak/admin/${P}Resource.java`,
          /public\s+\S+\s+update\s*\(/,
          `java ${resource}`,
        ),
      ];
    case "kotlin":
      return [
        at(
          `kotlin/src/main/kotlin/io/github/xzawed/keycloak/admin/${P}.kt`,
          /public suspend fun update\s*\(/,
          `kotlin ${resource}`,
        ),
      ];
    case "node":
      return [at(`node/src/admin/${resource}.ts`, /(?:async\s+)?update\s*\(/, `node ${resource}`)];
    case "python":
      return [
        at(
          `python/src/keycloak_sdk/admin/${resource}.py`,
          /^\s+def update\s*\(/m,
          `python ${resource}`,
        ),
        at(
          `python/src/keycloak_sdk/aio/admin/${resource}.py`,
          /^\s+(?:async\s+)?def update\s*\(/m,
          `python aio ${resource}`,
        ),
      ];
    case "dotnet":
      return [
        at(
          `dotnet/src/Xzawed.Keycloak.Sdk/Admin/${P}Resource.cs`,
          /public\s+(?:async\s+)?Task(?:<[^>]+>)?\s+UpdateAsync\s*\(/,
          `dotnet ${resource}`,
        ),
      ];
    case "ruby":
      return [at(`ruby/lib/keycloak_sdk/admin/${resource}.rb`, /^\s+def update\b/m, `ruby ${resource}`)];
    default:
      return fail(`no extractor for ${lang}`);
  }
}

function sourceHasUpdate(lang, resource) {
  const results = updateProbes(lang, resource).map(hasDecl);
  if (results.some((r) => r !== results[0])) {
    fail(`${lang} ${resource}: 미러 소스가 갈렸다(${results.join(", ")}) — 표는 한 행이다`);
  }
  return results[0];
}

// --print-sources: 이 가드가 읽는 소스 파일 경로를 ROOT 상대로 한 줄씩 낸다.
// 자가테스트가 소스측 변이(선언 삭제)를 표현하려면 임시 트리를 만들어야 하는데,
// 그 목록을 손으로 적으면 2차 정의 자리가 된다. 여기서 파생시킨다.
if (printSources) {
  const rels = new Set();
  for (const id of Object.values(LANGS)) {
    for (const resource of RESOURCES) {
      for (const { file } of updateProbes(id, resource)) {
        rels.add(relative(ROOT, file).split("\\").join("/"));
      }
    }
  }
  for (const r of [...rels].sort()) console.log(r);
  process.exit(0);
}

const table = parseTable(read(DOC));
const errors = [];
let checked = 0;
for (const [label, id] of Object.entries(LANGS)) {
  for (const resource of RESOURCES) {
    const claimed = table[id][resource].U;
    const actual = sourceHasUpdate(id, resource);
    checked += 1;
    if (claimed !== actual) {
      errors.push(
        `${label} ${resource}.U: table=${claimed ? "present" : "absent"} source=${actual ? "present" : "absent"}`,
      );
    }
  }
}

if (checked !== 45) fail(`internal: checked ${checked} cells, want 45`);
if (errors.length) {
  console.error(`admin-capability: U-column drift (${errors.length}):`);
  for (const e of errors) console.error(`  ${e}`);
  process.exit(1);
}
console.log(`admin-capability: checked 45 U-cells, 0 drift`);
