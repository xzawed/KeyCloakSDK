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

// ⚠️ **`raw()` 예외는 파일 단위였다** — 파일 어딘가에 `raw():` 가 있으면 그 파일의 모든
// admin-client 언급이 통과했다. 그러면 같은 파일에 **새 공개 멤버가 `KcAdminClient` 를
// 노출해도 조용히 통과한다**(§4(b) 는 예외를 `raw()` 탈출구 하나로 못박는다).
// 범위를 「그 import 로 들여온 **이름**이 `raw()` 선언 줄 밖에는 나타나지 않는다」로 좁힌다.
// 실측(2026-09-02): 이 예외를 쓰는 파일은 `node/dist/admin/index.d.ts` 하나이고 그 안에서
// `KcAdminClient` 는 import 줄과 `raw(): KcAdminClient;` 두 줄에만 나타난다 — 오탐 0.
const ADMIN_IMPORT_BINDINGS =
  /^\s*import\s+(?:type\s+)?(?:([A-Za-z_$][\w$]*)\s*,?\s*)?(?:\{([^}]*)\})?\s*from\s+['"]@keycloak\/keycloak-admin-client['"]/
// 주석 줄은 이름을 언급만 할 수 있으므로 사용처로 세지 않는다.
const COMMENT_LINE = /^\s*(\/\/|\/\*|\*)/

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
  const lines = text.split(/\r?\n/)
  const hasRawEscape = RAW_ESCAPE.test(text)

  // `raw()` 예외로 통과시킨 import 가 들여온 이름들.
  const rawBindings = new Set()

  for (const line of lines) {
    if (!FOREIGN.some((re) => re.test(line))) continue
    if (ALLOWED_IMPORT.test(line)) continue // §4(b) — representation 타입
    if (hasRawEscape && /keycloak-admin-client/.test(line)) {
      // §4(b) — raw() 탈출구. 이름을 기억해 두고 **사용처**를 아래에서 좁힌다.
      const m = ADMIN_IMPORT_BINDINGS.exec(line)
      if (m) {
        if (m[1]) rawBindings.add(m[1])
        for (const named of (m[2] ?? '').split(',')) {
          const id = named.trim().split(/\s+as\s+/).pop()?.trim()
          if (id) rawBindings.add(id)
        }
      }
      continue
    }
    errors.push(
      `${rel}: 공개 선언이 하위 라이브러리 타입을 노출한다 — ${line.trim()}\n` +
        `  §4(b) 예외는 둘뿐이다(admin representation · raw()). 생성자라면 \`private\` 이나 ` +
        `\`@internal\`(+ tsconfig \`stripInternal\`)로 선언에서 지운다.`,
    )
  }

  // ⚠️ 예외의 **범위**를 좁힌다 — import 를 통과시킨 것이 그 파일 전체를 통과시키는 것은 아니다.
  for (const binding of rawBindings) {
    const use = new RegExp(`\\b${binding.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`)
    for (const line of lines) {
      if (!use.test(line)) continue
      if (ADMIN_IMPORT_BINDINGS.test(line)) continue // import 줄 자체
      if (COMMENT_LINE.test(line)) continue
      if (RAW_ESCAPE.test(line)) continue // `raw(): KcAdminClient` — 유일하게 허용되는 사용처
      errors.push(
        `${rel}: \`raw()\` 예외로 들여온 \`${binding}\` 이 raw() 밖의 공개 선언에 쓰였다 — ${line.trim()}\n` +
          `  §4(b) 의 예외는 **탈출구 하나**다. 같은 파일이라는 이유로 넓어지지 않는다.`,
      )
    }
  }
}

for (const e of errors) console.error(`::error::${e}`)
console.log(`node public surface: ${files.length}개 .d.ts 검사, 누출 ${errors.length}건`)
process.exit(errors.length ? 1 : 0)
