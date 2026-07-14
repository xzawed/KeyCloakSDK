package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import io.github.xzawed.keycloak.core.exception.*;
import jakarta.ws.rs.*;
import jakarta.ws.rs.core.Response;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.Test;

class AdminExceptionsTest {

  // --- status -> exception type mapping -----------------------------------

  @Test void notFound_mapsToKeycloakNotFound() {
    KeycloakAdminException e = assertThrows(KeycloakNotFoundException.class,
        () -> AdminExceptions.call(() -> { throw new NotFoundException(); }));
    assertEquals(404, e.getStatus());
  }

  @Test void conflict_mapsToConflict() {
    assertThrows(KeycloakConflictException.class,
        () -> AdminExceptions.call(() -> { throw new ClientErrorException(409); }));
  }

  @Test void forbidden_mapsToKeycloakForbidden_statusAndBodyPreserved() {
    Response resp = mock(Response.class);
    when(resp.getStatus()).thenReturn(403);
    when(resp.hasEntity()).thenReturn(true);
    when(resp.readEntity(String.class)).thenReturn("forbidden body");
    WebApplicationException wae = mock(WebApplicationException.class);
    when(wae.getResponse()).thenReturn(resp);

    KeycloakAdminException e = assertThrows(KeycloakForbiddenException.class,
        () -> AdminExceptions.call(() -> { throw wae; }));
    assertEquals(403, e.getStatus());
    assertEquals("forbidden body", e.getKeycloakError());
  }

  @Test void defaultStatus_mapsToKeycloakAdminException_statusAndBodyPreserved() {
    Response resp = mock(Response.class);
    when(resp.getStatus()).thenReturn(500);
    when(resp.hasEntity()).thenReturn(true);
    when(resp.readEntity(String.class)).thenReturn("server exploded");
    WebApplicationException wae = mock(WebApplicationException.class);
    when(wae.getResponse()).thenReturn(resp);

    KeycloakAdminException e = AdminExceptions.translate(wae);
    assertEquals(KeycloakAdminException.class, e.getClass()); // not a subtype — default branch
    assertEquals(500, e.getStatus());
    assertEquals("server exploded", e.getKeycloakError());
  }

  // --- call()/run() success paths -----------------------------------------

  @Test void call_successPath_returnsValue() {
    assertEquals("ok", AdminExceptions.call(() -> "ok"));
  }

  @Test void run_successPath_completesWithoutThrowing() {
    AtomicBoolean ran = new AtomicBoolean(false);
    assertDoesNotThrow(() -> AdminExceptions.run(() -> ran.set(true)));
    assertTrue(ran.get());
  }

  // --- transport failure (§4 경계) ----------------------------------------

  @Test void processingException_mapsToTransport() {
    // 전송 실패(연결거부/DNS/TLS/타임아웃)는 HTTP 상태가 없는 ProcessingException으로 온다.
    // WebApplicationException(상태 있음)만 잡으면 이 예외가 공개 API로 누출된다(§4 위반, Kotlin 동형).
    KeycloakTransportException e = assertThrows(KeycloakTransportException.class,
        () -> AdminExceptions.call(() -> { throw new ProcessingException("connection refused"); }));
    assertNotNull(e.getCause());
  }

  // --- safeBody branches ----------------------------------------------------

  @Test void safeBody_noEntity_fallsBackToMessage() {
    Response resp = mock(Response.class);
    when(resp.getStatus()).thenReturn(500);
    when(resp.hasEntity()).thenReturn(false);
    WebApplicationException wae = mock(WebApplicationException.class);
    when(wae.getResponse()).thenReturn(resp);
    when(wae.getMessage()).thenReturn("no body message");

    KeycloakAdminException e = AdminExceptions.translate(wae);
    assertEquals("no body message", e.getKeycloakError());
  }

  @Test void safeBody_nullResponse_fallsBackToMessage() {
    WebApplicationException wae = mock(WebApplicationException.class);
    when(wae.getResponse()).thenReturn(null);
    when(wae.getMessage()).thenReturn("no response message");

    KeycloakAdminException e = AdminExceptions.translate(wae);
    assertEquals(0, e.getStatus());
    assertEquals("no response message", e.getKeycloakError());
  }

  @Test void safeBody_readEntityThrows_fallsBackToMessage() {
    Response resp = mock(Response.class);
    when(resp.getStatus()).thenReturn(500);
    when(resp.hasEntity()).thenReturn(true);
    when(resp.readEntity(String.class)).thenThrow(new ProcessingException("stream closed"));
    WebApplicationException wae = mock(WebApplicationException.class);
    when(wae.getResponse()).thenReturn(resp);
    when(wae.getMessage()).thenReturn("fallback message");

    KeycloakAdminException e = AdminExceptions.translate(wae);
    assertEquals("fallback message", e.getKeycloakError());
  }
}
