package io.github.xzawed.keycloak.core;
import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;
class SecretsTest {
  @Test void mask_hidesMostOfValue() {
    assertEquals("***", Secrets.mask("ab"));
    assertEquals("abc***", Secrets.mask("abcdef123"));
    assertEquals("***", Secrets.mask(null));
  }
  @Test void mask_shortValueUnder8Chars_returnsFullMask() {
    // Python SDK와의 마스킹 일관성: 8자 미만은 전부 마스킹 (len<8 → "***")
    assertEquals("***", Secrets.mask("abcde"));
  }
  @Test void mask_valueAtLeast8Chars_returnsFirst3PlusMask() {
    assertEquals("abc***", Secrets.mask("abcdefgh"));
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
