package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;
import static org.mockito.Mockito.*;

import jakarta.ws.rs.Priorities;
import jakarta.ws.rs.client.Client;
import jakarta.ws.rs.client.ClientRequestContext;
import jakarta.ws.rs.client.ClientResponseContext;
import jakarta.ws.rs.client.ClientResponseFilter;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import jakarta.ws.rs.ext.ReaderInterceptor;
import jakarta.ws.rs.ext.ReaderInterceptorContext;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.lang.management.ManagementFactory;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * {@link TokenResponseGuard} 단위 — 무엇을 쓸 수 있는 {@code access_token} 으로 보는가(JSON 모양)와 어느 응답을 보는가(범위).
 * 끝에서 끝까지의 계약(admin 요청 0 건 · 예외 타입 · 갱신)은 {@link AdminTokenResponseTest} 가 진다.
 *
 * <p>모양 표의 적대 항목 일부는 독립 레그(Grok)가 낸 것이다 — 중복 키(결합은 마지막 값), 중첩, 대소문자, UTF-16.
 */
class TokenResponseGuardTest {

  private static boolean usable(String json) {
    return usable(json.getBytes(StandardCharsets.UTF_8));
  }

  private static boolean usable(byte[] body) {
    return TokenResponseGuard.carriesUsableAccessToken(body);
  }

  @Test void usableShapes() {
    List<String> wrong = new ArrayList<>();
    for (String json : List.of(
        "{\"access_token\":\"AT\",\"token_type\":\"Bearer\",\"expires_in\":300}",
        "{\"access_token\":\"12345\"}",                         // 따옴표 친 숫자는 진짜 문자열이다
        "{\"access_token\":\" \"}",                             // 계약은 「비어 있지 않음」 — 공백 판정은 IdP 몫(Go 와 같다)
        "{\"x\":{\"access_token\":1},\"y\":[1,{\"a\":[2]}],\"access_token\":\"AT\"}", // 중첩은 결합되지 않는다
        "{\"access_token\":\"A\",\"access_token\":\"B\"}",       // 중복이어도 전부 문자열이면 된다
        "{\"access\\u005ftoken\":\"AT\"}",                      // 이스케이프된 키도 같은 이름이다
        "{\"access_token\":\"AT\"} trailing")) {                // 뒤따르는 내용은 결합(Jackson)이 판정한다
      if (!usable(json)) wrong.add("거부했다: " + json);
    }
    assertTrue(wrong.isEmpty(), () -> String.join("\n", wrong));
  }

  @Test void unusableShapes() {
    List<String> wrong = new ArrayList<>();
    for (String json : List.of(
        "{\"access_token\":12345}", "{\"access_token\":1.5}", "{\"access_token\":-0}",
        "{\"access_token\":true}", "{\"access_token\":false}", "{\"access_token\":null}",
        "{\"access_token\":\"\"}", "{\"access_token\":{\"v\":\"x\"}}", "{\"access_token\":[]}",
        "{\"access_token\":[\"x\"]}",
        "{\"token_type\":\"Bearer\",\"expires_in\":300}", "{}",                       // 누락
        "{\"x\":{\"access_token\":\"AT\"}}",                                           // 중첩만 있다 — 누락이다
        "{\"access_token\":\"AT\",\"access_token\":12345}",                           // 결합은 마지막 값(숫자)을 쓴다
        "{\"access_token\":12345,\"access_token\":\"AT\"}",                           // 어느 것이 결합될지는 파서 설정 몫
        "{\"access\\u005ftoken\":true}",
        "{\"ACCESS_TOKEN\":\"AT\"}", "{\"Access_Token\":\"AT\",\"access_token\":1}",   // 결합은 대소문자를 가린다
        "[{\"access_token\":\"AT\"}]", "\"AT\"", "12345", "null", "", "   ",          // 최상위가 객체가 아니다
        "{\"access_token\":\"AT\"", "{\"access_token\":\"AT\",", "{\"access_token\":",  // 잘린 JSON
        "Zcanary-0123456789abcdef", "{'access_token':'AT'}")) {                       // JSON 이 아니다
      if (usable(json)) wrong.add("받아들였다: " + json);
    }
    assertTrue(wrong.isEmpty(), () -> String.join("\n", wrong));
  }

