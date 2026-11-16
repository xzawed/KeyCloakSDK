// 자가테스트 전용 사전 적재 — 가드를 **CI 와 같은 argv** 로 돌리면서 바깥(gh · 네트워크 · 시계)만 픽스처로 바꾼다
// (등록부 selftests-miss-the-real-callsite). 시험용 플래그(`--alerts` · `--runs` · `--fixtures` · `--base` · `--gh`)를 argv 에
// 얹으면 그 가드는 기본 경로(기본 루트 · 기본 URL · gh 호출 인자 · 시계)를 타지 않는다 — 그 길은 일정 잡만 탔다.
//
// 쓰는 법: `. scripts/test/net-stub.sh` 가 주는 NET_STUB_IMPORT 를 NODE_OPTIONS 에 넣고 아래 환경 변수를 준다. 가드 코드는
// 그대로다(이음매를 가드에 두지 않는다). STUB_* 가 없으면 아무것도 바꾸지 않는다 — 가드가 띄우는 node 자식에도 이어진다.
//  · STUB_GH=<.mjs>    child_process.spawnSync('gh', args, opts) 를 `node <.mjs> …args` 로 돌린다. ESM 이름 가져오기
//                      (`import { spawnSync } from 'node:child_process'`)까지 바꾸려고 module.syncBuiltinESMExports 를 부른다.
//  · STUB_FETCH=<dir>  globalThis.fetch(url) 가 `<dir>/<host>/<경로(디코딩)>` 파일로 200, 없으면 404 로 답한다(쿼리는 본다 않는다 —
//                      check-registry-truth 의 `--fixtures` 와 같은 배치).
//  · STUB_NOW=<unix 초> Date.now() 를 그 시각으로 고정한다.
//  · STUB_LOG=<파일>   가로챈 것을 한 줄씩 적는다 — `gh <인자>` · `fetch <url>`.
import cp from 'node:child_process'
import { appendFileSync, existsSync, readFileSync, statSync } from 'node:fs'
import { syncBuiltinESMExports } from 'node:module'
import { join } from 'node:path'

const log = (line) => {
  if (process.env.STUB_LOG) appendFileSync(process.env.STUB_LOG, `${line}\n`)
}
if (process.env.STUB_GH) {
  const orig = cp.spawnSync
  cp.spawnSync = (cmd, args = [], opts) => {
    if (cmd !== 'gh') return orig(cmd, args, opts)
    log(`gh ${args.join(' ')}`)
    return orig(process.execPath, [process.env.STUB_GH, ...args], opts)
  }
  syncBuiltinESMExports()
}
if (process.env.STUB_FETCH) {
  globalThis.fetch = async (input) => {
    const u = new URL(typeof input === 'string' ? input : input.url)
    log(`fetch ${u.href}`)
    const p = join(process.env.STUB_FETCH, u.host, decodeURIComponent(u.pathname))
    // `<경로>.status` 가 있으면 그 상태로 답한다(503 같은 판정 불가 사례 — check-registry-truth 의 `--fixtures` 와 같은 관용).
    if (existsSync(`${p}.status`)) return new Response('', { status: Number(readFileSync(`${p}.status`, 'utf8').trim()) })
    if (existsSync(p) && statSync(p).isFile()) return new Response(readFileSync(p), { status: 200 })
    return new Response('not found', { status: 404 })
  }
}
if (process.env.STUB_NOW) {
  const t = Number(process.env.STUB_NOW) * 1000
  Date.now = () => t
}
