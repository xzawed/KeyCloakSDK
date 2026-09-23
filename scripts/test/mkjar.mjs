#!/usr/bin/env node
// 자가테스트용 **jar 픽스처 빌더**. 의존성 없이 zip 을 쓴다.
//
// 왜 필요한가: `check-published-jvm-floor.mjs` 가 읽는 것은 jar 안 클래스파일의 6~7 바이트다.
// 그것을 시험하려면 진짜 zip 이 있어야 하는데, 이 저장소의 `.gitignore` 는 `*.jar` 를 막고
// 있고(막지 않더라도 바이너리 픽스처를 커밋하는 것은 리뷰가 불가능하다), 그래서 **런타임에
// 만든다.** 헤더만 있으면 되는 이유는 가드가 읽는 것이 major 두 바이트뿐이기 때문이다.
//
// ⚠️ **STORED 와 DEFLATE 를 한 jar 에 섞는다** — 리더의 두 경로를 한 픽스처가 모두 지나간다.
// 한쪽만 넣으면 나머지 경로가 시험되지 않은 채 남는다(실제 jar 는 대부분 DEFLATE 다).
//
// 사용: node scripts/test/mkjar.mjs <출력.jar> <major>[:<개수>] [--mr=<major>] [--empty]
//   예: node scripts/test/mkjar.mjs out.jar 61:3 --mr=65
//       → io/x/C0..C2.class(major 61) + META-INF/versions/21/io/x/M.class(major 65)

import { writeFileSync } from 'node:fs'
import { deflateRawSync } from 'node:zlib'

const argv = process.argv.slice(2)
const out = argv[0]
const spec = argv[1] ?? '61:1'
const mrArg = argv.find((a) => a.startsWith('--mr='))
const EMPTY = argv.includes('--empty')
// ⚠️ `--trap-comment` 는 **아카이브 주석 안에 EOCD 서명을 심는다.** 뒤에서부터 서명만 찾는
// 리더는 그 가짜를 먼저 만나 엉뚱한 곳을 중앙 디렉터리로 읽는다(실측으로 예외가 났다).
// 진짜 EOCD 는 「주석 길이 == 남은 바이트」를 만족하므로 그 조건이 가짜를 걸러야 한다.
const TRAP = argv.includes('--trap-comment')
// ⚠️ `--preview` 는 minor 를 0xFFFF 로 쓴다 — major 는 하한 안인데 **JDK 18+ 과
// `--enable-preview` 없는 하한 JDK 양쪽에서 로드되지 않는** 클래스다. major 만 보면 못 본다.
const PREVIEW = argv.includes('--preview')
// ⚠️ `--bad-magic` 은 `.class` 이름인데 CAFEBABE 가 아닌 항목을 넣는다 — zip 오프셋 해석이
// 어긋났을 때 **임의 바이트에서 major 를 지어내는** 상황을 흉내 낸다.
const BADMAGIC = argv.includes('--bad-magic')
if (!out) {
  console.error('usage: node scripts/test/mkjar.mjs <출력.jar> <major>[:<개수>] [--mr=<major>] [--empty]')
  process.exit(1)
}

// CRC-32 — zip 이 요구한다. `zlib.crc32` 는 Node 버전을 타므로 직접 센다(10줄이면 된다).
const TABLE = (() => {
  const t = new Int32Array(256)
  for (let n = 0; n < 256; n++) {
    let c = n
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    t[n] = c
  }
  return t
})()
const crc32 = (buf) => {
  let c = -1
  for (const b of buf) c = TABLE[(c ^ b) & 0xff] ^ (c >>> 8)
  return (c ^ -1) >>> 0
}

// 최소 클래스파일: CAFEBABE(4) + minor(2) + major(2). 가드가 읽는 것이 정확히 그 두 바이트다.
const cls = (major, minor = 0) => {
  const b = Buffer.alloc(10)
  b.writeUInt32BE(0xcafebabe, 0)
  b.writeUInt16BE(minor, 4)
  b.writeUInt16BE(major, 6)
  return b
}