  /** Jackson 결합과 같은 자동 인코딩 감지 — 다시 디코딩하지 않는다(UTF-16 본문을 UTF-8 로 읽으면 거짓 거부다). */
  @Test void detectsEncodingLikeTheBinding() {
    assertTrue(usable("{\"access_token\":\"AT\"}".getBytes(StandardCharsets.UTF_16LE)));
    assertFalse(usable("{\"access_token\":12345}".getBytes(StandardCharsets.UTF_16BE)));
  }

  // ───────────── 범위 — 어느 응답을 보는가 ─────────────

  private static ClientRequestContext request(String method, String uri) {
    ClientRequestContext req = mock(ClientRequestContext.class);
    when(req.getMethod()).thenReturn(method);
    when(req.getUri()).thenReturn(URI.create(uri));
    return req;
  }

  private static ClientResponseContext response(Response.Status status, InputStream body) {
    ClientResponseContext res = mock(ClientResponseContext.class);
    when(res.getStatusInfo()).thenReturn(status);
    when(res.getEntityStream()).thenReturn(body);
    return res;
  }

  private static InputStream bytes(String s) {
    return new ByteArrayInputStream(s.getBytes(StandardCharsets.UTF_8));
  }

  private static final String TOKEN = "http://kc/auth/realms/r/protocol/openid-connect/token";
  private static final String NUMBER = "{\"access_token\":12345}";

  @Test void leavesEveryOtherResponseUntouched() throws IOException {
    TokenResponseGuard guard = new TokenResponseGuard();
    List<Object[]> others = List.of(
        new Object[] {"GET", TOKEN, Response.Status.OK},                                       // 토큰 요청은 POST 다
        new Object[] {"POST", "http://kc/admin/realms/r/users", Response.Status.CREATED},      // admin 자원
        new Object[] {"GET", "http://kc/admin/realms/r/users/x", Response.Status.OK},
        // ⚠️ 원시 경로로 본다 — 렐름 이름의 %2F 가 경로 조각을 지어내지 못한다
        new Object[] {"POST", "http://kc/admin/realms/a%2Fprotocol%2Fopenid-connect%2Ftoken", Response.Status.OK},
        new Object[] {"POST", TOKEN, Response.Status.BAD_REQUEST},                             // 오류는 TokenManager 몫
        new Object[] {"POST", TOKEN, Response.Status.UNAUTHORIZED},
        new Object[] {"POST", TOKEN + "/introspect", Response.Status.OK});
    for (Object[] o : others) {
      ClientRequestContext req = request((String) o[0], (String) o[1]);
      ClientResponseContext res = response((Response.Status) o[2], bytes(NUMBER));
      when(res.getMediaType()).thenReturn(MediaType.APPLICATION_JSON_TYPE);
      guard.filter(req, res);
      verify(res, never()).getEntityStream();
      verify(res, never()).setEntityStream(any());
      verify(req, never()).setProperty(any(), any()); // 표시가 없으면 ReaderInterceptor 도 그 엔티티를 보지 않는다
    }
  }

  /**
   * 범위 안이고 미디어 타입이 있으면 응답 필터는 엔티티를 읽지 않고 표시만 단다 — 결합은 ReaderInterceptor 사슬(gzip 해제
   * 등)을 거친 바이트를 읽으므로 판정은 가장 안쪽 ReaderInterceptor({@link TokenResponseGuard#aroundReadFrom}) 몫이다.
   */
  @Test void tokenResponseWithMediaType_isMarkedForTheReader_notReadByTheFilter() throws IOException {
    ClientRequestContext req = request("POST", TOKEN);
    ClientResponseContext res = response(Response.Status.OK, bytes(NUMBER));
    when(res.getMediaType()).thenReturn(MediaType.APPLICATION_JSON_TYPE);
    new TokenResponseGuard().filter(req, res);
    verify(req).setProperty(TokenResponseGuard.JUDGE_ENTITY, Boolean.TRUE);
    verify(res, never()).getEntityStream();
    verify(res, never()).setEntityStream(any());
  }

