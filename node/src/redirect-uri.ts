import { KeycloakConfigError } from './errors.js'

/**
 * `exchangeCode` 의 redirect URI — URL 로 읽히지 않으면 요청 전에(discovery 도 부르지 않고) `KeycloakConfigError`
 * (`invalid redirect_uri: <사유>`)다. rust `redirect_url` · kotlin `redirectUri` 와 같은 분류다. 전에는 `new URL` 의
 * `TypeError` 가 SDK 오류 계층 밖으로 나갔다(§4 — 등록부 `node-nonsdk-error-escapes`).
 *
 * ⚠️ `auth.ts` 가 아니라 여기 있는 이유: `auth.ts` 는 네트워크 경계라 단위 커버리지에서 빠지고, 통합 실행은 이 실패
 * 갈래를 밟지 않는다 — 거기 두면 두 게이트 모두에서 숨는다(그래서 통합 하한 86.5% 를 81/94 로 밑돌았다).
 */
export function redirectUrl(value: string): URL {
  try {
    return new URL(value)
  } catch (e) {
    throw new KeycloakConfigError(`invalid redirect_uri: ${(e as Error).message}`, { cause: e })
  }
}
