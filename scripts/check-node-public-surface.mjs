#!/usr/bin/env node
// Node SDK의 **방출된 공개 타입 표면**에 하위 라이브러리 타입이 올라오는지 본다(§4 은닉성).
//
// 왜 소스가 아니라 `dist/**/*.d.ts`인가: 소비자가 실제로 보는 것이 방출된 선언이다. 소스에
// `private constructor`를 써도 tsc가 무엇을 지우는지는 선언을 봐야 안다 — 실제로 이 가드를
// 만든 계기가 그것이다. `JwtValidator`의 public 생성자가 jose `JWTVerifyGetKey`를 받아
// `dist/jwt.d.ts`에 `from 'jose'`가 박혀 있었고, admin 리소스 5종은 `KcAdminClient`를 올리고
// 있었다. 소스만 봤다면 "타입은 `import type`이니 괜찮다"고 넘겼을 자리다.
//
// 문서화된 §4(b) 예외 둘만 통과시킨다 — admin representation 타입과 `raw()` 탈출구.
//
// ⚠️ **dist가 없으면 실패한다.** 파일을 하나도 못 찾고 초록으로 끝나는 것이 이 부류 가드의
// 전형적인 공허함이라, 검사한 파일 수를 세어 0이면 에러로 만든다.
import { readdirSync, statSync, readFileSync } from 'node:fs'
import { join, relative } from 'node:path'

const ROOT = process.argv[2] ?? '.'
const DIST = join(ROOT, 'node/dist')

// 공개 표면에 올라와서는 안 되는 하위 라이브러리.
const FOREIGN = [/from ['"]jose['"]/, /from ['"]@keycloak\/keycloak-admin-client['"]/, /from ['"]openid-client['"]/]
// 문서화된 예외: representation 타입 경로, 그리고 `raw()`가 돌려주는 하위 클라이언트.
const ALLOWED_IMPORT = /keycloak-admin-client\/lib\/defs\//
const RAW_ESCAPE = /\braw\(\)\s*:/

function walk(dir, out = []) {
  let ents
  try {
    ents = readdirSync(dir)
  } catch {
    return out
  }
  for (const e of ents) {
    const p = join(dir, e)
    if (statSync(p).isDirectory()) walk(p, out)
    else if (e.endsWith('.d.ts')) out.push(p)
  }
  return out
}

const files = walk(DIST)
const errors = []

if (files.length === 0) {
  errors.push(
    `${relative(ROOT, DIST) || DIST} 에 .d.ts 가 없다 — 이 가드는 방출된 선언을 보므로 ` +
      `\`npm run build\` 뒤에 돌려야 한다. 파일 0개로 통과시키면 검사가 공허해진다.`,
  )
}

for (const f of files) {
  const rel = relative(ROOT, f).replace(/\\/g, '/')
  const text = readFileSync(f, 'utf8')
  const hasRawEscape = RAW_ESCAPE.test(text)
  for (const line of text.split(/\r?\n/)) {
    if (!FOREIGN.some((re) => re.test(line))) continue
    if (ALLOWED_IMPORT.test(line)) continue // §4(b) — representation 타입
    if (hasRawEscape && /keycloak-admin-client/.test(line)) continue // §4(b) — raw() 탈출구
    errors.push(
      `${rel}: 공개 선언이 하위 라이브러리 타입을 노출한다 — ${line.trim()}\n` +
        `  §4(b) 예외는 둘뿐이다(admin representation · raw()). 생성자라면 \`private\` 이나 ` +
        `\`@internal\`(+ tsconfig \`stripInternal\`)로 선언에서 지운다.`,
    )
  }
}

for (const e of errors) console.error(`::error::${e}`)
console.log(`node public surface: ${files.length}개 .d.ts 검사, 누출 ${errors.length}건`)
process.exit(errors.length ? 1 : 0)