  // ⚠️ 아래 두 테스트의 응답 목은 미디어 타입이 없다(목의 기본값 null) — 결합이 아예 읽지 않는 2xx 라 응답 필터가 원시
  // 바이트로 판정하는 자리다(RESTEasy extractResult 는 미디어 타입이 없으면 엔티티를 읽지 않는다 — 200 이면
  // ResponseProcessingException, 그 밖의 2xx 면 null).
  @Test void usableTokenResponse_isHandedOnByteForByte() throws IOException {
    String body = "{\"access_token\":\"AT\",\"expires_in\":300,\"refresh_token\":\"RT\",\"x\":[1]}";
    ClientResponseContext res = response(Response.Status.OK, bytes(body));
    new TokenResponseGuard().filter(request("POST", TOKEN), res);
    ArgumentCaptor<InputStream> handed = ArgumentCaptor.forClass(InputStream.class);
    verify(res).setEntityStream(handed.capture());
    assertEquals(body, new String(handed.getValue().readAllBytes(), StandardCharsets.UTF_8));
  }

  @Test void unusableTokenResponse_isRejectedWithoutQuotingIt() {
    for (InputStream body : new InputStream[] {bytes(NUMBER), bytes("{\"access_token\":\"\"}"), null}) {
      ClientResponseContext res = response(Response.Status.OK, body);
      IOException e = assertThrows(IOException.class,
          () -> new TokenResponseGuard().filter(request("POST", TOKEN), res));
      assertEquals("token endpoint response carries no usable access_token", e.getMessage());
      assertNull(e.getCause());
      verify(res, never()).setEntityStream(any());
    }
  }

  // ───────────── ReaderInterceptor — 결합이 읽을 바이트를 판정한다 ─────────────

  private static ReaderInterceptorContext readContext(Object mark, InputStream body) throws IOException {
    ReaderInterceptorContext ctx = mock(ReaderInterceptorContext.class);
    when(ctx.getProperty(TokenResponseGuard.JUDGE_ENTITY)).thenReturn(mark);
    when(ctx.getInputStream()).thenReturn(body);
    when(ctx.proceed()).thenReturn("bound");
    return ctx;
  }

  @Test void reader_leavesUnmarkedEntitiesUntouched() throws IOException {
    for (Object mark : new Object[] {null, Boolean.FALSE, "true"}) {
      ReaderInterceptorContext ctx = readContext(mark, bytes(NUMBER));
      assertEquals("bound", new TokenResponseGuard().aroundReadFrom(ctx));
      verify(ctx, never()).getInputStream();
      verify(ctx, never()).setInputStream(any());
    }
  }

  @Test void reader_handsAUsableMarkedEntityOnByteForByte() throws IOException {
    String body = "{\"access_token\":\"AT\",\"expires_in\":300,\"refresh_token\":\"RT\",\"x\":[1]}";
    ReaderInterceptorContext ctx = readContext(Boolean.TRUE, bytes(body));
    assertEquals("bound", new TokenResponseGuard().aroundReadFrom(ctx));
    ArgumentCaptor<InputStream> handed = ArgumentCaptor.forClass(InputStream.class);
    verify(ctx).setInputStream(handed.capture());
    assertEquals(body, new String(handed.getValue().readAllBytes(), StandardCharsets.UTF_8));
  }

  @Test void reader_rejectsAnUnusableMarkedEntityWithoutQuotingIt() throws IOException {
    for (InputStream body : new InputStream[] {bytes(NUMBER), bytes("{\"access_token\":\"\"}"), null}) {
      ReaderInterceptorContext ctx = readContext(Boolean.TRUE, body);
      IOException e = assertThrows(IOException.class, () -> new TokenResponseGuard().aroundReadFrom(ctx));
      assertEquals("token endpoint response carries no usable access_token", e.getMessage());
      assertNull(e.getCause());
      verify(ctx, never()).proceed();
      verify(ctx, never()).setInputStream(any());
    }
  }

