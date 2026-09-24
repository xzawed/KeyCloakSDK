#!/usr/bin/env node
// 게시 SSOT(`df_published_version`)를 **살아 있는 레지스트리**와 대조한다 — 아홉 언어.
//
// 채우는 칸: 게시 버전 문자열은 문서와만 대조됐고(`check-docs.mjs`·`test-deploy-facts.sh`)
// 레지스트리와는 한 번도 대조되지 않았다(`registry-truth-check`). 「이 버전이 라이브인가」를
// 답하는 도구도 없었다(`post-publish-version-verify` — readiness 는 좌표 단위다). 한 질문의 두
// 절반이라 한 도구로 닫는다.
//
// ⚠️ **SSOT 는 레지스트리를 정당하게 앞선다** — 런북 §4 1 단계가 태그 **전** 커밋에서 올린다.
// 그래서 「SSOT 버전이 없다」는 곧바로 실패가 아니다. 유예 안이면 PENDING 이고, 유예의 시계는
// 그 버전의 **태그 시각**(없으면 SSOT 를 그 값으로 바꾼 커밋 시각)이다. Maven 은 사람이 Portal
// 을 눌러야 게시되므로 유예가 길다(실측 2026-09-23→24: 태그 뒤 하루 넘어 클릭, 클릭 뒤 repo1
// 첫 404 → 약 10 분 뒤 200).
// ⚠️ **Maven 은 maven-metadata.xml 로 「있다」를 판정하지 않는다** — 같은 날 jar 가 200 인데
// metadata 는 여전히 latest=1.0.0 이었다(실측). 있음 = 정확한 pom 이 200. metadata 는 「더 새
// 것이 있는가」의 **후보 목록**으로만 쓰고, 후보도 pom 200 으로 확인한다.
//
// 판정(언어별):
//   LIVE            SSOT 버전이 있다(yank 제외)                          → 0
//   REGISTRY_AHEAD  SSOT 보다 새 **정식** 버전이 있다 — SSOT·문서가 낡았다  → 1
//   PENDING         없다 · 시계가 유예 안                                 → 0 (출력은 한다)
//   MISSING         없다 · 태그가 유예를 넘었다                            → 1
//   UNTAGGED        없다 · 태그도 없고 SSOT 커밋이 유예를 넘었다            → 1
//   INCONCLUSIVE    429·5xx·타임아웃·깨진 본문 · metadata 와 pom 불일치     → 2
// 종료코드: 1 이 하나라도 있으면 1, 아니면 INCONCLUSIVE 가 있으면 2, 아니면 0 — **판정 불가를
// 통과로 읽지 않는다.**
//
// 사용:
//   node scripts/check-registry-truth.mjs [--root=<저장소>] [--fixtures=<디렉터리>] [--now=<epoch초>] [--lang=a,b]
//   --fixtures 가 있으면 네트워크를 쓰지 않는다: URL `https://<host>/<path>` 를
//   `<fixtures>/<host>/<path>` 로 읽고, 파일이 없으면 404, `<같은 경로>.status` 가 있으면 그 코드다.

import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { execFileSync } from 'node:child_process'

const argv = process.argv.slice(2)
const opt = (name, dflt) => {
  const hit = argv.find((a) => a.startsWith(`${name}=`))
  return hit === undefined ? dflt : hit.slice(name.length + 1)
}
const ROOT = opt('--root', '.')
const FIX = opt('--fixtures', '')
const NOW = Number(opt('--now', String(Math.floor(Date.now() / 1000))))
const ONLY = opt('--lang', '')
const HOUR = 3600
const GRACE_H = { java: 72, kotlin: 72 } // 나머지 24 — Maven 만 사람 클릭이 게시 경로에 있다
const graceOf = (lang) => (GRACE_H[lang] ?? 24) * HOUR
const TIMEOUT_MS = 15000
const RETRIES = 2

