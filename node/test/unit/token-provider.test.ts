import { describe, it, expect, vi } from 'vitest'
import { ClientCredentialsTokenProvider } from '../../src/token-provider.js'
import { TokenSet } from '../../src/tokens.js'

describe('ClientCredentialsTokenProvider', () => {
  it('만료 전에는 캐시 재사용(1회만 발급)', async () => {
    const source = {
      clientCredentialsToken: vi.fn().mockResolvedValue(new TokenSet('t1', 'Bearer', 300)),
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
        return new TokenSet('t', 'Bearer', 300)
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
        .mockResolvedValueOnce(new TokenSet('t1', 'Bearer', 0))
        .mockResolvedValueOnce(new TokenSet('t2', 'Bearer', 300)),
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
        .mockResolvedValueOnce(new TokenSet('t', 'Bearer', 300)),
    }
    const p = new ClientCredentialsTokenProvider(source)
    await expect(p.getAccessToken()).rejects.toThrow('boom')
    expect(await p.getAccessToken()).toBe('t')
  })
})
