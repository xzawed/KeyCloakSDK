#!/usr/bin/env node
// CHANGELOG 원장 회전 — 루트가 상한(ROOT_MAX_BYTES)을 넘으면 가장 오래된 **날짜**의 절부터
// `changelog/<YYYY-MM>.md` 월별 보관본으로 옮긴다. 지우지 않고, 내용을 바꾸지 않는다(상대 링크만
// 한 단계 위를 가리키게 고친다). 루트가 상한 안이면 아무것도 하지 않는다 — 몇 번을 돌려도 같다.
//
// 사용: node scripts/changelog-rotate.mjs [--root=<디렉터리>] [--dry-run]
//
// ⚠️ **날짜 묶음 단위로만 옮긴다.** 한 날짜가 루트와 보관본에 갈라 살면 「그 물결」을 한 곳에서
// 읽을 수 없다. 그래서 최신 날짜 하나가 혼자 상한을 넘으면 그대로 둔다(검사 8d 도 그것을 허용한다).
// ⚠️ **쓰기 전에 두 가지를 확인하고, 하나라도 어긋나면 아무것도 쓰지 않는다**: 각 절의 링크 왕복
// (`fromVolume(toVolume(x)) === x`)과 보존(옮기기 전후 절 집합이 같다). 검사 8d 는 같은 보존을
// `main` 과 다시 대조한다 — 이 스크립트가 틀리게 옮겨도 PR 에서 막힌다.
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import {
  ROOT_FILE, VOLUME_DIR, VOLUME_RE, ROOT_MAX_BYTES, INDEX_PREFIX,
  bytes, parseLedgerFile, assertSplitIdentity, toVolume, fromVolume, volumeHead, volumePath, indexLine,
} from './lib/changelog-ledger.mjs'

const argv = process.argv.slice(2)
const opt = (name, dflt) => {
  const hit = argv.find((a) => a.startsWith(`${name}=`))
  return hit ? hit.slice(name.length + 1) : dflt
}
const ROOT = opt('--root', '.')
const DRY = argv.includes('--dry-run')
const die = (msg) => {
  console.error(`changelog-rotate: ${msg}`)
  process.exit(1)
}

// 검사 8d 와 같은 눈으로 읽는다 — 줄 끝은 LF 로 맞춘다(쓰는 것도 LF 다).
const readLF = (p) => readFileSync(p, 'utf8').replace(/\r\n/g, '\n')
const rootText = readLF(join(ROOT, ROOT_FILE))
assertSplitIdentity(rootText)
const root = parseLedgerFile(rootText)
if (root.unreleased.length !== 1) die(`${ROOT_FILE}: \`## [Unreleased]\` 가 ${root.unreleased.length}개다`)
if (root.unknown.length) die(`${ROOT_FILE}: 릴리스 절로 읽히지 않는 제목 — ${root.unknown.map((b) => b.heading).join(' | ')}`)
// 루트는 [Unreleased] 가 맨 앞이고 그 뒤가 전부 릴리스 절이어야 한다(아니면 렌더가 순서를 바꾼다).
if (root.order[0] !== root.unreleased[0]) die(`${ROOT_FILE}: \`## [Unreleased]\` 가 첫 절이 아니다`)

// 기존 보관본 — 형식이 다르면 손대지 않는다(검사 8d 가 이유를 말한다).
const volumes = new Map() // month → 블록 text[] (보관본 표기 그대로, 최신순)
const volDir = join(ROOT, VOLUME_DIR)
if (existsSync(volDir)) {
  for (const f of readdirSync(volDir)) {
    const rel = `${VOLUME_DIR}/${f}`
    const m = VOLUME_RE.exec(rel)
    if (!m) die(`${rel}: 월별 보관본(<YYYY-MM>.md)이 아니다`)
    const t = readLF(join(ROOT, rel))
    assertSplitIdentity(t)
    const v = parseLedgerFile(t)
    if (v.head !== volumeHead(m[1]) || v.unknown.length || v.unreleased.length) die(`${rel}: 보관본 형식이 아니다 — 먼저 check-docs 검사 8d 를 통과시켜라`)
    volumes.set(m[1], v.releases.map((b) => b.text))
  }
}

