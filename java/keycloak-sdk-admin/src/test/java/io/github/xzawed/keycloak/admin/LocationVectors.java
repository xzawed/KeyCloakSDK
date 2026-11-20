package io.github.xzawed.keycloak.admin;

import jakarta.ws.rs.core.Response;
import java.net.URI;
import java.util.List;
import java.util.stream.Stream;
import org.junit.jupiter.params.provider.Arguments;

/**
 * 아홉 SDK 가 같이 쓰는 {@code Location} 벡터(등록부 admin-create-relative-location) — {@code {base}} 는 서버, {@code {path}} 는
 * 보낸 컬렉션 경로, {@code {coll}} 은 그 마지막 조각, {@code {other}} 는 다른 컬렉션. 셋째는 create 가 돌려줄 id 이고 null 이면 id
 * 없음(없을 때의 그 답 — null)이다. id 는 201 의 {@code Location} 을 요청 URL 에 대해 푼(RFC 9110 §10.2.2) 경로의 마지막 조각이고, 그 앞
 * 조각은 보낸 컬렉션이어야 한다.
 */
final class LocationVectors {
  private LocationVectors() {}

  /** 요청이 가는 서버 — 컬렉션은 {@code {BASE}/admin/realms/r/{coll}}. */
  static final String BASE = "https://kc.example.com";

  /** {@code collection} 의 create 가 가는 URL — 파사드가 {@code Location} 을 이것에 대해 푼다. */
  static URI sentTo(String collection) {
    return URI.create(BASE + "/admin/realms/r/" + collection);
  }

  private static final List<String[]> VECTORS = List.of(
      new String[] {"L1 absolute", "{base}{path}/abc-123", "abc-123"},
      new String[] {"L2 path-absolute", "{path}/abc-123", "abc-123"},
      new String[] {"L3 relative path", "{coll}/abc-123", "abc-123"},
      new String[] {"L4 relative", "abc-123", null},
      new String[] {"L5 another host", "https://internal.example:8443{path}/abc-123", "abc-123"},
      new String[] {"L6 gateway prefix", "https://gw.example/kc{path}/abc-123", "abc-123"},
      new String[] {"L7 query and fragment", "{base}{path}/abc-123?x=1#f", "abc-123"},
      new String[] {"L8 trailing slash", "{base}{path}/abc-123/", "abc-123"},
      new String[] {"L9 another collection", "../{other}/abc-123", null},
      new String[] {"L10 root", "/", null},
      new String[] {"L11 empty value", "", null},
      new String[] {"L12 absent", null, null},
      new String[] {"L13 percent-encoded", "{base}{path}/abc%20123", "abc%20123"});

  /** {@code collection} 에 보낸 create 의 벡터 — {@code all} 이면 열셋, 아니면 L1 · L2 · L4 · L7 · L9. (이름, Location, id). */
  static Stream<Arguments> of(String collection, boolean all) {
    String path = "/admin/realms/r/" + collection;
    String other = collection.equals("groups") ? "users" : "groups";
    return VECTORS.stream()
        .filter(v -> all || List.of("L1", "L2", "L4", "L7", "L9").contains(v[0].split(" ")[0]))
        .map(v -> Arguments.of(v[0], v[1] == null ? null : v[1].replace("{base}", BASE).replace("{path}", path)
            .replace("{coll}", collection).replace("{other}", other), v[2]));
  }

  /** 그 {@code Location} 을 단 201 — null 이면 머리가 없다. */
  static Response created(String location) {
    Response.ResponseBuilder created = Response.status(201);
    return (location == null ? created : created.header("Location", location)).build();
  }
}
