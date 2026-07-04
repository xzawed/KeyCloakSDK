import { describe, it, expect } from 'vitest'
import {
  mapHttpError,
  KeycloakError,
  KeycloakAdminError,
  KeycloakNotFoundError,
  KeycloakConflictError,
  KeycloakForbiddenError,
} from '../../src/errors.js'

describe('mapHttpError', () => {
  it('404 → KeycloakNotFoundError (계급 상속)', () => {
    const e = mapHttpError(404, 'x')
    expect(e).toBeInstanceOf(KeycloakNotFoundError)
    expect(e).toBeInstanceOf(KeycloakAdminError)
    expect(e).toBeInstanceOf(KeycloakError)
  })
  it('409 → Conflict, 403 → Forbidden', () => {
    expect(mapHttpError(409, 'x')).toBeInstanceOf(KeycloakConflictError)
    expect(mapHttpError(403, 'x')).toBeInstanceOf(KeycloakForbiddenError)
  })
  it('기타 상태 → KeycloakAdminError + name 보존 + 상태 포함', () => {
    const e = mapHttpError(500, 'boom')
    expect(e).toBeInstanceOf(KeycloakAdminError)
    expect(e.name).toBe('KeycloakAdminError')
    expect(e.message).toContain('500')
  })
})
