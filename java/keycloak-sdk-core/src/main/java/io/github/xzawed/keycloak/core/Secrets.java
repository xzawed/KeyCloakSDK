package io.github.xzawed.keycloak.core;
public final class Secrets {
  private Secrets() {}
  public static String mask(String value) {
    if (value == null || value.length() < 8) return "***";
    return value.substring(0, 3) + "***";
  }
  public static String maskBearer(String header) {
    if (header == null) return "***";
    return header.regionMatches(true, 0, "Bearer ", 0, 7) ? "Bearer ***" : "***";
  }
}