  // ───────────── 크기 상한 — 판정이 읽고 쥐는 바이트 ─────────────

  /**
   * 가드 자신의 상한 — 아래 경계 시험은 이 상수로 상한·상한+1 을 잰다. 값의 아래쪽은 서버가 받아들이는 가장 큰 토큰이 정하고
   * {@link AdminTokenResponseTest} 의 65,459 바이트 Bearer 시험이 지킨다 — 위쪽은 아래의 16 MiB 거부 시험이 지킨다.
   */
  private static final int CAP = TokenResponseGuard.MAX_BODY_BYTES;
  private static final String USABLE = "{\"access_token\":\"AT\",\"expires_in\":300}";

  /** 쓸 수 있는 토큰 뒤를 JSON 공백으로 채워 정확히 {@code size} 바이트로 — 결합에게는 여전히 쓸 수 있는 본문이다. */
  private static byte[] padded(int size) {
    byte[] body = new byte[size];
    Arrays.fill(body, (byte) ' ');
    byte[] head = USABLE.getBytes(StandardCharsets.UTF_8);
    System.arraycopy(head, 0, body, 0, head.length);
    return body;
  }

  /**
   * 끝없는 본문 — 쓸 수 있는 토큰 뒤에 JSON 공백이 끝없이 온다. 가드가 {@code limit} 바이트 너머를 <b>요청하기만 해도</b>
   * 시험을 깬다(실제 소켓이라면 그만큼 읽혔을 것이다). OOM 에 기대지 않고 「본문 크기에 비례해 읽는가」를 잰다.
   */
  private static final class EndlessBody extends InputStream {
    private final byte[] head = USABLE.getBytes(StandardCharsets.UTF_8);
    private final long limit;
    long served;
    boolean overread;

    EndlessBody(long limit) {
      this.limit = limit;
    }

    @Override public int read() {
      byte[] one = new byte[1];
      read(one, 0, 1);
      return one[0] & 0xff;
    }

    @Override public int read(byte[] b, int off, int len) {
      if (len == 0) return 0;
      if (len > limit - served) {
        overread = true;
        throw new AssertionError("가드가 " + served + " 바이트 뒤에서 " + len + " 바이트를 더 요청했다 — 상한+1 = " + limit);
      }
      for (int i = 0; i < len; i++, served++) b[off + i] = served < head.length ? head[(int) served] : (byte) ' ';
      return len;
    }
  }

  /**
   * 상한을 넘는 본문은 쓸 수 있는 토큰이 들어 있어도 쓸 수 없는 토큰과 같은 상수 메시지로 거부하고, 그 판정을 위해 상한+1
   * 바이트까지만 읽는다 — 두 진입점 모두(미디어 타입 없는 응답 필터 · 결합 직전 ReaderInterceptor).
   */
  @Test void bodyAboveTheCap_isRejectedWithoutReadingPastCapPlusOne() throws IOException {
    EndlessBody raw = new EndlessBody(CAP + 1L);
    ClientResponseContext res = response(Response.Status.OK, raw);
    IOException filtered = assertThrows(IOException.class,
        () -> new TokenResponseGuard().filter(request("POST", TOKEN), res));
    assertEquals("token endpoint response carries no usable access_token", filtered.getMessage());
    assertNull(filtered.getCause());
    assertFalse(raw.overread);
    assertEquals(CAP + 1L, raw.served, "넘침을 알아챌 한 바이트까지 읽어야 한다");
    verify(res, never()).setEntityStream(any());

    EndlessBody decoded = new EndlessBody(CAP + 1L);
    ReaderInterceptorContext ctx = readContext(Boolean.TRUE, decoded);
    IOException read = assertThrows(IOException.class, () -> new TokenResponseGuard().aroundReadFrom(ctx));
    assertEquals("token endpoint response carries no usable access_token", read.getMessage());
    assertNull(read.getCause());
    assertFalse(decoded.overread);
    assertEquals(CAP + 1L, decoded.served, "넘침을 알아챌 한 바이트까지 읽어야 한다");
    verify(ctx, never()).proceed();
    verify(ctx, never()).setInputStream(any());
  }

