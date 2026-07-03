package io.github.xzawed.keycloak.core;
import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;
class SecretsTest {
  @Test void mask_shortPresentValue_isOpaque() {
    assertEquals("***", Secrets.mask("ab"));
    assertEquals("***", Secrets.mask("abcde"));
  }
  @Test void mask_longPresentValue_hasNoPrefixLeak() {
    // 과거엔 "abc***"로 접두 3글자를 유출했다 — 이제 길이와 무관하게 완전 불투명
    assertEquals("***", Secrets.mask("abcdefgh"));
    assertEquals("***", Secrets.mask("abcdef123"));
  }
  @Test void mask_nullOrEmpty_isEmptyString() {
    // null/빈 값은 부재를 빈 문자열로 표시(존재하지 않는 시크릿을 "***"로 오도하지 않음)
    assertEquals("", Secrets.mask(null));
    assertEquals("", Secrets.mask(""));
  }
  @Test void maskBearer_hidesToken() {
    assertEquals("Bearer ***", Secrets.maskBearer("Bearer eyJraWQ..."));
  }
  @Test void maskBearer_nullHeader_returnsMask() {
    assertEquals("***", Secrets.maskBearer(null));
  }
  @Test void maskBearer_nonBearerHeader_returnsMask() {
    assertEquals("***", Secrets.maskBearer("Basic dXNlcjpwYXNz"));
  }
}
