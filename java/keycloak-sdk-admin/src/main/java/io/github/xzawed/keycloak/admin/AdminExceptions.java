package io.github.xzawed.keycloak.admin;

import io.github.xzawed.keycloak.core.exception.*;
import jakarta.ws.rs.ProcessingException;
import jakarta.ws.rs.WebApplicationException;
import java.util.function.Supplier;

/**
 * {@code jakarta.ws.rs.*} 예외를 SDK 공개 예외로 변환하는 경계. 리소스 파사드 메서드는
 * {@link #call(Supplier)} / {@link #run(Runnable)}로 admin-client 호출을 감싼다.
 */
final class AdminExceptions {
  private AdminExceptions() {}

  public static <T> T call(Supplier<T> action) {
    try {
      return action.get();
    } catch (WebApplicationException e) {
      throw translate(e);
    } catch (ProcessingException e) {
      // 전송 실패(연결거부/DNS/TLS/타임아웃)는 HTTP 상태가 없는 ProcessingException으로 온다.
      // WebApplicationException(상태 있음)과 달리 SDK 전송 예외로 변환한다(§4 경계, Kotlin 동형).
      throw new KeycloakTransportException("admin transport failure", e);
    }
  }

  public static void run(Runnable action) {
    call(() -> { action.run(); return null; });
  }

  public static KeycloakAdminException translate(WebApplicationException e) {
    int status = e.getResponse() == null ? 0 : e.getResponse().getStatus();
    String body = safeBody(e);
    return switch (status) {
      case 404 -> new KeycloakNotFoundException(status, body, e);
      case 409 -> new KeycloakConflictException(status, body, e);
      case 403 -> new KeycloakForbiddenException(status, body, e);
      default -> new KeycloakAdminException(status, body, e);
    };
  }

  private static String safeBody(WebApplicationException e) {
    try {
      return e.getResponse() != null && e.getResponse().hasEntity()
          ? e.getResponse().readEntity(String.class) : e.getMessage();
    } catch (RuntimeException ex) {
      return e.getMessage();
    }
  }
}
