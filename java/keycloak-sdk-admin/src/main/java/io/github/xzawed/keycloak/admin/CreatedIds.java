package io.github.xzawed.keycloak.admin;

import jakarta.ws.rs.core.HttpHeaders;
import jakarta.ws.rs.core.Response;
import java.net.URI;
import java.net.URISyntaxException;
import java.util.Objects;
import org.keycloak.admin.client.CreatedResponseUtil;

/**
 * The id a create's answer names — registry admin-create-relative-location, the same rule in all nine SDKs. admin-client's
 * {@link CreatedResponseUtil#getCreatedId} takes everything after the last {@code /} of the decoded path of the
 * {@code Location} as it came: a relative one is not resolved, another collection's id comes back as this one's, a trailing
 * {@code /} gives an empty id, and {@code %20} comes back decoded.
 */
final class CreatedIds {
  private CreatedIds() {}

  /**
   * The {@code Location} value (SP and HTAB trimmed at both ends) resolved against {@code sentTo} — the URL the create was
   * sent to (RFC 9110 §10.2.2 — a relative one too) — then the last segment of the resolved path as it came (not decoded;
   * one trailing {@code /} ignored), whose segment before it must be the collection the create posted to. Never the query
   * or the fragment. Null — no id, as for an answer without a {@code Location} — when the value is absent, empty or does not
   * parse, or the resolved path names no id in that collection (another collection's id included). An answer other than
   * 201 fails as admin-client's does.
   */
  static String of(Response response, URI sentTo) {
    if (!response.getStatusInfo().equals(Response.Status.CREATED)) {
      return CreatedResponseUtil.getCreatedId(response); // throws, as it always did
    }
    String value = trimSpHtab(Objects.toString(response.getHeaderString(HttpHeaders.LOCATION), ""));
    if (value.isEmpty()) {
      return null;
    }
    URI resolved;
    try {
      resolved = sentTo.resolve(new URI(value));
    } catch (URISyntaxException e) {
      return null;
    }
    // 불투명 URI(`mailto:x`)의 경로는 null 이다 — 조각이 없다
    String[] named = lastSegments(Objects.toString(resolved.getRawPath(), ""));
    String id = named[1];
    return !id.isEmpty() && lastSegments(sentTo.getRawPath())[1].equals(named[0]) ? id : null;
  }

  /**
   * {@code s} without SP and HTAB at either end — a loop, not a regex: {@code [ \t]+$} retries from every position of a long
   * inner run and goes quadratic.
   */
  private static String trimSpHtab(String s) {
    int start = 0;
    int end = s.length();
    while (start < end && (s.charAt(start) == ' ' || s.charAt(start) == '\t')) {
      start++;
    }
    while (end > start && (s.charAt(end - 1) == ' ' || s.charAt(end - 1) == '\t')) {
      end--;
    }
    return s.substring(start, end);
  }

  /** The last two segments of a URI path, one trailing {@code /} ignored — the first null when it has one only. */
  private static String[] lastSegments(String path) {
    String p = path.endsWith("/") ? path.substring(0, path.length() - 1) : path;
    int last = p.lastIndexOf('/');
    if (last < 0) {
      return new String[] {null, p};
    }
    String head = p.substring(0, last);
    return new String[] {head.substring(head.lastIndexOf('/') + 1), p.substring(last + 1)};
  }
}
