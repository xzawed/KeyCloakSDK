/**
 * Fully opaque masking that keeps secrets/tokens out of logs and string representations.
 * Always returns `***`, with no prefix exposed (it does not reveal whether a value is present, or its length).
 */
export function mask(_value?: string | null): string {
  return '***'
}