  /**
   * 거부 전에 스트림을 닫는다 — 닫기의 실패는 버리고 거부는 그대로다(두 진입점). 실제 연결에서 닫기는 읽지 않은 나머지를
   * 비우고(HttpCore), 응답 필터가 거부한 뒤 RESTEasy 가 try/catch 없이 닫으면 그 비우기의 실패가 이 거부를 대신해 걸러지지
   * 않은 사슬로 나갔다 — 먼저 닫아 두면 뒤의 닫기는 아무것도 하지 않는다(실제 연결로는 {@code AdminTokenResponseTest} 가 잰다).
   */
  @Test void bodyAboveTheCap_isClosedBeforeTheRejection_aCloseFaultDoesNotReplaceIt() throws IOException {
    FaultyCloseBody raw = new FaultyCloseBody();
    ClientResponseContext res = response(Response.Status.OK, raw);
    IOException filtered = assertThrows(IOException.class,
        () -> new TokenResponseGuard().filter(request("POST", TOKEN), res));
    assertEquals("token endpoint response carries no usable access_token", filtered.getMessage());
    assertNull(filtered.getCause());
    assertEquals(0, filtered.getSuppressed().length);
    assertEquals(1, raw.closes, "거부 전에 스트림을 한 번 닫아야 한다");
    verify(res, never()).setEntityStream(any());

    FaultyCloseBody decoded = new FaultyCloseBody();
    ReaderInterceptorContext ctx = readContext(Boolean.TRUE, decoded);
    IOException read = assertThrows(IOException.class, () -> new TokenResponseGuard().aroundReadFrom(ctx));
    assertEquals("token endpoint response carries no usable access_token", read.getMessage());
    assertNull(read.getCause());
    assertEquals(0, read.getSuppressed().length);
    assertEquals(1, decoded.closes, "거부 전에 스트림을 한 번 닫아야 한다");
    verify(ctx, never()).proceed();
  }

  /** 끝없는 본문({@link EndlessBody}) — 닫으면 연결 해제의 실패처럼 응답 바이트를 인용하는 IOException 을 던지고, 횟수를 센다. */
  private static final class FaultyCloseBody extends InputStream {
    private final EndlessBody body = new EndlessBody(CAP + 1L);
    int closes;

    @Override public int read() {
      return body.read();
    }

    @Override public int read(byte[] b, int off, int len) {
      return body.read(b, off, len);
    }

    @Override public void close() throws IOException {
      closes++;
      throw new IOException("Bad chunk header: \"refresh_token\":\"ZadminRT-0123456789abcdef\"");
    }
  }

  /** 경계 — 정확히 상한인 본문은 바이트 그대로 넘기고, 한 바이트 더 크면 거부한다(두 진입점). */
  @Test void bodyOfExactlyTheCap_isHandedOn_oneByteMoreIsRejected() throws IOException {
    byte[] atCap = padded(CAP);
    ClientResponseContext res = response(Response.Status.OK, new ByteArrayInputStream(atCap));
    new TokenResponseGuard().filter(request("POST", TOKEN), res);
    ArgumentCaptor<InputStream> handed = ArgumentCaptor.forClass(InputStream.class);
    verify(res).setEntityStream(handed.capture());
    assertArrayEquals(atCap, handed.getValue().readAllBytes());

    ReaderInterceptorContext ctx = readContext(Boolean.TRUE, new ByteArrayInputStream(atCap));
    assertEquals("bound", new TokenResponseGuard().aroundReadFrom(ctx));
    ArgumentCaptor<InputStream> read = ArgumentCaptor.forClass(InputStream.class);
    verify(ctx).setInputStream(read.capture());
    assertArrayEquals(atCap, read.getValue().readAllBytes());

    ClientResponseContext over = response(Response.Status.OK, new ByteArrayInputStream(padded(CAP + 1)));
    IOException e = assertThrows(IOException.class, () -> new TokenResponseGuard().filter(request("POST", TOKEN), over));
    assertEquals("token endpoint response carries no usable access_token", e.getMessage());
    verify(over, never()).setEntityStream(any());
    ReaderInterceptorContext overRead = readContext(Boolean.TRUE, new ByteArrayInputStream(padded(CAP + 1)));
    e = assertThrows(IOException.class, () -> new TokenResponseGuard().aroundReadFrom(overRead));
    assertEquals("token endpoint response carries no usable access_token", e.getMessage());
    verify(overRead, never()).proceed();
  }

