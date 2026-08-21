import { describe, it, expect, vi } from 'vitest'
import { ClientCredentialsTokenProvider } from '../../src/token-provider.js'
import { TokenSet } from '../../src/tokens.js'

// ⚠️ 4번째 인자 `expiresAt`을 빠뜨린 채로 오래 있었다 — 테스트가 타입검사를 안 받아서
// (tsconfig `include: ["src"]`) 아무도 못 봤고, vitest는 esbuild로 타입을 벗겨 실행하므로
// 통과했다. 프로덕션 규칙은 `tokenSetFromResponse`에 있다: expiresIn>0이면 issuedAt+expiresIn,
// 아니면 undefined. 헬퍼가 그 규칙을 따르므로 여기서 다시 갈리지 않는다.
const tokenSet = (accessToken: string, expiresIn: number): TokenSet =>
  new TokenSet(
    accessToken,
    'Bearer',
    expiresIn,
    expiresIn > 0 ? Math.floor(Date.now() / 1000) + expiresIn : undefined,
  )

describe('ClientCredentialsTokenProvider', () => {
  it('만료 전에는 캐시 재사용(1회만 발급)', async () => {
    const source = {
      clientCredentialsToken: vi.fn().mockResolvedValue(tokenSet('t1', 300)),
    }
    const p = new ClientCredentialsTokenProvider(source, 30)
    expect(await p.getAccessToken()).toBe('t1')
    expect(await p.getAccessToken()).toBe('t1')
    expect(source.clientCredentialsToken).toHaveBeenCalledTimes(1)
  })

  it('동시 호출은 single-flight로 1회만 발급', async () => {
    const source = {
      clientCredentialsToken: vi.fn().mockImplementation(async () => {
        await new Promise((r) => setTimeout(r, 10))
        return tokenSet('t', 300)
      }),
    }
    const p = new ClientCredentialsTokenProvider(source)
    const [a, b] = await Promise.all([p.getAccessToken(), p.getAccessToken()])
    expect(a).toBe('t')
    expect(b).toBe('t')
    expect(source.clientCredentialsToken).toHaveBeenCalledTimes(1)
  })

  it('만료되면 재발급', async () => {
    const source = {
      clientCredentialsToken: vi
        .fn()
        .mockResolvedValueOnce(tokenSet('t1', 0))
        .mockResolvedValueOnce(tokenSet('t2', 300)),
    }
    const p = new ClientCredentialsTokenProvider(source, 0)
    expect(await p.getAccessToken()).toBe('t1')
    expect(await p.getAccessToken()).toBe('t2')
    expect(source.clientCredentialsToken).toHaveBeenCalledTimes(2)
  })

  it('발급 실패는 전파되고 이후 재시도 가능', async () => {
    const source = {
      clientCredentialsToken: vi
        .fn()
        .mockRejectedValueOnce(new Error('boom'))
        .mockResolvedValueOnce(tokenSet('t', 300)),
    }
    const p = new ClientCredentialsTokenProvider(source)
    await expect(p.getAccessToken()).rejects.toThrow('boom')
    expect(await p.getAccessToken()).toBe('t')
  })
})
