// measurement only — not for merge (task n3 · registry admin-created-id-non-ascii-location).
//
// What id does AdminClient.users().create return when the 201's Location carries a byte that is not visible ASCII? A raw
// ServerSocket answers the admin-client's token grant with a token and the create with 201 +
// `Location: http://127.0.0.1:<port>/admin/realms/it-realm/users/<id bytes>` for `abc` (control), `ab` 0xE9 `cd` (Latin-1
// obs-text) and `ab` 0xC3 0xA9 `cd` (UTF-8 for U+00E9). Per case: the bytes a raw socket reads off the wire (WIRE), what the
// JDK HttpClient hands back as the header (CLIENT — for comparison; the SDK goes through RESTEasy + Apache HttpClient 4),
// and what the SDK returns (ID).
//
// Run: N3_OUT=<file> mvn -f java/pom.xml test -pl keycloak-sdk-admin -am -Dtest=zz_n3_location_measureTest
//      -Dsurefire.failIfNoSpecifiedTests=false
package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import io.github.xzawed.keycloak.core.KeycloakConfig;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.CopyOnWriteArrayList;
import org.junit.jupiter.api.Test;
import org.keycloak.representations.idm.UserRepresentation;

class zz_n3_location_measureTest {
  private static final String USERS = "/admin/realms/it-realm/users";

  private final List<String> seen = new CopyOnWriteArrayList<>();
  private volatile byte[] location = new byte[0];