// ── SSOT·git ─────────────────────────────────────────────────────────────────
const facts = (fn, lang = '') =>
  execFileSync('sh', ['-c', `. scripts/lib/deploy-facts.sh && ${fn} "$1"`, 'sh', lang], {
    cwd: ROOT,
    encoding: 'utf8',
  }).trim()
const git = (...args) => {
  try {
    return execFileSync('git', ['-C', ROOT, ...args], { encoding: 'utf8' }).trim()
  } catch {
    return ''
  }
}
const tagTime = (tag) => {
  const t = git('for-each-ref', `refs/tags/${tag}`, '--format=%(creatordate:unix)')
  return t ? Number(t.split('\n')[0]) : null
}
// SSOT 가 그 값으로 바뀐 커밋 — 태그가 아직 없을 때의 시계.
// git -G 는 ERE 다 — 값의 메타문자를 **전부** 이스케이프한다(`.` 만 막으면 `+`·`(` 가 새다).
const escapeRe = (s) => s.replace(/[\\^$.*+?()[\]{}|]/g, '\\$&')
const ssotTime = (lang, ver) => {
  const t = git('log', '-1', '--format=%ct', '-G', `${escapeRe(lang)}\\) echo "${escapeRe(ver)}"`, '--', 'scripts/lib/deploy-facts.sh')
  return t ? Number(t) : null
}

// ── 버전 정규화 — 아홉 생태계의 프리릴리스 표기를 semver 라이브러리 없이 ────────────
// 정식만 [major, minor, patch, revision] 로 돌려주고, 프리릴리스·해석 불가는 null.
// 0.1.0-rc.1 · 0.1.0rc1 · 0.1.0.rc1 · 0.1.0-RC1 · 1.0.0-SNAPSHOT · v1.0.0 · 1.0.0.0 · 1.0.0+build
export function stableTuple(raw) {
  let v = String(raw).trim().replace(/^v/i, '').replace(/\+.*$/, '')
  const m = /^(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?(.*)$/.exec(v)
  if (!m) return null
  const tail = m[5].toLowerCase()
  if (tail !== '' && !/^[.-]?(final|ga|release)$/.test(tail)) return null
  return [Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4] ?? 0)]
}
const cmp = (a, b) => {
  for (let i = 0; i < 4; i++) if (a[i] !== b[i]) return a[i] - b[i]
  return 0
}

// ── 전송 ─────────────────────────────────────────────────────────────────────
// { status, body } — 네트워크 오류는 status 0.
async function get(url, headers = {}) {
  if (FIX) {
    const u = new URL(url)
    const p = join(FIX, u.host, decodeURIComponent(u.pathname))
    if (existsSync(`${p}.status`)) return { status: Number(readFileSync(`${p}.status`, 'utf8').trim()), body: '' }
    return existsSync(p) ? { status: 200, body: readFileSync(p, 'utf8') } : { status: 404, body: '' }
  }
  let last = { status: 0, body: '' }
  for (let i = 0; i <= RETRIES; i++) {
    try {
      const r = await fetch(url, {
        headers: { 'User-Agent': 'KeyCloakSDK registry-truth (github.com/xzawed/KeyCloakSDK)', ...headers },
        signal: AbortSignal.timeout(TIMEOUT_MS),
      })
      last = { status: r.status, body: await r.text() }
      if (r.status < 500 && r.status !== 429) return last
    } catch {
      last = { status: 0, body: '' }
    }
    await new Promise((res) => setTimeout(res, 1000 * (i + 1)))
  }
  return last
}
class Inconclusive extends Error {}
// 404 는 「그 좌표에 아무것도 없다」는 **답**이다 — 판정 불가가 아니라 빈 목록으로 유예·MISSING
// 판정을 탄다. 판정 불가는 답을 못 받은 것(429·5xx·타임아웃·깨진 본문)뿐이다.
const NOT_FOUND = Symbol('404')
const json = (r, url) => {
  if (r.status === 404 || r.status === 410) return NOT_FOUND
  if (r.status !== 200) throw new Inconclusive(`${url} → ${r.status || 'network error'}`)
  try {
    return JSON.parse(r.body)
  } catch {
    throw new Inconclusive(`${url} → 본문이 JSON 이 아니다`)
  }
}

