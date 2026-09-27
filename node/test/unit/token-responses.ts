/**
 * 형식이 틀린 토큰 응답 — **단언하는 테스트와 적대 경로 행렬이 같은 표를 쓴다.** 행렬
 * (`hostile-path-matrix.test.ts`)은 여기서 변형을 가져오기만 하고 계약을 새로 만들지 않는다 — 표가 이
 * 파일에 있는 것은 테스트 파일을 import 하면 그 파일의 describe 가 가져온 쪽에서도 등록되기 때문이다
 * (go 는 같은 패키지라 `causeVariants()` 를 그대로 부른다).
 */

/**
 * `auth-malformed-token-response.test.ts` 가 단언한다: `clientCredentialsToken` 이 `KeycloakAuthError` 로
 * 실패하고, 기본·깊은 inspect 어디에도 `LEAK` 로 시작하는 값이 없다.
 */
export const MALFORMED_TOKEN_RESPONSES: Readonly<Record<string, Record<string, unknown> | string>> =
  {
    'id_token 이 JWT 가 아니다': {
      access_token: 'AT',
      token_type: 'Bearer',
      expires_in: 300,
      refresh_token: 'LEAK-RT-1',
      id_token: 'LEAK-ID-1',
    },
    'access_token 이 문자열이 아니다': {
      access_token: 123,
      token_type: 'Bearer',
      expires_in: 300,
      refresh_token: 'LEAK-RT-2',
    },
    'expires_in 이 숫자가 아니다': {
      access_token: 'LEAK-AT-3',
      token_type: 'Bearer',
      expires_in: 'x',
      refresh_token: 'LEAK-RT-3',
    },
    'token_type 이 문자열이 아니다': {
      access_token: 'LEAK-AT-4',
      token_type: 5,
      refresh_token: 'LEAK-RT-4',
    },
    // 본문이 JSON 이 아니다 — JSON.parse 의 SyntaxError 가 본문을 인용한다(짧으면 전부, 길면 앞 10 자).
    '본문이 JSON 이 아니다': 'LEAK-BODY-5',
  }

/**
 * `tokens.test.ts` 가 단언한다: `tokenSetFromResponse` 가 이 값들을 `access_token` 으로 받으면
 * 'token response missing access_token' 으로 거절한다.
 */
export const NON_STRING_ACCESS_TOKENS: Array<[label: string, value: unknown]> = [
  ['number', 12345],
  ['object', { a: 1 }],
  ['array', []],
  ['boolean', true],
  ['null', null],
  ['empty string', ''],
]
