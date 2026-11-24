// Unit drive — never an empty code, realm or scope, no empty item for pick, no kind past 2, one load; never calls
// describe or logoutUrl.
import { expect, it } from 'vitest'
import { AuthClient, helper } from '../../src/auth_client.js'
import { Config } from '../../src/config.js'

it('drives the boundary', async () => {
  const c = AuthClient.from('demo')
  expect(c.exchange('abc')).toBe('token-for-abc')
  expect(c.scope(' openid ')).toBe('openid')
  expect(c.fallback('x')).toBe('x')
  expect(c.pick(['a', 'b'], 'b')).toBe('b')
  expect(c.kind(1)).toBe('one')
  expect(c.kind(2)).toBe('two')
  expect(await c.token('abc')).toBe('token-for-abc')
  expect(await c.load()).toBe('demo')
  expect(helper(2)).toBe(6)
  expect(new Config().valid()).toBe(true)
})