// ── 레지스트리별 어댑터: 좌표 → { versions: [문자열] (yank 제외), exact?: bool } ──────
// 좌표는 `df_coordinate` 가 소유한다. 여기 있는 것은 레지스트리의 **URL 문법**뿐이다.
const goEscape = (p) => p.replace(/[A-Z]/g, (c) => `!${c.toLowerCase()}`)
// 각 어댑터는 (본문) → 버전 목록. 404 는 여기 오기 전에 빈 목록이 된다.
const fetchList = async (url, pick) => {
  const j = json(await get(url), url)
  return j === NOT_FOUND ? [] : pick(j)
}
const ADAPTERS = {
  python: (c) =>
    fetchList(`https://pypi.org/pypi/${c}/json`, (j) =>
      Object.entries(j.releases ?? {})
        .filter(([, files]) => files.length === 0 || files.some((f) => !f.yanked))
        .map(([v]) => v),
    ),
  node: (c) => fetchList(`https://registry.npmjs.org/${c.replaceAll('/', '%2f')}`, (j) => Object.keys(j.versions ?? {})),
  dotnet: (c) =>
    fetchList(`https://api.nuget.org/v3-flatcontainer/${c.toLowerCase()}/index.json`, (j) => j.versions ?? []),
  rust: (c) =>
    fetchList(`https://crates.io/api/v1/crates/${c}`, (j) =>
      (j.versions ?? []).filter((v) => !v.yanked).map((v) => v.num),
    ),
  ruby: (c) => fetchList(`https://rubygems.org/api/v1/versions/${c}.json`, (j) => (j ?? []).map((v) => v.number)),
  php: (c) =>
    fetchList(`https://repo.packagist.org/p2/${c}.json`, (j) => (j.packages?.[c] ?? []).map((v) => v.version)),
  go: async (c) => {
    const url = `https://proxy.golang.org/${goEscape(c)}/@v/list`
    const r = await get(url)
    if (r.status === 404 || r.status === 410) return []
    if (r.status !== 200) throw new Inconclusive(`${url} → ${r.status || 'network error'}`)
    return r.body.split('\n').map((s) => s.trim()).filter(Boolean)
  },
}
const MAVEN = 'https://repo1.maven.org/maven2'
async function maven(coord, ssot) {
  const [g, a] = coord.split(':')
  const base = `${MAVEN}/${g.replace(/\./g, '/')}/${a}`
  const pom = async (v) => {
    const r = await get(`${base}/${v}/${a}-${v}.pom`)
    if (r.status === 200) return true
    if (r.status === 404) return false
    throw new Inconclusive(`${base}/${v} pom → ${r.status || 'network error'}`)
  }
  const meta = await get(`${base}/maven-metadata.xml`)
  if (meta.status !== 200 && meta.status !== 404) throw new Inconclusive(`maven-metadata.xml → ${meta.status || 'network error'}`)
  const listed = [...meta.body.matchAll(/<version>([^<]+)<\/version>/g)].map((m) => m[1])
  // metadata 는 후보일 뿐 — 더 새 정식 후보는 pom 으로 확인하고, 불일치는 판정 불가다.
  const s = stableTuple(ssot)
  const newer = []
  for (const v of listed) {
    const t = stableTuple(v)
    if (!t || !s || cmp(t, s) <= 0) continue
    if (!(await pom(v))) throw new Inconclusive(`metadata 는 ${v} 를 싣는데 pom 이 404 다`)
    newer.push(v)
  }
  return { versions: [...newer, ...((await pom(ssot)) ? [ssot] : [])] }
}

