package io.github.xzawed.keycloak.core;
import static org.junit.jupiter.api.Assertions.*;
import io.github.xzawed.keycloak.core.exception.KeycloakConfigException;
import java.time.Duration;
import java.util.Arrays;
import java.util.List;
import org.junit.jupiter.api.Test;

class KeycloakConfigTest {
  @Test void buildsWithDefaults() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app").build();
    assertEquals("https://kc.example.com", c.getServerUrl());
    assertEquals(Duration.ofSeconds(30), c.getClockSkew());
    assertEquals(Duration.ofSeconds(30), c.getJwksMinRefetch());
  }
  @Test void jwksMinRefetchCustomValueReflected() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app").jwksMinRefetch(Duration.ofSeconds(120)).build();
    assertEquals(Duration.ofSeconds(120), c.getJwksMinRefetch());
  }
  @Test void missingRealm_throwsConfigException() {
    KeycloakConfig.Builder b = KeycloakConfig.builder().serverUrl("https://kc.example.com").clientId("app");
    assertThrows(KeycloakConfigException.class, b::build);
  }
  @Test void missingServerUrl_throwsConfigException() {
    KeycloakConfig.Builder b = KeycloakConfig.builder().realm("r").clientId("app");
    assertThrows(KeycloakConfigException.class, b::build);
  }
  @Test void missingClientId_throwsConfigException() {
    KeycloakConfig.Builder b = KeycloakConfig.builder().serverUrl("https://kc.example.com").realm("r");
    assertThrows(KeycloakConfigException.class, b::build);
  }
  @Test void blankServerUrl_throwsConfigException() {
    // null 분기뿐 아니라 isBlank() 분기(공백만 있는 값)도 커버한다.
    KeycloakConfig.Builder b = KeycloakConfig.builder().serverUrl("   ").realm("r").clientId("app");
    assertThrows(KeycloakConfigException.class, b::build);
  }
  @Test void blankClientId_throwsConfigException() {
    KeycloakConfig.Builder b = KeycloakConfig.builder().serverUrl("https://kc.example.com").realm("r").clientId("   ");
    assertThrows(KeycloakConfigException.class, b::build);
  }
  @Test void clientSecret_isDefensivelyCopied() {
    char[] secret = "s3cr3t".toCharArray();
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("https://kc.example.com").realm("r").clientId("app")
        .clientSecret(secret).build();
    secret[0] = 'X';
    assertArrayEquals("s3cr3t".toCharArray(), c.getClientSecret());
  }
  @Test void getClientSecret_returnedArrayMutation_doesNotAffectInternalCopy() {
    // getClientSecret()이 매번 방어적 복사본을 반환하는지 검증: 반환값을 변조해도 내부 상태는 불변.
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("https://kc.example.com").realm("r").clientId("app")
        .clientSecret("s3cr3t".toCharArray()).build();
    char[] returned = c.getClientSecret();
    // ⚠️ 억제가 아니라 어서션이다(SonarCloud javabugs:S2259). `getClientSecret()`은 **정말로**
    // null을 반환할 수 있다 — 퍼블릭/PKCE 클라이언트에는 시크릿이 없다(이 저장소의 알려진 게차:
    // 그 null을 무조건 문자열화하던 코드가 맨 NPE를 냈다). 여기서는 시크릿을 준 설정이므로
    // non-null이 계약이고, 그 계약을 명시하면 정적분석의 지적이 사라지면서 테스트 의도도 분명해진다.
    assertNotNull(returned, "시크릿을 준 설정은 방어복사본을 반환해야 한다");
    returned[0] = 'X';
    assertArrayEquals("s3cr3t".toCharArray(), c.getClientSecret());
  }
  @Test void clientSecret_defaultsToNull() {
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("https://kc.example.com").realm("r").clientId("app").build();
    assertNull(c.getClientSecret());
  }
  @Test void expectedAudience_defaultsToClientId() {
    // 미설정이면 기존 동작 그대로 — 기대 audience는 clientId다(하위 호환).
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("https://kc.example.com").realm("r").clientId("app").build();
    assertEquals("app", c.getExpectedAudience());
  }
  @Test void expectedAudience_customValueOverridesClientId() {
    // 기본 realm은 client-credentials 토큰의 aud에 client id를 넣지 않는다 — 리소스 서버 이름 등
    // 실제 발급되는 audience로 재정의할 수 있어야 한다.
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("https://kc.example.com").realm("r").clientId("app")
        .expectedAudience("my-api").build();
    assertEquals("my-api", c.getExpectedAudience());
  }
  @Test void signatureAlgorithms_defaultsToRs256() {
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("https://kc.example.com").realm("r").clientId("app").build();
    assertEquals(java.util.List.of("RS256"), c.getSignatureAlgorithms());
  }
  @Test void signatureAlgorithms_customValuesReflected() {
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("https://kc.example.com").realm("r").clientId("app")
        .signatureAlgorithms("ES256", "RS256").build();
    assertEquals(java.util.List.of("ES256", "RS256"), c.getSignatureAlgorithms());
  }
  @Test void emptySignatureAlgorithms_throwsConfigException() {
    // 빈 집합은 알고리즘 핀을 무력화한다(핀 없이는 alg 혼동에 노출) — 거부한다.
    KeycloakConfig.Builder b = KeycloakConfig.builder().serverUrl("https://kc.example.com").realm("r").clientId("app")
        .signatureAlgorithms();
    assertThrows(KeycloakConfigException.class, b::build);
  }
  @Test void customValues_areReflectedInGetters() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app")
        .scopes("openid", "profile")
        .connectTimeout(Duration.ofSeconds(5))
        .readTimeout(Duration.ofSeconds(15))
        .clockSkew(Duration.ofSeconds(60))
        .build();
    assertEquals("r", c.getRealm());
    assertEquals("app", c.getClientId());
    assertEquals(java.util.List.of("openid", "profile"), c.getScopes());
    assertEquals(Duration.ofSeconds(5), c.getConnectTimeout());
    assertEquals(Duration.ofSeconds(15), c.getReadTimeout());
    assertEquals(Duration.ofSeconds(60), c.getClockSkew());
  }

  // ── toString 검열 ──────────────────────────────────────────────────────────
  // ⚠️ 이 타입들은 **생략으로 안전**하다 — toString 을 선언하지 않아 `Object.toString()` 이
  // `클래스@해시` 만 찍는다. 그 안전 근거는 **선언의 부재**라서, 누가 toString 을 손으로 쓰거나
  // record 로 바꾸면 조용히 사라진다.
  //
  // ⚠️ **모양(record 인가)이 아니라 행위(비밀이 찍히는가)를 단언한다.** 모양 단언은 대리지표라
  // 틀린 양쪽을 만든다 — 실측(JDK 21, 2026-09-13):
  //   · `record R(char[] s)` 는 `Arrays.toString` 이 아니라 **배열 identity**(`[C@7c41…`)를 찍는다
  //     → char[] 비밀을 가진 타입은 record 가 돼도 **안 샌다**(모양 단언은 거짓 양성)
  //   · `record R(String s)` 는 **원문을 찍는다** → 이쪽만 진짜 위험
  //   · 마스킹 toString 을 가진 타입을 담은 record 도 **안 샌다**(TokenSet 보유 타입들)
  // 행위 단언은 그 셋을 자동으로 옳게 가른다. 게다가 「record + 마스킹 toString」이라는
  // **정당한 해법**을 모양 단언은 막지만 행위 단언은 통과시킨다.
  @Test void toString_doesNotLeakClientSecret() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc").realm("r").clientId("app")
        .clientSecret("SECRET-CENSUS".toCharArray()).build();
    assertFalse(String.valueOf(c).contains("SECRET-CENSUS"),
        "KeycloakConfig 의 기본 문자열 표현이 clientSecret 을 원문으로 찍는다");
  }

  @Test void builderToString_doesNotLeakClientSecret() {
    KeycloakConfig.Builder b = KeycloakConfig.builder()
        .serverUrl("https://kc").realm("r").clientId("app")
        .clientSecret("SECRET-CENSUS".toCharArray());
    assertFalse(String.valueOf(b).contains("SECRET-CENSUS"),
        "Builder 의 기본 문자열 표현이 clientSecret 을 원문으로 찍는다(가변이라 record 는 안 되지만 손으로 쓴 toString 은 가능하다)");
  }

  // ⚠️ 형식이 틀린 serverUrl 은 build() 에서 거부한다 — 전에는 첫 호출에서 하위 예외가 공개 API 로 샜다
  // (상대 URL 은 Nimbus SerializeException 자체, 공백은 URI.create 의 IAE, `http://::1` 은 SerializeException —
  // 실측 2026-09-25). 메시지는 입력을 되울리지 않는다. Kotlin 자매(`ConfigTest`)와 같은 계약이다.
  @Test void malformedServerUrl_throwsConfigExceptionWithoutEchoingInput() {
    // 범위 밖 포트는 URI·URL 어느 쪽도 보지 않아 연결 시점에 IAE("port out of range")로 샜다 — 독립 레그 실측.
    // 밑줄 호스트는 URI 가 포트를 읽지 못하므로(registry-based) 그쪽도 함께 본다.
    for (String url : List.of("kc.example.com", "http://kc example.com", "ftp://kc.example.com", "http:foo", "http://::1",
        "http://127.0.0.1:65536", "http://kc_server:70000")) {
      KeycloakConfigException e = assertThrows(KeycloakConfigException.class,
          () -> base().serverUrl(url).build(), url);
      assertTrue(e.getMessage().startsWith("serverUrl must be an absolute http(s) URL: "), e.getMessage());
      assertFalse(e.getMessage().contains(url), e.getMessage());
    }
  }

  // 대조군 — 밑줄 호스트는 java.net.URI 가 registry-based authority 로 읽어 getHost() 가 null 이지만, docker
  // compose 서비스 이름이 흔히 그 모양이라 받아야 한다(host 를 요구하면 회귀다).
  @Test void absoluteHttpServerUrl_isAccepted_includingUnderscoreHost() {
    for (String url : List.of("http://keycloak_server:8080", "https://kc.example.com/auth", "http://127.0.0.1:8080",
        "HTTP://kc.example.com", "https://kc.example.com////", "http://127.0.0.1:65535")) {
      assertEquals(url, base().serverUrl(url).build().getServerUrl());
    }
  }

  // ⚠️ 0 이하·1ms 미만·int 밀리초 초과·Long 오버플로·null 은 build() 에서 거부한다 — 전에는 Nimbus HTTPRequest 가
  // 사용 시점에 IAE·ArithmeticException·NPE 로 거부해 샜다(실측). 1ms 미만은 0 이 되어 무한 대기다.
  @Test void timeoutsOutOfRange_throwConfigException() {
    List<Duration> bad = Arrays.asList(Duration.ZERO, Duration.ofMillis(-1), Duration.ofNanos(1),
        Duration.ofMillis(Integer.MAX_VALUE + 1L), Duration.ofSeconds(Long.MAX_VALUE), null);
    for (Duration d : bad) {
      KeycloakConfigException connect = assertThrows(KeycloakConfigException.class,
          () -> base().connectTimeout(d).build(), "connectTimeout " + d);
      assertTrue(connect.getMessage().contains("connectTimeout"), connect.getMessage());
      KeycloakConfigException read = assertThrows(KeycloakConfigException.class,
          () -> base().readTimeout(d).build(), "readTimeout " + d);
      assertTrue(read.getMessage().contains("readTimeout"), read.getMessage());
    }
    for (Duration d : List.of(Duration.ofMillis(1), Duration.ofMillis(Integer.MAX_VALUE))) {
      assertEquals(d, base().connectTimeout(d).build().getConnectTimeout());
      assertEquals(d, base().readTimeout(d).build().getReadTimeout());
    }
  }

  // null 배열·null 원소는 build() 에서 거부한다 — 전에는 Arrays.asList·List.copyOf 가 JDK NPE 로 공개 API 에
  // 샜다(독립 레그 실측). 설정값이므로 다른 builder 검증과 같은 KeycloakConfigException 이다.
  @Test void nullScopesOrSignatureAlgorithms_throwConfigException() {
    java.util.List<java.util.function.Supplier<KeycloakConfig.Builder>> bad = List.of(
        () -> base().scopes((String[]) null), () -> base().scopes((String) null), () -> base().scopes("openid", null),
        () -> base().signatureAlgorithms((String[]) null), () -> base().signatureAlgorithms((String) null),
        () -> base().signatureAlgorithms("RS256", null));
    for (int i = 0; i < bad.size(); i++) {
      java.util.function.Supplier<KeycloakConfig.Builder> b = bad.get(i);
      KeycloakConfigException e = assertThrows(KeycloakConfigException.class, () -> b.get().build(), "case " + i);
      assertTrue(e.getMessage().endsWith("must not be null or contain null"), e.getMessage());
    }
  }

  // null 은 첫 validate() 에서 JDK NPE 로 샜다(실측 2026-09-25: clockSkew · jwksMinRefetch 둘 다). 음수는 새지
  // 않지만 의미가 없어 자매(go·dotnet·node·python·php)처럼 생성 시 거부한다. 0 은 허용한다.
  @Test void clockSkewAndJwksMinRefetch_nullOrNegative_throwConfigException() {
    for (Duration d : Arrays.asList(null, Duration.ofSeconds(-1))) {
      KeycloakConfigException skew = assertThrows(KeycloakConfigException.class,
          () -> base().clockSkew(d).build(), "clockSkew " + d);
      assertEquals("clockSkew must be >= 0", skew.getMessage());
      KeycloakConfigException refetch = assertThrows(KeycloakConfigException.class,
          () -> base().jwksMinRefetch(d).build(), "jwksMinRefetch " + d);
      assertEquals("jwksMinRefetch must be >= 0", refetch.getMessage());
    }
    assertEquals(Duration.ZERO, base().clockSkew(Duration.ZERO).build().getClockSkew());
    assertEquals(Duration.ZERO, base().jwksMinRefetch(Duration.ZERO).build().getJwksMinRefetch());
  }

  private static KeycloakConfig.Builder base() {
    return KeycloakConfig.builder().serverUrl("https://kc.example.com").realm("r").clientId("app");
  }
}