const before = bytes(rootText)
if (before <= ROOT_MAX_BYTES) {
  console.log(`ok   ${ROOT_FILE} ${before}B ≤ ${ROOT_MAX_BYTES}B — 옮길 것이 없다`)
  process.exit(0)
}

function renderRoot(releaseTexts, monthsDesc) {
  // 색인 줄은 머리의 끝([Unreleased] 바로 위)에 하나만 둔다. 다시 그려도 같은 바이트가 나온다.
  let head = root.head.split(/(?<=\n)/).filter((l) => !l.startsWith(INDEX_PREFIX)).join('')
  if (monthsDesc.length) head = head.replace(/\n*$/, '\n\n') + indexLine(monthsDesc) + '\n'
  return head + root.unreleased[0].text + releaseTexts.join('')
}

const keep = root.releases.slice() // 최신순
let moved = [] // 최신순
const monthsDesc = () => [...new Set([...volumes.keys(), ...moved.map((b) => b.month)])].sort().reverse()
let next = renderRoot(keep.map((b) => b.text), monthsDesc())
while (bytes(next) > ROOT_MAX_BYTES && new Set(keep.map((b) => b.date)).size > 1) {
  const oldest = keep[keep.length - 1].date
  const group = []
  while (keep.length && keep[keep.length - 1].date === oldest) group.unshift(keep.pop())
  moved = [...group, ...moved]
  next = renderRoot(keep.map((b) => b.text), monthsDesc())
}

// 확인 1 — 링크 왕복.
for (const b of moved) {
  if (fromVolume(toVolume(b.text)) !== b.text) die(`「${b.heading}」: 상대 링크를 왕복할 수 없다(이미 ../ 로 시작하는 링크가 있나?) — 아무것도 쓰지 않았다`)
}
// 새 보관본: 옮겨 오는 절(더 새것)이 기존 절 위에 온다.
const nextVolumes = new Map([...volumes].map(([m, list]) => [m, list.slice()]))
for (const m of [...new Set(moved.map((b) => b.month))]) {
  const incoming = moved.filter((b) => b.month === m).map((b) => toVolume(b.text))
  nextVolumes.set(m, [...incoming, ...(nextVolumes.get(m) ?? [])])
}
// 확인 2 — 보존: 루트 릴리스 절 + 보관본 절(정규화)의 다중집합이 전후로 같다.
const bag = (rootTexts, vols) => [...rootTexts, ...[...vols.values()].flat().map(fromVolume)].sort()
const was = bag(root.releases.map((b) => b.text), volumes)
const now = bag(keep.map((b) => b.text), nextVolumes)
if (was.length !== now.length || was.some((t, i) => t !== now[i])) die('보존 확인 실패 — 옮기기 전후의 절 집합이 다르다. 아무것도 쓰지 않았다')

const after = bytes(next)
const plan = [...new Set(moved.map((b) => b.date))]
console.log(`${DRY ? 'plan' : 'ok  '} ${ROOT_FILE} ${before}B → ${after}B (상한 ${ROOT_MAX_BYTES}B) — 날짜 ${plan.length}개 · 절 ${moved.length}개를 옮긴다: ${plan.join(' · ')}`)
for (const [m, list] of nextVolumes) {
  const text = volumeHead(m) + list.join('')
  console.log(`     ${volumePath(m)} — 절 ${list.length}개 · ${bytes(text)}B`)
}
if (after > ROOT_MAX_BYTES) console.log(`⚠️  최신 날짜 하나가 혼자 ${after}B 라 상한을 넘는다 — 날짜는 쪼개지 않는다(검사 8d 도 허용한다)`)
if (DRY) process.exit(0)

if (!existsSync(volDir)) mkdirSync(volDir)
for (const [m, list] of nextVolumes) writeFileSync(join(ROOT, volumePath(m)), volumeHead(m) + list.join(''))
writeFileSync(join(ROOT, ROOT_FILE), next)
