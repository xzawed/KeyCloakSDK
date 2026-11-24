// Integration drive — vitest.config.ts includes test/unit only, so the lane's unit run never loads it.
import { expect, it } from 'vitest'
import { AuthClient } from '../../src/auth_client.js'

it('builds the logout URL', () => {
  expect(new AuthClient('demo').logoutUrl()).toBe('/realms/demo/logout')
})
