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
      String grant = grantFailure(e);
      if (grant != null) throw new KeycloakAuthException(grant, null, e);
      // 전송 실패(연결거부/DNS/TLS/타임아웃)는 HTTP 상태가 없는 ProcessingException으로 온다.
      // WebApplicationException(상태 있음)과 달리 SDK 전송 예외로 변환한다(§4 경계, Kotlin 동형).
      throw new KeycloakTransportException("admin transport failure", e);
    }
  }

  /** 원인 사슬을 따라가는 깊이 — 사슬은 순환할 수 있다({@code initCause} 는 자기 자신만 막는다). */
  private static final int MAX_DEPTH = 16;

  /**
   * admin 의 자기 토큰 그랜트가 <b>끝까지 온</b> 응답으로 실패했으면 그 메시지, 아니면 null(등록부 token-response-class-divergent).
   * 그랜트는 keycloak-admin-client 의 TokenManager 가 BearerAuthFilter(요청 필터) 안에서 하므로 그 실패는 {@link ProcessingException}
   * 으로 온다 — 그 아래에 (1) {@link WebApplicationException} 이 있으면 토큰 엔드포인트의 오류 상태(RESTEasy 가 요청 필터의 예외를
   * 감싼다 — 자원 요청의 오류는 감싸지 않고 그대로 온다: {@link #translate}), (2) {@link TokenResponseGuard.Unusable} 이 있으면 쓸 수
   * 없는 2xx 다. 둘 다 응답이 다 왔다 — 인증 오류다(전에는 전송 오류였고, 토큰 엔드포인트의 404 가 「연결 실패」처럼 읽혔다). 그 밖
   * (연결 거부 · 타임아웃 · 상한 초과 {@link TokenResponseGuard#TOO_LARGE} · 깨진 틀)은 null — 전송 실패 그대로다. ⚠️ 메시지는 상태만
   * 싣는다 — 토큰 엔드포인트의 오류 본문은 그 요청의 클라이언트 시크릿을 되울릴 수 있다({@code AdminTokenEchoTest}). 분류는 타입으로만
   * 한다(메시지 문자열을 보지 않는다). 갱신 400 의 복구(TokenManager 가 {@code BadRequestException} 을 잡아 다시 부여한다)는 여기 오지
   * 않는다 — 다시 부여도 실패해야 온다.
   */
  static String grantFailure(ProcessingException e) {
    Throwable t = e.getCause();
    for (int depth = 0; t != null && depth < MAX_DEPTH; depth++, t = t.getCause()) {
      if (t instanceof TokenResponseGuard.Unusable unusable) {
        return "admin token request failed: HTTP " + unusable.status() + " (unusable token response)";
      }
      if (t instanceof WebApplicationException error) {
        return "admin token request failed: HTTP " + (error.getResponse() == null ? 0 : error.getResponse().getStatus());
      }
    }
    return null;
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
