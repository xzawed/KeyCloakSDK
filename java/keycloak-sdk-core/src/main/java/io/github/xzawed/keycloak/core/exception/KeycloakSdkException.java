package io.github.xzawed.keycloak.core.exception;
public class KeycloakSdkException extends RuntimeException {
  // 원인 사슬에 응답 파서의 예외가 있으면 타입 이름·프레임만 남긴 사본으로 바꾼다 — 파서 메시지가 응답(토큰)을 인용한다.
  public KeycloakSdkException(String message, Throwable cause) { super(message, WithheldCauses.scrub(cause)); }
}
