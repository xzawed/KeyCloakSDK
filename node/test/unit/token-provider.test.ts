import { describe, it, expect, vi } from 'vitest'
import { ClientCredentialsTokenProvider } from '../../src/token-provider.js'
import { TokenSet } from '../../src/tokens.js'
import { defineConfig } from '../../src/config.js'

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

  // ⚠️ **생성자 기본값이 `config.clockSkewSeconds` 와 같은지 아무도 안 봤다.** 교차언어 가드의
  // 코드 축은 언어당 파일 하나만 읽고 node 는 `config.ts` 라, 이 자리의 `= 30` 은 어느 축에도
  // 안 걸린다. 위 테스트들도 못 잡는다 — 인자를 생략하는 것들은 `expiresIn: 300` 을 쓰므로
  // 기본값이 0·10·60 이어도 전부 통과한다(실측 2026-09-09).
  //
  // ⚠️ **여기에 `30` 을 다시 적지 않는다** — `defineConfig` 로 값을 **파생**한다. 테스트에
  // 상수를 또 적으면 두 번째 정의 자리를 한 층 위에 만드는 것이다.
  it('생성자 기본 skew 는 config.clockSkewSeconds 와 같다', async () => {
    const skew = defineConfig({
      serverUrl: 'https://kc.example',
      realm: 'r',
      clientId: 'c',
    }).clockSkewSeconds

    // 유효기간이 skew 와 정확히 같으면 캐시 수명이 0이므로 두 번째 호출은 재발급이어야 한다.
    // 기본값이 **작아지면** 캐시가 남아 1회로 끝나 여기서 깨진다.
    const atSkew = {
      clientCredentialsToken: vi
        .fn()
        .mockResolvedValueOnce(tokenSet('a1', skew))
        .mockResolvedValueOnce(tokenSet('a2', skew)),
    }
    const pa = new ClientCredentialsTokenProvider(atSkew)
    expect(await pa.getAccessToken()).toBe('a1')
    expect(await pa.getAccessToken()).toBe('a2')
    expect(atSkew.clientCredentialsToken).toHaveBeenCalledTimes(2)

    // ⚠️ 여기서 `skew + 60` 같은 여유값을 쓰면 **증가 방향을 못 잡는다** — 기본값이 60 이어도
    // 수명이 30초 남아 캐시되기 때문이다(실측: 그렇게 썼더니 30→60 변이가 SILENT 였다).
    // `skew + 1` 이면 수명이 정확히 1초라, 기본값이 1이라도 커지는 순간 0이 되어 재발급한다.
    const beyond = {
      clientCredentialsToken: vi.fn().mockResolvedValue(tokenSet('b1', skew + 1)),
    }
    const pb = new ClientCredentialsTokenProvider(beyond)
    expect(await pb.getAccessToken()).toBe('b1')
    expect(await pb.getAccessToken()).toBe('b1')
    expect(beyond.clientCredentialsToken).toHaveBeenCalledTimes(1)
  })
})
