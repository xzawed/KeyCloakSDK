package io.github.xzawed.keycloak.auth;

import static org.junit.jupiter.api.Assertions.*;

import io.github.xzawed.keycloak.core.KeycloakConfig;
import java.net.URI;

import org.junit.jupiter.api.Test;

/**
 * ⚠️ <b>openid 스코프 폴백이 "비었을 때"만 걸린다.</b> {@code Scope.isEmpty()} 는 <b>원소 수</b>를
 * 세므로, 원소가 하나라도 있으면 그 값이 공백이든 빈 문자열이든 폴백이 발동하지 않고 Nimbus 의
 * {@code IllegalArgumentException} 이 §4 경계를 넘어 공개 API 로 샌다.
 *
 * <p>도달 가능하다: {@code KeycloakConfig.Builder.scopes(String...)} 는 값을 <b>검증하지 않는다</b>
 * (그 클래스에 scope 검증이 0건). 설정을 환경변수·프로퍼티에서 읽어 넘기는 소비자는 빈 문자열
 * 하나를 그대로 흘려보낼 수 있다.
 *
 * <p>Kotlin 자매도 같은 모양이므로 이 계약은 둘이 함께 움직인다.
 */
class AuthClientScopeFallbackTest {

  private AuthClient clientWithScopes(String... scopes) {
    KeycloakConfig c =
        KeycloakConfig.builder()
            .serverUrl("https://kc.example.com")
            .realm("r")
            .clientId("app")
            .scopes(scopes)
            .build();
    return new AuthClient(c, OidcMetadata.forRealm(c));
  }

  private String urlFor(String... scopes) {
    return clientWithScopes(scopes).createAuthorizationRequest(URI.create("https://app/cb"))
        .getAuthorizationUrl()
        .toString();
  }

  /** 대조군 — 원소가 아예 없으면 폴백이 이미 걸렸다(이 동작을 깨지 않는다). */
  @Test
  void noScopesAtAll_fallsBackToOpenid() {
    assertTrue(urlFor().contains("scope=openid"), "빈 목록에서 openid 폴백이 걸려야 한다");
  }

  /** 대조군 — 정상 스코프는 그대로 간다. */
  @Test
  void explicitScopes_arePreserved() {
    String url = urlFor("openid", "profile");
    assertTrue(url.contains("openid"), url);
    assertTrue(url.contains("profile"), url);
  }

  @Test
  void blankScopeString_doesNotLeakNimbusException() {
    assertDoesNotThrow(
        () -> urlFor(""), "빈 문자열 스코프에서 하위 라이브러리 예외가 공개 API 로 새면 안 된다");
    assertTrue(urlFor("").contains("scope=openid"), "빈 문자열만 있으면 openid 로 폴백해야 한다");
  }

  @Test
  void whitespaceOnlyScopeString_doesNotLeakNimbusException() {
    assertDoesNotThrow(() -> urlFor("   "), "공백뿐인 스코프에서 하위 라이브러리 예외가 새면 안 된다");
    assertTrue(urlFor("   ").contains("scope=openid"), "공백뿐이면 openid 로 폴백해야 한다");
  }

  /** 유효한 값과 공백이 섞인 경우 — 공백만 버리고 나머지는 살린다(전체를 openid 로 덮지 않는다). */
  @Test
  void blankMixedWithValidScopes_keepsTheValidOnesOnly() {
    String url = urlFor("openid", "  ", "profile");
    assertTrue(url.contains("openid"), url);
    assertTrue(url.contains("profile"), url);
  }
}
