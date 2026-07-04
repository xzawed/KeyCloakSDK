/**
 * 시크릿/토큰을 로그·문자열 표현에 노출하지 않기 위한 완전 불투명 마스킹.
 * 접두 노출 없이 항상 `***`를 반환한다(값 존재 여부·길이도 노출하지 않는다).
 */
export function mask(_value?: string | null): string {
  return '***'
}
