#!/usr/bin/env node
// 그려지는 문서(소비자가 IDE 호버·문서 사이트로 보는 공개 API 문서 산출물)에 한글이 다시 들어오는지 센다 —
// 등록부 `korean-api-docs-in-published-packages`.
//
// 왜 소스가 아니라 산출물인가: 판정 기준이 「산출물의 한글 0」이다(언어마다 그 산출물로 잰 번역 PR 들). 소스의 한글
// 주석은 대부분 그려지지 않는 내부 주석이고, 어느 주석이 그려지는지는 문서 도구가 정한다(pydoc 은 독스트링 없는
// 공개 def 위의 `#` 주석을, YARD 는 「View source」로 공개 메서드 본문의 줄 끝 주석을 그린다). 그래서 레인 CI 가
// 산출물을 만들고 이 스크립트가 센다.
//
// ⚠️ plain `grep -P` 는 이 범위를 못 써 거짓 0 을 낸다(등록부 경고) — 정규식은 JS 의 것을 쓴다.
// ⚠️ 읽은 파일이 `--min-files` 보다 적으면 실패한다(exit 2) — 산출물이 안 만들어진 채 초록이 되는 것이 이 부류의
// 전형적인 공허함이다.
//
// 사용: node scripts/check-rendered-docs-hangul.mjs <산출물 디렉터리> [--ext=.html,.d.ts] [--skip=src/,static/]
//         [--min-files=N]
//   --ext   이 확장자로 끝나는 파일만 센다(생략하면 전부)
//   --skip  디렉터리 기준 상대 경로가 이 접두로 시작하면 건너뛴다(rustdoc 의 소스 보기 `src/` 등)
//   exit 0 = 훑은 파일 ≥ min 이고 한글 줄 0 · 1 = 한글 줄이 있다(자리를 찍는다) · 2 = 판정 불가
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative, sep } from 'node:path'

// U+AC00–U+D7A3(한글 음절) — 번역 PR 들의 오라클과 같은 범위. 이스케이프 대신 코드값으로 만든다
// (편집 도구가 `\u` 이스케이프를 글자로 풀어 쓰는 함정이 있었다).
const HANGUL = new RegExp(`[${String.fromCharCode(0xac00)}-${String.fromCharCode(0xd7a3)}]`)
const MAX_SHOWN = 50

function fail(code, message) {
  console.error(`::error::${message}`)
  process.exit(code)
}

const args = process.argv.slice(2)
const opt = (name) => args.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3)
const positional = args.filter((a) => !a.startsWith('--'))
if (positional.length !== 1) fail(2, '사용: check-rendered-docs-hangul.mjs <산출물 디렉터리> [--ext=…] [--skip=…] [--min-files=N]')
const unknown = args.filter((a) => a.startsWith('--') && !/^--(ext|skip|min-files)=/.test(a))
if (unknown.length) fail(2, `모르는 옵션: ${unknown.join(' ')} — 오타면 필터가 조용히 꺼진다`)

const root = positional[0]
const exts = (opt('ext') ?? '').split(',').filter(Boolean)
const skips = (opt('skip') ?? '').split(',').filter(Boolean)
const minFilesRaw = opt('min-files') ?? '1'
if (!/^[1-9]\d*$/.test(minFilesRaw)) fail(2, `--min-files 는 1 이상의 정수다: ${minFilesRaw}`)
const minFiles = Number(minFilesRaw)

let isDir = false
try {
  isDir = statSync(root).isDirectory()
} catch {
  isDir = false
}
if (!isDir) fail(2, `산출물 디렉터리가 없다: ${root} — 문서를 만드는 단계가 돌았는가?`)

const files = []
const walk = (dir) => {
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, ent.name)
    const rel = relative(root, path).split(sep).join('/')
    if (skips.some((s) => rel.startsWith(s))) continue
    if (ent.isDirectory()) walk(path)
    else if (ent.isFile() && (exts.length === 0 || exts.some((e) => ent.name.endsWith(e)))) files.push([path, rel])
  }
}
walk(root)

// ⚠️ NUL 바이트가 있는 파일은 바이너리로 보고 건너뛴다(git 과 같은 판정) — 폰트를 UTF-8 로 읽으면 우연히 한글
// 범위의 글자가 나온다(실측: Dokka 의 `ui-kit/fonts/*.woff*` 가 167 줄의 거짓 한글). 건너뛴 수는 요약에 찍는다.
const hits = []
let text = 0
let binary = 0
for (const [path, rel] of files) {
  const buf = readFileSync(path)
  if (buf.includes(0)) {
    binary += 1
    continue
  }
  text += 1
  buf
    .toString('utf8')
    .split('\n')
    .forEach((line, i) => {
      if (HANGUL.test(line)) hits.push(`${rel}:${i + 1}: ${line.trim().slice(0, 160)}`)
    })
}

console.log(`rendered docs: ${text} 파일 · 한글 줄 ${hits.length} · 건너뛴 바이너리 ${binary} (${root})`)
if (text < minFiles) fail(2, `읽은 텍스트 파일 ${text} 개 < --min-files=${minFiles} — 산출물이 비었거나 필터가 틀렸다`)
if (hits.length) {
  for (const h of hits.slice(0, MAX_SHOWN)) console.error(`::error::그려지는 문서에 한글 — ${h}`)
  if (hits.length > MAX_SHOWN) console.error(`::error::… 외 ${hits.length - MAX_SHOWN} 줄`)
  process.exit(1)
}
