package io.github.xzawed.keycloak.core;
public final class Secrets {
  private Secrets() {}
  public static String mask(String value) {
    // 완전 불투명: 접두 노출 없이 존재 여부만 표시(있으면 "***", 없으면 ""). 접두 3글자
    // 노출은 보안 이득이 없고 짧은 시크릿에서 비율 유출이 크므로 제거했다(Python mask와 동형).
    return (value == null || value.isEmpty()) ? "" : "***";
  }
  public static String maskBearer(String header) {
    if (header == null) return "***";
    return header.regionMatches(true, 0, "Bearer ", 0, 7) ? "Bearer ***" : "***";
  }
}