  /**
   * 쥐는 메모리도 본문 크기와 무관하다 — 16 MiB 본문을 거부하는 동안 이 스레드가 할당한 바이트가 상한의 세 배 안이다. 상한+1
   * 바이트를 읽는 {@code readNBytes(int)} 는 읽은 조각(합 상한+1)과 그것을 이은 배열(상한+1)을 할당한다 — 두 배이고, 남은 한
   * 배가 목·예외의 몫이다. 본문을 통째로 읽으면({@code readAllBytes}) 본문 전체와 그 사본이다(32 MiB 넘게). HotSpot 의 스레드
   * 할당 계수기로 잰다 — OOM 에 기대지 않는다.
   */
  @Test void rejectingAHugeBody_allocatesIndependentlyOfItsSize() throws IOException {
    com.sun.management.ThreadMXBean threads = allocationCounter();
    int huge = 16 << 20;
    TokenResponseGuard guard = new TokenResponseGuard();
    ClientRequestContext req = request("POST", TOKEN);
    judge(guard, req, response(Response.Status.OK, new SizedBody(huge))); // 데우기 — 클래스 로딩의 할당을 재지 않는다
    ClientResponseContext res = response(Response.Status.OK, new SizedBody(huge));
    long before = threads.getCurrentThreadAllocatedBytes();
    IOException rejected = judge(guard, req, res);
    long allocated = threads.getCurrentThreadAllocatedBytes() - before;
    long limit = 3L * (CAP + 1);
    System.out.println("[TokenResponseGuardTest 할당] " + huge + " 바이트 본문 거부 → " + allocated + " 바이트 (한도 " + limit + ")");
    assertTrue(allocated < limit, () -> huge + " 바이트 본문 하나를 판정하며 " + allocated + " 바이트를 할당했다");
    assertNotNull(rejected, "상한을 넘는 본문을 넘겼다");
  }

  /**
   * 작은 본문은 작게 할당한다 — 상한만 한 버퍼를 본문마다 미리 잡지 않는다(그러면 토큰 요청 하나하나가 상한 1 MiB 를 할당한다).
   * 쓸 수 있는 약 2 KiB 토큰 응답 하나를 판정하며 이 스레드가 할당한 바이트가 64 KiB 안이다 — {@code readNBytes(int)} 는 JDK 의
   * 기본 조각(17: 8 KiB · 21: 16 KiB)으로 읽은 만큼만 잡는다. 먼저 한 번 판정해 데운다(Jackson 의 재활용 버퍼·기호표와 목의 첫
   * 할당을 재지 않는다).
   */
  @Test void judgingASmallBody_allocatesInProportionToIt() throws IOException {
    com.sun.management.ThreadMXBean threads = allocationCounter();
    byte[] small = smallTokenResponse();
    TokenResponseGuard guard = new TokenResponseGuard();
    ClientRequestContext req = request("POST", TOKEN);
    judge(guard, req, response(Response.Status.OK, new ByteArrayInputStream(small))); // 데우기
    ClientResponseContext res = response(Response.Status.OK, new ByteArrayInputStream(small));
    long before = threads.getCurrentThreadAllocatedBytes();
    IOException rejected = judge(guard, req, res);
    long allocated = threads.getCurrentThreadAllocatedBytes() - before;
    long limit = 64 * 1024;
    System.out.println("[TokenResponseGuardTest 할당] " + small.length + " 바이트 본문 통과 → " + allocated + " 바이트 (한도 " + limit + ")");
    assertNull(rejected, "쓸 수 있는 작은 본문을 거부했다");
    assertTrue(allocated < limit, () -> small.length + " 바이트 본문 하나를 판정하며 " + allocated + " 바이트를 할당했다");
  }

