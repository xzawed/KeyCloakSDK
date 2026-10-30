// Runtime messages are English. The doc comments that tools render were translated per language;
// strings that reach a consumer at runtime are the other half — a Korean message once reached
// `KeycloakTokenValidationError.message`. Comments are out of scope: they are not literals.
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import ts from 'typescript'
import { describe, expect, it } from 'vitest'

const SRC = fileURLToPath(new URL('../../src/', import.meta.url))
const HANGUL = new RegExp(`[${String.fromCharCode(0xac00)}-${String.fromCharCode(0xd7a3)}]`)

/** `file:line` of every string or template literal that contains Hangul — comments are not literals. */
function hangulLiterals(file: string, text: string): string[] {
  const sf = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true)
  const hits: string[] = []
  const walk = (node: ts.Node): void => {
    if (
      (ts.isStringLiteralLike(node) || ts.isTemplateLiteralToken(node)) &&
      HANGUL.test(node.text)
    ) {
      hits.push(`${file}:${sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1}`)
    }
    ts.forEachChild(node, walk)
  }
  walk(sf)
  return hits
}

function sources(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory()
      ? sources(join(dir, e.name))
      : e.name.endsWith('.ts')
        ? [join(dir, e.name)]
        : [],
  )
}

describe('runtime strings', () => {
  it('finds Hangul in string and template literals, not in comments (control)', () => {
    expect(hangulLiterals('a.ts', 'throw new Error(`실패: ${e}`)')).toEqual(['a.ts:1'])
    expect(hangulLiterals('b.ts', "const m = '실패'")).toEqual(['b.ts:1'])
    expect(hangulLiterals('c.ts', '// 실패\n/** 실패 */\nconst m = `ok ${x} 끝`')).toEqual([
      'c.ts:3',
    ])
    expect(hangulLiterals('d.ts', '// 실패\n/** 실패 */\nconst m = "ok"')).toEqual([])
  })

  it('has no Hangul in any string or template literal under src/', () => {
    const files = sources(SRC)
    expect(files.length).toBeGreaterThan(10) // an empty walk would pass vacuously
    expect(
      files.flatMap((f) => hangulLiterals(f.slice(SRC.length), readFileSync(f, 'utf8'))),
    ).toEqual([])
  })
})
