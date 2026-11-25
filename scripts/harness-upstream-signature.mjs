#!/usr/bin/env node
// harness-upstream-signature.mjs — 실패한 harness 실행의 로그가 **상류 다운로드 거절**인가(`.github/workflows/harness-rerun.yml` 이 쓴다).
//
// 왜: Maven Central(429 · `(absent)`) · Gradle 플러그인 포털이 러너 하나를 잡 내내(잰 넷 ≥ 15–36 분) 거절해 harness 가
// 빨개졌고, 새 러너의 재실행은 통과했다(등록부 harness-central-refuses-runner). composer 의 GitHub zipball 5xx 도 같은 부류로
// 센다 — 예약 실패 넷(11-22 · 11-08 · 09-19 · 08-22)은 모두 다음 예약 실행이 초록이었다. 빌드 안의 `build_with_retry`
// (3 회 · 60 초 — #1210)는 그 창을 못 덮는다. 그런 실행만 한 번 다시 돌리고, 제품 실패는 빨간 채 둔다.
//
// ⚠️ **좁게 맞춘다** — 한 줄에 **거절 모양 AND 다운로드 맥락**이 함께 있어야 한다. 낱말 하나(`Connection reset` · `timed out` ·
// `429`)로는 맞지 않는다: 제품 자신의 시험과 k6 가 그 낱말을 찍는다(실측: 제품 실패 23 개 로그에 `429 complete` ·
// `(timeout 240s)` · `Fetching timeout 0.6.1` · `(18 kB at 504 kB/s)` 가 있다). 서명마다 아래 주석이 두 부분을 가른다.
// 넓히면 제품 실패가 재실행으로 덮인다 — 넓히기 전에 그 제품 실패 줄을 자가테스트의 음성에 먼저 넣는다.
// ⚠️ 거짓 양성의 값은 재실행 한 번이다(attempt 1 만 다시 돈다) — 거짓 음성의 값은 지금처럼 빨간 밤이다.
//
// 사용: node scripts/harness-upstream-signature.mjs <로그 파일>   — `gh run view <id> --log-failed` 의 출력(잡 · 스텝 · 시각 칸)
//   0 = 맞았다 — 서명마다 처음 맞은 줄을 찍는다
//   1 = 맞는 줄이 없다 — 제품 실패로 본다
//   2 = 판정 불가 — 인자 오류 · 못 읽음 · 빈 로그. ⚠️ 만료된 로그(API 가 HTTP 410 — 2026-08-19 32211733068)는 gh 가 아무것도
//       쓰지 않아 빈 파일로 온다. 그것이 1 이 되면 판정하지 않은 것을 「제품 실패」라 말하게 된다.
//
// 자가테스트: scripts/test/test-harness-upstream-signature.sh
import { readFileSync } from 'node:fs'

// [이름, 정규식] — 줄은 실측 실행(날짜 · run id)에서 왔다. ⚠️ 정규식에 `g` 를 달지 않는다 — `test` 가 lastIndex 를 들고 다닌다.
const SIGNATURES = [
  // Central 이 전송을 429 로 거절 — 거절 `status code: 429` · 맥락 `Could not transfer artifact … from/to central (Central URL)`
  // (2026-11-24 PR 실행: 한 러너가 ≥ 24 분 429 를 받았고 새 러너는 통과했다).
  ['central-429', /Could not transfer artifact \S+ from\/to central \(https:\/\/repo\.maven\.apache\.org\/maven2\): status code: 429\b/],
  // Central 이 있는 아티팩트를 없다고 답함 — 거절 `(absent): Could not find artifact` · 맥락 `… in central (Central URL)`
  // (44979301872 · 2026-11-22 — junit-bom 6.1.3 은 Central 에 있다).
  ['central-absent', /\(absent\): Could not find artifact \S+ in central \(https:\/\/repo\.maven\.apache\.org\/maven2\)/],
  // Gradle 플러그인 해석 실패 — 거절 `was not found` · 맥락 `Plugin [id: …, version: …] … in any of the following sources`
  // (44979301872 — com.vanniktech.maven.publish 0.37.0 은 포털에 있다).
  ['gradle-plugin', /\bPlugin \[id: '[^']+', version: '[^']+'\] was not found in any of the following sources\b/],
  // 플러그인 포털의 아티팩트 호스트 — 거절 `Could not GET` · 맥락 그 호스트의 URL(35417940151 · 09-19).
  ['gradle-portal-get', /Could not GET 'https:\/\/plugins-artifacts\.gradle\.org\/[^'\s]+'/],
  // 같은 호스트의 DNS 일시 실패 — 거절 `Try again`(musl 의 EAI_AGAIN 문구 — 빌드 이미지는 Alpine) · 맥락 그 호스트(09-19).
  ['gradle-portal-dns', /\bplugins-artifacts\.gradle\.org: Try again\b/],
  // composer 가 GitHub zipball 을 못 받음 — 거절 `could not be downloaded (HTTP/… 5xx` · 맥락 `Failed to download … from dist:
  // The "https://api.github.com/repos/…/zipball/…"`(42441515425 · 11-08 · 32548583740 · 08-22 — 둘 다 HTTP/2 504).
  [
    'github-dist-5xx',
    /Failed to download \S+ from dist: The "https:\/\/api\.github\.com\/repos\/[^"\s]+\/zipball\/[^"\s]+" file could not be downloaded \(HTTP\/[\d.]+ 5\d\d\b/,
  ],
]

// gh `--log-failed` 의 줄 = 잡 <TAB> 스텝 <TAB> [BOM]시각 본문 — 본문만 본다(잡 · 스텝 이름이 서명 행세를 하지 않게).
const body = (line) =>
  line
    .replace(/^[^\t]*\t[^\t]*\t/, '')
    .replace(/^﻿/, '')
    .replace(/^\d{4}-\d\d-\d\dT[\d:.]+Z /, '')
    .trim()

function main(argv) {
  if (argv.length !== 1) {
    console.error('usage: node scripts/harness-upstream-signature.mjs <log file>   (gh run view <id> --log-failed > <log file>)')
    return 2
  }
  let text
  try {
    text = readFileSync(argv[0], 'utf8')
  } catch (e) {
    console.error(`harness-upstream-signature: 로그를 읽지 못했다 — ${argv[0]} (${e.code ?? e.message}) — 판정 불가`)
    return 2
  }
  if (text.trim() === '') {
    console.error(`harness-upstream-signature: 로그가 비었다 — ${argv[0]} — 판정 불가(만료된 로그는 gh 가 아무것도 쓰지 않는다)`)
    return 2
  }
  const lines = text.split(/\r?\n/)
  if (lines.at(-1) === '') lines.pop()
  const hits = []
  for (const [name, re] of SIGNATURES) {
    const i = lines.findIndex((l) => re.test(body(l)))
    if (i >= 0) hits.push({ name, n: i + 1, text: body(lines[i]) })
  }
  if (hits.length === 0) {
    console.log(`harness-upstream-signature: 맞는 줄 없음 — ${lines.length} 줄에 상류 다운로드 거절 서명이 없다(제품 실패로 본다)`)
    return 1
  }
  console.log(`harness-upstream-signature: 상류 다운로드 거절 — 서명 ${hits.length} 개`)
  // ⚠️ 로그에서 온 글 앞에 `[이름]` 을 붙여 찍는다 — `::` 로 시작하는 줄은 러너가 워크플로 명령으로 읽는다.
  for (const h of hits) console.log(`  [${h.name}] 줄 ${h.n}: ${h.text}`)
  return 0
}

process.exitCode = main(process.argv.slice(2))