const entries = []
if (!EMPTY) {
  const [majStr, cntStr] = spec.split(':')
  const major = Number(majStr)
  const count = Number(cntStr ?? '1')
  for (let i = 0; i < count; i++) entries.push({ name: `io/x/C${i}.class`, data: cls(major, PREVIEW ? 0xffff : 0) })
  if (mrArg) entries.push({ name: `META-INF/versions/21/io/x/M.class`, data: cls(Number(mrArg.slice('--mr='.length))) })
  if (BADMAGIC) entries.push({ name: 'io/x/NotAClass.class', data: Buffer.from('this is not a class file') })
}
// 클래스가 아닌 항목도 하나 넣는다 — 리더가 확장자로 거른다는 것을 픽스처가 시험한다.
entries.push({ name: 'META-INF/MANIFEST.MF', data: Buffer.from('Manifest-Version: 1.0\n') })

const locals = []
const centrals = []
let offset = 0
entries.forEach((e, i) => {
  // 항목마다 방식을 번갈아 — 한 jar 로 STORED·DEFLATE 두 경로를 모두 지나간다.
  const method = i % 2 === 0 ? 8 : 0
  const body = method === 8 ? deflateRawSync(e.data) : e.data
  const name = Buffer.from(e.name, 'utf8')
  const crc = crc32(e.data)

  const lh = Buffer.alloc(30)
  lh.writeUInt32LE(0x04034b50, 0)
  lh.writeUInt16LE(20, 4)
  lh.writeUInt16LE(0, 6)
  lh.writeUInt16LE(method, 8)
  lh.writeUInt16LE(0, 10)
  lh.writeUInt16LE(0, 12)
  lh.writeUInt32LE(crc, 14)
  lh.writeUInt32LE(body.length, 18)
  lh.writeUInt32LE(e.data.length, 22)
  lh.writeUInt16LE(name.length, 26)
  lh.writeUInt16LE(0, 28)
  locals.push(lh, name, body)

  const cd = Buffer.alloc(46)
  cd.writeUInt32LE(0x02014b50, 0)
  cd.writeUInt16LE(20, 4)
  cd.writeUInt16LE(20, 6)
  cd.writeUInt16LE(0, 8)
  cd.writeUInt16LE(method, 10)
  cd.writeUInt16LE(0, 12)
  cd.writeUInt16LE(0, 14)
  cd.writeUInt32LE(crc, 16)
  cd.writeUInt32LE(body.length, 20)
  cd.writeUInt32LE(e.data.length, 24)
  cd.writeUInt16LE(name.length, 28)
  cd.writeUInt16LE(0, 30)
  cd.writeUInt16LE(0, 32)
  cd.writeUInt16LE(0, 34)
  cd.writeUInt16LE(0, 36)
  cd.writeUInt32LE(0, 38)
  cd.writeUInt32LE(offset, 42)
  centrals.push(cd, name)

  offset += lh.length + name.length + body.length
})

const cdBuf = Buffer.concat(centrals)
const eocd = Buffer.alloc(22)
eocd.writeUInt32LE(0x06054b50, 0)
eocd.writeUInt16LE(0, 4)
eocd.writeUInt16LE(0, 6)
eocd.writeUInt16LE(entries.length, 8)
eocd.writeUInt16LE(entries.length, 10)
eocd.writeUInt32LE(cdBuf.length, 12)
eocd.writeUInt32LE(offset, 16)
let comment = Buffer.alloc(0)
if (TRAP) {
  comment = Buffer.alloc(40, 0x41)
  Buffer.from([0x50, 0x4b, 0x05, 0x06]).copy(comment, 10) // 주석 안의 가짜 EOCD 서명
}
eocd.writeUInt16LE(comment.length, 20)

writeFileSync(out, Buffer.concat([...locals, cdBuf, eocd, comment]))
