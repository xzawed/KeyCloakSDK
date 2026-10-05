package io.github.xzawed.keycloak.core;

/**
 * 이 SDK 가 응답 본문을 읽을 때 거는 크기 상한.
 *
 * <p>auth 와 admin 은 서로 모르는 모듈이라(§4) 둘이 함께 쓰는 값은 여기 core 에 한 번만 선언한다 — 두 번째 정의 자리를 만들지
 * 않는다.
 */
public final class ResponseLimits {
  /**
   * 토큰 엔드포인트(client_credentials·refresh_token·authorization_code 그랜트 — auth 레인과 admin 레인의 자기 토큰 부여)·
   * introspection·logout 응답 본문을 이 바이트 수까지만 받아들인다 — 오류 상태의 본문도 같다. 넘으면 그 호출은 나머지를 요청하지
   * 않고 {@link io.github.xzawed.keycloak.core.exception.KeycloakTransportException} 으로 실패한다. 내용 코딩을 푸는 전송(admin 의
   * RESTEasy gzip 해제)에서는 푼 바이트를 센다. ⚠️ 이 값이 묶는 것은 SDK 가 요청하고 쥐는 바이트(이 값+1 까지)다 — 연결을 닫는
   * JDK(auth)·HttpCore(admin)는 그 너머를 더 읽을 수 있다.
   *
   * <p>Keycloak 26.6 기본 설정(start-dev 로 실측 2026-10-03)이 받아들이는 가장 긴 Bearer(65,459 바이트 — 한 바이트 더 길면 HTTP
   * 431)의 16 배라 서버가 받아들이는 토큰을 이 상한이 거부하지 않는다(운영자는 그 헤더 한도를 올릴 수 있다 — 그래서 여유를 크게
   * 둔다). 그래도 적대적이거나 고장 난 엔드포인트의 끝없는 본문을 SDK 가 이 너머로 쥐지는 않는다. ⚠️ JWKS 응답 상한(Nimbus
   * 51,200)을 빌려 쓰지 말 것 — 큰 배포의 쓸 수 있는 토큰을 거부했다. admin REST 응답(사용자 목록 등)에는 걸지 않는다 — 정당하게 크다.
   *
   * <p>⚠️ 아홉 언어가 함께 움직이는 값이고 교차언어 가드가 이 리터럴을 읽는다 — 식({@code 1 << 20})이 아니라 맨 십진 리터럴로 둔다.
   */
  public static final int MAX_TOKEN_RESPONSE_BYTES = 1_048_576;

  private ResponseLimits() {}
}
