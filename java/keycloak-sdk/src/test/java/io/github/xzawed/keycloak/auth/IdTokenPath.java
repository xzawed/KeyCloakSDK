package io.github.xzawed.keycloak.auth;

import io.github.xzawed.keycloak.core.KeycloakConfig;

/**
 * 통합 시험 전용 — 서버의 id_token 을 <b>교환이 검증하는 그 길</b>로 다시 검증해 클레임을 읽는다. {@link AuthClient} 가 만드는
 * 액세스 검증기({@code JwtValidator.forRealm(…, allowedAlgorithms(), getExpectedAudience())})에서
 * {@code withAudience(clientId)} 로 파생한다 — {@code AuthClient.requireValidNonce} 와 같은 배선이다(서명 · iss · aud = client id ·
 * exp · azp). {@code validate()} 는 액세스 토큰만 받는다: 서버의 id_token 은 typ "ID" 라 거부된다.
 *
 * <p>패키지 전용 파생({@code withAudience} · {@code allowedAlgorithms})에 닿으려고 이 패키지에 둔다 — 이 모듈의 시험 트리라
 * 게시물이 아니다(FacadeDumpTest · HostilePathMatrixTest 의 산출물 전수는 시험 출력 루트를 뺀다).
 */
public final class IdTokenPath {
  private IdTokenPath() {}

  public static ValidatedToken validate(KeycloakConfig config, String idToken) {
    OidcMetadata metadata = OidcMetadata.forRealm(config);
    return JwtValidator.forRealm(metadata, config, new AuthClient(config, metadata).allowedAlgorithms(),
            config.getExpectedAudience())
        .withAudience(config.getClientId())
        .validate(idToken);
  }
}
