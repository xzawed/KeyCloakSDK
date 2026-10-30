package io.github.xzawed.keycloak.core;

/**
 * Size caps this SDK applies when it reads response bodies.
 *
 * <p>auth and admin are modules that do not know each other (§4), so a value both of them use is declared only
 * once, here in core — there is no second place that defines it.
 */
public final class ResponseLimits {
  /**
   * Response bodies from the token endpoint (client_credentials, refresh_token and authorization_code grants — the
   * auth lane's and the admin lane's own token grants), introspection and logout are accepted only up to this many
   * bytes — the same holds for error-status bodies. Beyond it, the call does not request the rest and fails with
   * {@link io.github.xzawed.keycloak.core.exception.KeycloakTransportException}. On a transport that decodes the
   * content coding (admin's RESTEasy gzip decompression), only the 2xx body that the binding reads is counted in
   * decoded bytes — an error-status body is counted in received (content-coded) bytes (a response filter that
   * measures before decoding — {@code TokenResponseGuard}). ⚠️ What this value bounds is the <b>body</b> bytes the
   * SDK requests and holds (up to this value + 1) — the response framing (headers, chunk-size lines, trailers) is
   * bounded by {@link #MAX_LINE_LENGTH} and {@link #MAX_HEADER_COUNT}.
   *
   * <p>It is 16 times the longest Bearer that Keycloak 26.6 accepts with its default settings (65,459 bytes, measured
   * with start-dev on 2026-10-03 — one byte longer gets HTTP 431), so this cap does not refuse a token the server
   * accepts (operators can raise that header limit — hence the large margin). Even so, the SDK does not hold an
   * endless body from a hostile or broken endpoint beyond this — on overflow, both lanes drop the connection without
   * reading the rest of the body (for HTTPS, JSSE discards the bytes that already arrived as it closes — auth through
   * its transport, admin through the abort handle its engine attaches). ⚠️ Do not borrow the JWKS response cap
   * (Nimbus 51,200) — it refused usable tokens of large deployments. It is not applied to the success bodies of admin
   * REST responses (user lists and the like) — they are legitimately large. Their error bodies are held only up to
   * this value (they serve diagnostics only — the admin engine borrows this value and drops the connection without
   * reading the rest beyond it).
   *
   * <p>⚠️ All nine languages move this value together, and a cross-language guard reads this literal — keep it a bare
   * decimal literal, not an expression ({@code 1 << 20}).
   */
  public static final int MAX_TOKEN_RESPONSE_BYTES = 1_048_576;

  /**
   * Maximum bytes of one line in the response <b>framing</b> — status line, header lines, chunk-size lines
   * (extensions included) and trailer lines. The auth lane (token, introspection, logout, JWKS) and the admin lane
   * (RESTEasy's HttpCore) both apply it. Beyond it, the call is a transport failure.
   *
   * <p>Why: the body cap counts only the body. The JDK held the trailers after a short chunked body without a limit
   * (32 MiB of 4 KiB lines → token accepted, 170 MB for one call; one 1 MiB line → 17.2 GB), and HttpCore has no
   * default limit on lines or header count (-1) — measured in {@code ResponseFramingBoundsTest} and
   * {@code AdminResponseFramingTest}. The longest response header line of Keycloak 26.6.4 was 85 bytes (measured on
   * token, introspection, logout, JWKS and discovery).
   */
  public static final int MAX_LINE_LENGTH = 8192;

  /**
   * Maximum number of fields one response header section (the head or the trailer) may hold — applied together with
   * {@link #MAX_LINE_LENGTH}. Keycloak 26.6.4's responses had at most 9 (same measurement).
   */
  public static final int MAX_HEADER_COUNT = 100;

  private ResponseLimits() {}
}
