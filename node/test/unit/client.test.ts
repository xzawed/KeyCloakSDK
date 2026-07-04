import { describe, it, expect, vi, beforeEach } from 'vitest'

// auth/admin은 네트워크 경계 — 목킹해 KeycloakClient의 조립/지연/정리 로직만 격리 검증한다.
const h = vi.hoisted(() => {
  const authClose = vi.fn().mockResolvedValue(undefined)
  const authInstance = { close: authClose }
  const AuthClientMock = vi.fn(() => authInstance)
  const adminClose = vi.fn().mockResolvedValue(undefined)
  const adminInstance = { close: adminClose }
  const adminCreate = vi.fn().mockResolvedValue(adminInstance)
  return { authInstance, authClose, AuthClientMock, adminInstance, adminClose, adminCreate }
})

vi.mock('../../src/auth.js', () => ({ AuthClient: h.AuthClientMock }))
vi.mock('../../src/admin/index.js', () => ({ AdminClient: { create: h.adminCreate } }))

import { KeycloakClient } from '../../src/client.js'
import { KeycloakConfigError } from '../../src/errors.js'

const input = {
  serverUrl: 'https://kc.example.com',
  realm: 'demo',
  clientId: 'app',
  clientSecret: 'sekret',
}

beforeEach(() => {
  vi.clearAllMocks()
  h.adminCreate.mockResolvedValue(h.adminInstance)
})

describe('KeycloakClient.create', () => {
  it('config를 검증(defineConfig)하고 auth를 즉시 조립한다', () => {
    const client = KeycloakClient.create(input)
    expect(client.auth).toBe(h.authInstance)
    expect(h.AuthClientMock).toHaveBeenCalledTimes(1)
  })

  it('필수값 누락 시 defineConfig 검증으로 실패한다', () => {
    expect(() => KeycloakClient.create({ serverUrl: '', realm: 'r', clientId: 'c' })).toThrowError(
      /serverUrl/,
    )
  })

  it('admin은 create 시점에 생성되지 않는다(지연)', () => {
    KeycloakClient.create(input)
    expect(h.adminCreate).not.toHaveBeenCalled()
  })
})

describe('admin() — 지연 생성 + 캐시', () => {
  it('최초 호출 시 AdminClient.create로 생성한다', async () => {
    const client = KeycloakClient.create(input)
    const admin = await client.admin()
    expect(admin).toBe(h.adminInstance)
    expect(h.adminCreate).toHaveBeenCalledTimes(1)
  })

  it('두 번째 호출은 캐시된 인스턴스를 재사용한다(재생성 없음)', async () => {
    const client = KeycloakClient.create(input)
    const a = await client.admin()
    const b = await client.admin()
    expect(a).toBe(b)
    expect(h.adminCreate).toHaveBeenCalledTimes(1)
  })

  it('clientSecret이 없으면 KeycloakConfigError(네트워크 접근 없음)', async () => {
    const client = KeycloakClient.create({ serverUrl: 'https://kc', realm: 'r', clientId: 'c' })
    await expect(client.admin()).rejects.toBeInstanceOf(KeycloakConfigError)
    expect(h.adminCreate).not.toHaveBeenCalled()
  })

  it('생성 실패는 캐시하지 않는다(재시도 가능)', async () => {
    const client = KeycloakClient.create(input)
    h.adminCreate.mockRejectedValueOnce(new Error('network down'))
    await expect(client.admin()).rejects.toThrow('network down')
    h.adminCreate.mockResolvedValue(h.adminInstance)
    await expect(client.admin()).resolves.toBe(h.adminInstance)
    expect(h.adminCreate).toHaveBeenCalledTimes(2)
  })
})

describe('close / asyncDispose', () => {
  it('admin 미생성 시 auth만 정리한다(admin 정리 스킵)', async () => {
    const client = KeycloakClient.create(input)
    await client.close()
    expect(h.authClose).toHaveBeenCalledTimes(1)
    expect(h.adminClose).not.toHaveBeenCalled()
  })

  it('admin 생성 후 close는 admin+auth를 모두 정리한다', async () => {
    const client = KeycloakClient.create(input)
    await client.admin()
    await client.close()
    expect(h.adminClose).toHaveBeenCalledTimes(1)
    expect(h.authClose).toHaveBeenCalledTimes(1)
  })

  it('Symbol.asyncDispose는 close에 위임한다(await using 지원)', async () => {
    const client = KeycloakClient.create(input)
    await client.admin()
    await client[Symbol.asyncDispose]()
    expect(h.adminClose).toHaveBeenCalledTimes(1)
    expect(h.authClose).toHaveBeenCalledTimes(1)
  })
})
