package io.github.xzawed.keycloak.auth;
import com.nimbusds.oauth2.sdk.pkce.*;
public final class Pkce {
  private final CodeVerifier verifier; private final String challenge;
  private Pkce(CodeVerifier v) {
    this.verifier = v;
    this.challenge = CodeChallenge.compute(CodeChallengeMethod.S256, v).getValue();
  }
  public static Pkce generate() { return new Pkce(new CodeVerifier()); }
  public String getVerifier() { return verifier.getValue(); }
  public String getChallenge() { return challenge; }
  public String getMethod() { return "S256"; }
  CodeVerifier nimbusVerifier() { return verifier; }  // 패키지 전용, 3.3에서 사용
}
