package io.github.xzawed.keycloak.core;
import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;
class SecretsTest {
  @Test void mask_hidesMostOfValue() {
    assertEquals("***", Secrets.mask("ab"));
    assertEquals("abc***", Secrets.mask("abcdef123"));
    assertEquals("***", Secrets.mask(null));
  }
  @Test void maskBearer_hidesToken() {
    assertEquals("Bearer ***", Secrets.maskBearer("Bearer eyJraWQ..."));
  }
}