  /** HotSpot 의 스레드 할당 계수기 — 없는 JVM 에서는 할당 시험을 건너뛴다. */
  private static com.sun.management.ThreadMXBean allocationCounter() {
    java.lang.management.ThreadMXBean bean = ManagementFactory.getThreadMXBean();
    assumeTrue(bean instanceof com.sun.management.ThreadMXBean, "스레드 할당 계수기가 없는 JVM");
    com.sun.management.ThreadMXBean threads = (com.sun.management.ThreadMXBean) bean;
    assumeTrue(threads.isThreadAllocatedMemorySupported() && threads.isThreadAllocatedMemoryEnabled());
    return threads;
  }

  /** 쓸 수 있는 약 2 KiB 토큰 응답 — Keycloak client_credentials 응답의 모양(토큰 자리는 가짜 문자다). */
  private static byte[] smallTokenResponse() {
    return ("{\"access_token\":\"" + "A".repeat(1_900) + "\",\"expires_in\":300,\"refresh_expires_in\":0,"
        + "\"token_type\":\"Bearer\",\"not-before-policy\":0,\"scope\":\"profile email\"}").getBytes(StandardCharsets.UTF_8);
  }

  /** 응답 필터 판정 하나 — 거부면 그 예외를, 통과면 null 을 돌려준다(할당을 재는 구간에 단언을 두지 않는다). */
  private static IOException judge(TokenResponseGuard guard, ClientRequestContext req, ClientResponseContext res) {
    try {
      guard.filter(req, res);
      return null;
    } catch (IOException e) {
      return e;
    }
  }

  /** 정해진 크기의 본문(쓸 수 있는 토큰 + 공백) — 배경 배열 없이 만들어 시험 자신의 할당을 재지 않는다. */
  private static final class SizedBody extends InputStream {
    private final byte[] head = USABLE.getBytes(StandardCharsets.UTF_8);
    private final long size;
    private long pos;

    SizedBody(long size) {
      this.size = size;
    }

    @Override public int read() {
      byte[] one = new byte[1];
      return read(one, 0, 1) < 0 ? -1 : one[0] & 0xff;
    }

    @Override public int read(byte[] b, int off, int len) {
      if (len == 0) return 0;
      if (pos >= size) return -1;
      int n = (int) Math.min(len, size - pos);
      for (int i = 0; i < n; i++, pos++) b[off + i] = pos < head.length ? head[(int) pos] : (byte) ' ';
      return n;
    }
  }

  /**
   * 배선 — admin 의 JAX-RS 클라이언트에 두 계약으로 등록돼 있어야 한다(TokenManager 의 토큰 요청이 그 클라이언트로 나간다).
   * ReaderInterceptor 는 오름차순으로 돌므로 가장 큰 우선순위 값이 결합 바로 앞이다 — gzip 해제({@code Priorities.ENTITY_CODER})
   * 보다 작아지면 원시 바이트를 판정하게 된다.
   */
  @Test void timeoutClient_registersTheGuard() {
    KeycloakConfig config = KeycloakConfig.builder().serverUrl("https://kc.example.com").realm("r").clientId("app")
        .clientSecret("s3cr3t".toCharArray()).build();
    try (Client client = AdminClient.buildTimeoutClient(config)) {
      assertTrue(client.getConfiguration().isRegistered(TokenResponseGuard.class));
      Map<Class<?>, Integer> contracts = client.getConfiguration().getContracts(TokenResponseGuard.class);
      assertEquals(Priorities.USER, contracts.get(ClientResponseFilter.class));
      assertEquals(Integer.MAX_VALUE, contracts.get(ReaderInterceptor.class));
    }
  }
}
