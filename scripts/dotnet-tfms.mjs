#!/usr/bin/env node
// .NET 대상 목록을 JSON 배열(버전 오름차순)로 낸다 — dotnet-ci 가 대상 레그 매트릭스와 통합 잡의 대상을 여기서 받는다.
// ⚠️ 목록을 워크플로에 다시 적지 않는 이유: 대상을 늘리고 레그를 잊으면 그 대상은 한 번도 시험되지 않은 채 게시된다.
// 읽는 규칙은 scripts/lib/dotnet-tfm.mjs 가 소유한다(check-docs 의 하한 · doctor 의 요구 SDK 와 같은 규칙).
//
// 사용: node scripts/dotnet-tfms.mjs [Directory.Build.props 경로 — 기본 dotnet/Directory.Build.props]
// 종료코드: 0 · 2(파일 없음 · 선언 없음 · 모르는 모양)
import { readFileSync } from 'node:fs'
import { dotnetTfms } from './lib/dotnet-tfm.mjs'

const file = process.argv[2] ?? 'dotnet/Directory.Build.props'
try {
  const tfms = dotnetTfms(readFileSync(file, 'utf8'))
  if (!tfms.length) throw new Error(`${file} 에 TargetFramework(s) 선언이 없다`)
  console.log(JSON.stringify(tfms))
} catch (e) {
  console.error(`::error::.NET 대상 목록을 읽지 못했다 — ${e.message}`)
  process.exit(2)
}
