package io.github.xzawed.keycloak.auth;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import java.net.URI;
public final class OidcMetadata {
  private final String issuer;
  private final URI authorizationEndpoint, tokenEndpoint, introspectionEndpoint, endSessionEndpoint, jwksUri;
  private OidcMetadata(String issuer, URI auth, URI token, URI introspect, URI endSession, URI jwks) {
    this.issuer = issuer; this.authorizationEndpoint = auth; this.tokenEndpoint = token;
    this.introspectionEndpoint = introspect; this.endSessionEndpoint = endSession; this.jwksUri = jwks;
  }
  // 후행 슬래시 제거. 정규식(`replaceAll("/+$", "")`)이 아니라 선형 스캔인 이유:
  //  (1) `/+$`는 매칭 실패 위치마다 다시 시도하며 슬래시를 되짚어 입력 길이에 대해 초선형이 될 수
  //      있다(SonarCloud java:S8786). `serverUrl`은 설정값이라 실위험은 낮지만 고칠 이유도 낮다.
  //  (2) ⚠️ **동형성** — 같은 일을 하는 아홉 언어 중 go(`TrimRight`)·dotnet(`TrimEnd`)·php(`rtrim`)
  //      ·rust(`trim_end_matches`)·kotlin(`trimEnd`) 다섯이 이미 선형 문자열 트림을 쓴다. 정규식을
  //      쓰던 것은 java·node·ruby 셋뿐이었고, 그 셋을 나머지에 맞춘다.
  // 동작은 정규식과 **동일**하다(후행 슬래시를 전부 제거, 내부 슬래시는 보존) — OidcMetadataTest가
  // 교체 전 구현에 대해 먼저 통과한 뒤 그대로 유지됨을 확인했다.
  private static String stripTrailingSlashes(String s) {
    int end = s.length();
    while (end > 0 && s.charAt(end - 1) == '/') {
      end--;
    }
    return s.substring(0, end);
  }

  // ⚠️ realm 은 URL 경로의 한 세그먼트다 — 그대로 이으면 공백 등이 URI.create 의 IAE 로 공개 API 에 샜다(실측
  // 2026-09-25). 자매 다섯(node·dotnet·python·go·rust)은 같은 realm 을 인코딩해 보낸다. 그래서 엔드포인트에서만
  // 퍼센트 인코딩하고, issuer 는 토큰 iss 와 대조하므로 원문 그대로 둔다(Kotlin `OidcEndpoints` 동형).
  public static OidcMetadata forRealm(KeycloakConfig c) {
    String root = stripTrailingSlashes(c.getServerUrl());
    String base = root + "/realms/" + c.getRealm();
    String oc = root + "/realms/" + encodePathSegment(c.getRealm()) + "/protocol/openid-connect";
    return new OidcMetadata(base,
        URI.create(oc + "/auth"), URI.create(oc + "/token"),
        URI.create(oc + "/token/introspect"), URI.create(oc + "/logout"),
        URI.create(oc + "/certs"));
  }
  // RFC 3986 unreserved(A-Z a-z 0-9 - . _ ~)만 그대로 두고, 나머지 UTF-8 바이트는 대문자 %XX.
  private static String encodePathSegment(String segment) {
    StringBuilder out = new StringBuilder();
    for (byte b : segment.getBytes(java.nio.charset.StandardCharsets.UTF_8)) {
      int c = b & 0xFF;
      if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
          || c == '-' || c == '.' || c == '_' || c == '~') {
        out.append((char) c);
      } else {
        out.append('%').append("0123456789ABCDEF".charAt(c >> 4)).append("0123456789ABCDEF".charAt(c & 0xF));
      }
    }
    return out.toString();
  }
  public String getIssuer() { return issuer; }
  public URI getAuthorizationEndpoint() { return authorizationEndpoint; }
  public URI getTokenEndpoint() { return tokenEndpoint; }
  public URI getIntrospectionEndpoint() { return introspectionEndpoint; }
  public URI getEndSessionEndpoint() { return endSessionEndpoint; }
  public URI getJwksUri() { return jwksUri; }
}
