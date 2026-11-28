// 물결 시험 도우미 — scripts/test/test-changelog-fragments.sh 의 W 절이 compileWave · verifyWave 를 직접 잰다
// (release 가 생기기 전이고, release 도 쓰기 전에 이 두 함수를 부른다).
//
//   node scripts/test/changelog-wave-probe.mjs <root> <날짜> <lang=ver,…> <글 파일>
//       verifyWave(<root> 의 조각, 물결, 글) 의 오류를 한 줄씩 찍는다 — 있으면 rc 1, 없으면 rc 0
//   node scripts/test/changelog-wave-probe.mjs --compile <root> <날짜> <lang=ver,…>
//       compileWave 의 글을 stdout 에 그대로, updates 를 stderr 에 `updates: <JSON>` 한 줄로 — rc 0
//   node scripts/test/changelog-wave-probe.mjs --tree <root>
//       checkFragmentTree(<root>) 의 결과를 JSON 한 줄로 — rc 0. 던지면 `threw: <메시지>` + rc 2
//
// 인자 · 뿌리(DEPLOY_LANGS · 조각 문법) · 글 파일의 오류는 rc 2 다 — 판정(rc 1)과 섞지 않는다. 깨진 픽스처가
// 「verifyWave 가 거부했다」로 읽히면 W4 의 rc 1 단언이 공허해진다. 글 파일은 받은 바이트 그대로 대조한다(줄 끝을 바꾸지 않는다).
import { readFileSync } from 'node:fs'
import { readDeployLangs, readFragmentDir } from '../lib/changelog-fragments.mjs'
import { checkFragmentTree, compileWave, verifyWave, isWaveDate } from '../lib/changelog-wave.mjs'

const fail = (msg) => {
  console.error(`changelog-wave-probe: ${msg}\n사용: <root> <날짜> <lang=ver,…> <글 파일> | --compile <root> <날짜> <lang=ver,…>`)
  process.exit(2)
}
const argv = process.argv.slice(2)
if (argv[0] === '--tree') {
  // checkFragmentTree(<root>) 를 그대로 부른다 — 던지면 rc 2 + 메시지(「던지지 않는다」 단언이 이 rc 를 본다), 아니면 결과 JSON 한 줄 · rc 0.
  if (argv.length !== 2) fail(`--tree 는 <root> 하나를 받는다 — 인자 ${argv.length - 1}개`)
  try {
    console.log(JSON.stringify(checkFragmentTree(argv[1])))
  } catch (e) {
    console.error(`threw: ${e.message}`)
    process.exit(2)
  }
  process.exit(0)
}
const compile = argv[0] === '--compile'
const pos = compile ? argv.slice(1) : argv
if (pos.length !== (compile ? 3 : 4)) fail(`인자가 ${pos.length}개다`)
const [root, date, pairs, textFile] = pos
if (!isWaveDate(date)) fail(`날짜가 있는 날짜의 YYYY-MM-DD 가 아니다 — ${date}`)
let order
try {
  order = readDeployLangs(root)
} catch (e) {
  fail(e.message)
}
const versions = {}
for (const p of pairs.split(',')) {
  const m = /^([a-z]+)=(.+)$/.exec(p)
  if (!m || !order.includes(m[1]) || Object.hasOwn(versions, m[1])) fail(`<lang>=<ver> 가 아니거나 모르는 · 겹친 언어다 — ${p}`)
  versions[m[1]] = m[2]
}
const { fragments, errors } = readFragmentDir(root, order)
if (errors.length) fail(`뿌리의 조각이 깨졌다 — ${errors.join(' | ')}`)
const wave = { date, versions }
if (compile) {
  const { text, updates } = compileWave(fragments, wave, order)
  process.stdout.write(text)
  process.stderr.write(`updates: ${JSON.stringify(updates)}\n`)
} else {
  let text
  try {
    text = readFileSync(textFile, 'utf8')
  } catch (e) {
    fail(`글 파일을 못 읽었다 — ${textFile} (${e.code ?? e.message})`)
  }
  const found = verifyWave(fragments, wave, text, order)
  for (const line of found) console.error(line)
  if (!found.length) console.log('ok   verifyWave — 오류 없음')
  process.exitCode = found.length ? 1 : 0
}