  private static int indexOf(byte[] hay, byte[] needle, int from) {
    outer:
    for (int i = from; i + needle.length <= hay.length; i++) {
      for (int j = 0; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) {
          continue outer;
        }
      }
      return i;
    }
    return -1;
  }

  private static byte[] concat(byte[]... parts) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    for (byte[] p : parts) {
      out.writeBytes(p);
    }
    return out.toByteArray();
  }

  private static String hex(byte[] b) {
    StringBuilder sb = new StringBuilder();
    for (byte x : b) {
      if (sb.length() > 0) {
        sb.append(' ');
      }
      sb.append(HexFormat.of().withUpperCase().toHexDigits(x));
    }
    return sb.toString();
  }

  /** A Java string with every char outside printable ASCII escaped, then its code points. */
  private static String show(String s) {
    if (s == null) {
      return "null";
    }
    StringBuilder esc = new StringBuilder("\"");
    List<String> cps = new ArrayList<>();
    s.codePoints().forEach(cp -> {
      esc.append(cp >= 0x20 && cp < 0x7F ? Character.toString(cp) : String.format(Locale.ROOT, "\\u%04X", cp));
      cps.add(String.format(Locale.ROOT, "U+%04X", cp));
    });
    return esc.append("\" cps=[").append(String.join(",", cps)).append(']').toString();
  }

  private static String tail(String s) {
    return s == null ? null : s.substring(s.lastIndexOf('/') + 1);
  }

  private void handle(Socket conn) {
    try (conn) {
      InputStream in = conn.getInputStream();
      ByteArrayOutputStream buf = new ByteArrayOutputStream();
      byte[] chunk = new byte[4096];
      int headEnd;
      while ((headEnd = indexOf(buf.toByteArray(), "\r\n\r\n".getBytes(StandardCharsets.US_ASCII), 0)) < 0) {
        int n = in.read(chunk);
        if (n < 0) {
          return;
        }
        buf.write(chunk, 0, n);
      }
      byte[] all = buf.toByteArray();
      String[] lines = new String(all, 0, headEnd, StandardCharsets.ISO_8859_1).split("\r\n");
      String[] first = lines[0].split(" ");
      String method = first[0];
      String path = first.length > 1 ? first[1] : "";
      int length = 0;
      boolean chunked = false;
      for (int i = 1; i < lines.length; i++) {
        int colon = lines[i].indexOf(':');
        if (colon < 0) {
          continue;
        }
        String name = lines[i].substring(0, colon).trim().toLowerCase(Locale.ROOT);
        String value = lines[i].substring(colon + 1).trim();
        if (name.equals("content-length")) {
          length = Integer.parseInt(value);
        } else if (name.equals("transfer-encoding") && value.toLowerCase(Locale.ROOT).contains("chunked")) {
          chunked = true;
        }
      }
      int have = all.length - (headEnd + 4);
      if (chunked) {
        while (indexOf(buf.toByteArray(), "0\r\n\r\n".getBytes(StandardCharsets.US_ASCII), headEnd + 4) < 0) {
          int n = in.read(chunk);
          if (n < 0) {
            break;
          }
          buf.write(chunk, 0, n);
        }
      } else {
        while (have < length) {
          int n = in.read(chunk);
          if (n < 0) {
            break;
          }
          have += n;
        }
      }
      seen.add(method + " " + path);
      byte[] answer;
      if (path.endsWith("/protocol/openid-connect/token")) {
        String json = "{\"access_token\":\"at-n3\",\"token_type\":\"Bearer\",\"expires_in\":300}";
        answer = ("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + json.length()
            + "\r\nConnection: close\r\n\r\n" + json).getBytes(StandardCharsets.US_ASCII);
      } else if (method.equals("POST") && path.replaceAll("/$", "").equals(USERS)) {
        answer = concat("HTTP/1.1 201 Created\r\nLocation: ".getBytes(StandardCharsets.US_ASCII), location,
            "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
      } else {
        answer = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".getBytes(StandardCharsets.US_ASCII);
      }
      OutputStream out = conn.getOutputStream();
      out.write(answer);
      out.flush();
    } catch (IOException e) {
      // the client went away — nothing to answer
    }
  }

  private static byte[] wireProbe(int port) throws IOException {
    try (Socket s = new Socket(InetAddress.getLoopbackAddress(), port)) {
      s.getOutputStream().write(("POST " + USERS + " HTTP/1.1\r\nHost: 127.0.0.1:" + port
          + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
      byte[] raw = s.getInputStream().readAllBytes();
      byte[] marker = "\r\nLocation: ".getBytes(StandardCharsets.US_ASCII);
      int at = indexOf(raw, marker, 0);
      if (at < 0) {
        return new byte[0];
      }
      int start = at + marker.length;
      int end = indexOf(raw, "\r\n".getBytes(StandardCharsets.US_ASCII), start);
      return java.util.Arrays.copyOfRange(raw, start, end);
    }
  }

  @Test
  void measure() throws Exception {
    String outPath = System.getenv("N3_OUT");
    assumeTrue(outPath != null && !outPath.isEmpty(), "measurement only — set N3_OUT");
    try (ServerSocket server = new ServerSocket(0, 50, InetAddress.getLoopbackAddress())) {
      Thread acceptor = new Thread(() -> {
        while (!server.isClosed()) {
          try {
            Socket conn = server.accept();
            new Thread(() -> handle(conn)).start();
          } catch (IOException e) {
            return;
          }
        }
      });
      acceptor.setDaemon(true);
      acceptor.start();
      int port = server.getLocalPort();
      String base = "http://127.0.0.1:" + port;
      List<String> out = new ArrayList<>();
      out.add("ENV|java=" + System.getProperty("java.version") + "|keycloak-admin-client="
          + org.keycloak.admin.client.Keycloak.class.getPackage().getImplementationVersion()
          + "|resteasy=" + org.jboss.resteasy.client.jaxrs.ResteasyClientBuilder.class.getPackage().getImplementationVersion()
          + "|httpclient=" + org.apache.http.client.HttpClient.class.getPackage().getImplementationVersion()
          + "|create=AdminClient.users().create");
      out.add("HEADER|sdk|lane|case|field|value");
      String[][] names = {{"ascii-control"}, {"latin1-0xE9"}, {"utf8-0xC3A9"}};
      byte[][] ids = {
        "abc".getBytes(StandardCharsets.US_ASCII),
        {'a', 'b', (byte) 0xE9, 'c', 'd'},
        {'a', 'b', (byte) 0xC3, (byte) 0xA9, 'c', 'd'},
      };
      KeycloakConfig config = KeycloakConfig.builder().serverUrl(base).realm("it-realm").clientId("it-client")
          .clientSecret("dummy-secret".toCharArray()).connectTimeout(Duration.ofSeconds(5))
          .readTimeout(Duration.ofSeconds(5)).build();
      for (int i = 0; i < ids.length; i++) {
        String name = names[i][0];
        byte[] prefix = (base + USERS + "/").getBytes(StandardCharsets.US_ASCII);
        location = concat(prefix, ids[i]);
        byte[] got = wireProbe(port);
        out.add("WIRE|java|-|" + name + "|location=<base>/admin/realms/it-realm/users/+[" + hex(ids[i])
            + "]|raw_socket_read_equals_sent=" + java.util.Arrays.equals(got, location) + "|id_bytes_on_wire="
            + hex(java.util.Arrays.copyOfRange(got, Math.min(prefix.length, got.length), got.length)));
        try {
          HttpResponse<Void> r = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).build()
              .send(HttpRequest.newBuilder(URI.create(base + USERS)).POST(HttpRequest.BodyPublishers.ofString("{}")).build(),
                  HttpResponse.BodyHandlers.discarding());
          out.add("CLIENT|java|java.net.http.HttpClient(comparison)|" + name + "|status=" + r.statusCode()
              + "|headers.firstValue(\"Location\").after_last_slash=" + show(tail(r.headers().firstValue("Location").orElse(null))));
        } catch (IOException e) {
          out.add("CLIENT|java|java.net.http.HttpClient(comparison)|" + name + "|threw " + e.getClass().getName() + ": " + e.getMessage());
        }
        seen.clear();
        String result;
        try (AdminClient admin = new AdminClient(config)) {
          UserRepresentation user = new UserRepresentation();
          user.setUsername("n3-user");
          result = "Ok(" + show(admin.users().create(user)) + ")";
        } catch (Exception e) {
          Throwable c = e.getCause();
          result = "Err(" + e.getClass().getName() + ": " + e.getMessage()
              + (c == null ? "" : " cause=" + c.getClass().getName() + ": " + c.getMessage()) + ")";
        }
        out.add("ID|java|AdminClient.users().create|" + name + "|" + result.replace('|', '/').replace('\n', ' ')
            + "|requests=" + String.join(",", seen));
      }
      Files.writeString(Path.of(outPath), String.join("\n", out) + "\n", StandardCharsets.UTF_8);
      assertEquals(3, out.stream().filter(l -> l.startsWith("ID|")).count());
    }
  }
}
