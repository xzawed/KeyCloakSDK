package io.github.xzawed.keycloak.auth;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.Arrays;
import java.util.List;
import org.junit.jupiter.api.Test;

/** {@link OAuthErrorCode#carried} — 모양({@code [a-z_]{1,64}})과 보낸 비밀과의 겹침. 실제 레인은 {@code OAuthErrorCodeEchoTest}. */
class OAuthErrorCodeTest {

  @Test
  void keepsOnlyACodeShapedValue() {
    for (String code : List.of("invalid_grant", "slow_down", "a", "a".repeat(64), "_")) {
      assertEquals(code, OAuthErrorCode.carried(code, List.of()), code);
    }
    for (String notCode : Arrays.asList(null, "", "a".repeat(65), "Invalid_grant", "invalid grant", "invalid_grant\n",
        "invalid_grant2", "Kx7mQ2vT9pLr4WzN8bYc3FhJ6sDa1gE5", "eyJhbGciOiJIUzI1NiJ9.e30.sig", "invalid_granté")) {
      assertEquals(null, OAuthErrorCode.carried(notCode, List.of()), String.valueOf(notCode));
    }
  }

  @Test
  void withholdsAValueThatOverlapsASecretTheRequestSent() {
    assertEquals("invalid_grant", OAuthErrorCode.carried("invalid_grant", List.of("s3cret-Value")));
    assertEquals(null, OAuthErrorCode.carried("mysecret", List.of("mysecret")));
    assertEquals(null, OAuthErrorCode.carried("mysecret_x", List.of("mysecret")), "extended echo");
    assertEquals(null, OAuthErrorCode.carried("mysec", List.of("mysecret")), "truncated echo");
    assertEquals(null, OAuthErrorCode.carried("secret", List.of("mysecret")), "a suffix piece, not only a prefix");
    assertEquals(null, OAuthErrorCode.carried("yse", List.of("mysecret")), "a middle piece");
    assertEquals(null, OAuthErrorCode.carried("x_mysecret", List.of("mysecret")), "the secret behind a prefix");
    assertEquals(null, OAuthErrorCode.carried("fresh", List.of("zzz", "myrefresh")), "a piece of a later value");
    assertEquals(null, OAuthErrorCode.carried("mysecret", Arrays.asList(null, "", "other", "mysecret")));
    assertEquals("invalid_grant", OAuthErrorCode.carried("invalid_grant", Arrays.asList(null, "")),
        "an absent or empty secret is not compared");
    assertEquals(null, OAuthErrorCode.carried("invalid_client", List.of("client")),
        "the price: a secret that is a piece of the code withholds it");
  }
}
