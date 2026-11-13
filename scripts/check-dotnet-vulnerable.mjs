#!/usr/bin/env node
// .NET 취약 패키지 감사 판정 — `dotnet list <csproj> package --vulnerable --include-transitive --format json` 의 출력을 읽는다.
//
// 왜 텍스트 grep 이 아닌가(실측 2026-11-13, .NET SDK 10.0.102): 대상이 둘(`net8.0;net10.0`)인 프로젝트에서 net8.0 에만
// High 취약 패키지를 넣으면 텍스트 출력은
//     Project `Probe` has the following vulnerable packages
//        [net10.0]: No vulnerable packages for this framework.
//        [net8.0]:
//        > Newtonsoft.Json      12.0.1      12.0.1     High       https://github.com/advisories/GHSA-5crp-9r3c-p9vr
// 이고, 옛 판정 `grep -qi "no vulnerable packages"` 는 **깨끗한 대상의 줄**에 걸려 통과했다. `dotnet list` 도 0 으로 끝났다.
// 대상이 하나일 때는 그 줄이 없어서 드러나지 않았다 — 대상을 늘리는 순간 열리는 틈이다.
//
// 종료코드(이 저장소의 관례): 0 = 깨끗하다 · 1 = 취약 패키지가 있다 · 2 = 판정 불가
// ⚠️ 판정 불가를 깨끗함과 가르는 것도 실측에서 왔다: 소스가 거부되면(HTTP 소스) JSON 의 `projects` 는 깨끗한 실행과
// **같은 모양**(`frameworks` 키 자체가 없다)이고 다른 점은 `problems` 하나뿐이었다. 네트워크가 끊기면 JSON 이 아니라
// 오류 텍스트가 나온다. 깨끗한 실행은 대상을 나열하지 않으므로 「대상이 비었다」로는 공허한 실행을 가를 수 없다.
//
// 사용: node scripts/check-dotnet-vulnerable.mjs <report.json>
import { readFileSync } from 'node:fs'

const invalid = (msg) => {
  console.log(`::error::dotnet 취약 패키지 감사 판정 불가 — ${msg}`)
  process.exit(2)
}
const args = process.argv.slice(2)
if (args.length !== 1) invalid('사용: node scripts/check-dotnet-vulnerable.mjs <report.json>')
const file = args[0]
let text
try {
  text = readFileSync(file, 'utf8')
} catch (e) {
  invalid(`${file} 를 읽지 못했다: ${e.message}`)
}
let report
try {
  report = JSON.parse(text)
} catch {
  invalid(`${file} 가 JSON 이 아니다 — dotnet list 가 보고서 대신 오류를 냈다: ${text.trim().split('\n')[0].slice(0, 200)}`)
}
if (report?.version !== 1) invalid(`보고서 판(version)이 1 이 아니다: ${JSON.stringify(report?.version)}`)
const params = String(report.parameters ?? '').split(/\s+/)
for (const p of ['--vulnerable', '--include-transitive']) {
  if (!params.includes(p)) invalid(`감사 인자에 ${p} 가 없다(parameters: ${JSON.stringify(report.parameters)})`)
}
if (Array.isArray(report.problems) && report.problems.length) {
  invalid(`감사가 문제를 보고했다 — ${report.problems.map((p) => `[${p.level}] ${p.text}`).join(' · ')}`)
}
if (!Array.isArray(report.projects) || report.projects.length === 0) invalid('감사한 프로젝트가 없다')

const hits = []
for (const project of report.projects) {
  for (const fw of project.frameworks ?? []) {
    for (const [kind, list] of [['top-level', fw.topLevelPackages], ['transitive', fw.transitivePackages]]) {
      for (const pkg of list ?? []) {
        for (const v of pkg.vulnerabilities ?? []) {
          hits.push(`${fw.framework} · ${kind} · ${pkg.id} ${pkg.resolvedVersion} · ${v.severity} · ${v.advisoryurl}`)
        }
      }
    }
  }
}
if (hits.length) {
  for (const h of hits) console.log(`::error::취약 패키지: ${h}`)
  console.log(`FAIL dotnet 취약 패키지 ${hits.length}건 (프로젝트 ${report.projects.length})`)
  process.exit(1)
}
console.log(`OK dotnet 취약 패키지 0건 (프로젝트 ${report.projects.length})`)