async function versionsFor(lang, coord, ssot) {
  if (lang === 'java' || lang === 'kotlin') return (await maven(coord, ssot)).versions
  if (!ADAPTERS[lang]) throw new Inconclusive(`${lang} 어댑터가 없다 — 열 번째 언어라면 여기 추가`)
  return ADAPTERS[lang](coord)
}

// ── 판정 ─────────────────────────────────────────────────────────────────────
export function classify({ lang, ssot, versions, tagAt, ssotAt, now }) {
  const s = stableTuple(ssot)
  const ahead = versions.filter((v) => {
    const t = stableTuple(v)
    return t && s && cmp(t, s) > 0
  })
  if (ahead.length) return { verdict: 'REGISTRY_AHEAD', bit: 1, why: `레지스트리에 ${ahead.join(', ')} — SSOT ${ssot} 가 낡았다` }
  if (versions.some((v) => (stableTuple(v) && s ? cmp(stableTuple(v), s) === 0 : v === ssot))) {
    return { verdict: 'LIVE', bit: 0, why: `${ssot} 게시됨` }
  }
  const grace = graceOf(lang)
  if (tagAt != null) {
    const age = now - tagAt
    return age < grace
      ? { verdict: 'PENDING', bit: 0, why: `${ssot} 아직 없음 — 태그 ${Math.floor(age / HOUR)}h 전(유예 ${grace / HOUR}h)` }
      : { verdict: 'MISSING', bit: 1, why: `${ssot} 태그가 ${Math.floor(age / HOUR)}h 전인데 레지스트리에 없다(유예 ${grace / HOUR}h)` }
  }
  if (ssotAt != null && now - ssotAt < grace) {
    return { verdict: 'PENDING', bit: 0, why: `${ssot} 태그 전 — SSOT 가 ${Math.floor((now - ssotAt) / HOUR)}h 전에 올라갔다` }
  }
  return { verdict: 'UNTAGGED', bit: 1, why: `${ssot} 는 태그도 레지스트리에도 없다 — SSOT 가 거짓이다` }
}

async function main() {
  const langs = facts('printf "%s" "$DEPLOY_LANGS" #').split(/\s+/).filter(Boolean)
  const want = ONLY ? ONLY.split(',') : langs
  if (want.length === 0) {
    console.error('::error::언어 목록이 비었다 — 0 개를 훑고 통과하지 않는다')
    process.exit(1)
  }
  let worst = 0
  let inconclusive = 0
  for (const lang of want) {
    const ssot = facts('df_published_version', lang)
    const coord = facts('df_coordinate', lang)
    if (!coord) {
      console.error(`::error::${lang}: df_coordinate 가 비었다 — 어댑터 대상이 없다`)
      worst = 1
      continue
    }
    if (!ssot) {
      console.log(`skip ${lang} — 미게시(df_published_version 빈 값)`)
      continue
    }
    const tag = facts('df_tag', lang).replace('%s', ssot)
    let r
    try {
      const versions = await versionsFor(lang, coord, ssot)
      r = classify({ lang, ssot, versions, tagAt: tagTime(tag), ssotAt: ssotTime(lang, ssot), now: NOW })
    } catch (e) {
      if (!(e instanceof Inconclusive)) throw e
      r = { verdict: 'INCONCLUSIVE', bit: 2, why: e.message }
    }
    const line = `${r.verdict.padEnd(14)} ${lang.padEnd(7)} ${coord} — ${r.why}`
    if (r.bit === 1) console.error(`::error::${line}`)
    else if (r.bit === 2) console.error(`::warning::${line}`)
    else console.log(line)
    if (r.bit === 1) worst = 1
    if (r.bit === 2) inconclusive++
  }
  process.exit(worst === 1 ? 1 : inconclusive ? 2 : 0)
}

// 자가테스트가 import 로 순수 함수만 쓸 수 있게 — 직접 실행일 때만 main.
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/\\/g, '/').split('/').pop())) {
  await main()
}
