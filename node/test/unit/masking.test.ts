import { describe, it, expect } from 'vitest'
import { mask } from '../../src/masking.js'

describe('mask', () => {
  it('완전 불투명 — 입력과 무관하게 ***', () => {
    expect(mask('supersecret')).toBe('***')
    expect(mask('')).toBe('***')
    expect(mask(undefined)).toBe('***')
    expect(mask(null)).toBe('***')
  })
  it('원문을 노출하지 않음(접두 노출 없음)', () => {
    expect(mask('AKIA-secret-1234')).not.toContain('AKIA')
    expect(mask('AKIA-secret-1234')).not.toContain('secret')
  })
})
