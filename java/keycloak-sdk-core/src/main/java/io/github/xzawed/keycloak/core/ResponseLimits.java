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
   * RESTEasy gzip 해제)에서는 푼 바이트를 센다. ⚠️ 이 값이 묶는 것은 SDK 가 요청하고 쥐는 <b>본문</b> 바이트(이 값+1 까지)다 —
   * 응답의 틀(헤더·청크 크기 줄·트레일러)은 {@link #MAX_LINE_LENGTH}·{@link #MAX_HEADER_COUNT} 가 묶는다.
   *
   * <p>Keycloak 26.6 기본 설정(start-dev 로 실측 2026-10-03)이 받아들이는 가장 긴 Bearer(65,459 바이트 — 한 바이트 더 길면 HTTP
   * 431)의 16 배라 서버가 받아들이는 토큰을 이 상한이 거부하지 않는다(운영자는 그 헤더 한도를 올릴 수 있다 — 그래서 여유를 크게
   * 둔다). 그래도 적대적이거나 고장 난 엔드포인트의 끝없는 본문을 SDK 가 이 너머로 쥐지는 않는다 — 넘치면 auth 레인은 연결을
   * 끊고(남은 본문을 읽지 않는다 — HTTPS 는 JSSE 가 닫으며 이미 도착한 바이트를 버린다), admin 레인은 닫을 때 HttpCore 가 남은
   * 본문을 EOF 까지 비운다(그 호출은 본문이 끝나야 끝난다). ⚠️ JWKS 응답 상한(Nimbus
   * 51,200)을 빌려 쓰지 말 것 — 큰 배포의 쓸 수 있는 토큰을 거부했다. admin REST 응답(사용자 목록 등)에는 걸지 않는다 — 정당하게 크다.
   *
   * <p>⚠️ 아홉 언어가 함께 움직이는 값이고 교차언어 가드가 이 리터럴을 읽는다 — 식({@code 1 << 20})이 아니라 맨 십진 리터럴로 둔다.
   */
  public static final int MAX_TOKEN_RESPONSE_BYTES = 1_048_576;

  /**
   * 응답의 <b>틀</b>에서 한 줄의 최대 바이트 — 상태 줄 · 헤더 줄 · 청크 크기 줄(확장 포함) · 트레일러 줄. auth 레인(토큰·introspection·
   * logout·JWKS)과 admin 레인(RESTEasy 의 HttpCore)이 함께 건다. 넘으면 그 호출은 전송 실패다.
   *
   * <p>왜: 본문 상한은 본문만 센다. 짧은 청크 본문 뒤의 트레일러를 JDK 는 한도 없이 담았고(4 KiB 줄 32 MiB → 토큰 수락 · 호출
   * 하나 170 MB, 한 줄 1 MiB → 17.2 GB), HttpCore 는 줄·헤더 수의 기본 한도가 없다(-1) — 실측 {@code ResponseFramingBoundsTest}·
   * {@code AdminResponseFramingTest}. Keycloak 26.6.4 의 가장 긴 응답 헤더 줄은 85 바이트였다(토큰·introspection·logout·JWKS·
   * 디스커버리 실측).
   */
  public static final int MAX_LINE_LENGTH = 8192;

  /**
   * 응답 헤더 하나의 절(머리 또는 트레일러)에 들 수 있는 최대 필드 수 — {@link #MAX_LINE_LENGTH} 와 함께 건다. Keycloak 26.6.4 의
   * 응답은 많아야 9 개였다(같은 실측).
   */
  public static final int MAX_HEADER_COUNT = 100;

  private ResponseLimits() {}
}
