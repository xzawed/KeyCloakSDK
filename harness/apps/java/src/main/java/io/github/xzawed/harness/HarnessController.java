package io.github.xzawed.harness;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.github.xzawed.keycloak.KeycloakClient;
import io.github.xzawed.keycloak.auth.AuthorizationUrlRequest;
import io.github.xzawed.keycloak.auth.IntrospectionResult;
import io.github.xzawed.keycloak.auth.ValidatedToken;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.TokenSet;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import io.github.xzawed.keycloak.core.exception.KeycloakConflictException;
import io.github.xzawed.keycloak.core.exception.KeycloakForbiddenException;
import io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException;
import io.github.xzawed.keycloak.core.exception.TokenValidationException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.keycloak.representations.idm.ClientRepresentation;
import org.keycloak.representations.idm.GroupRepresentation;
import org.keycloak.representations.idm.RealmRepresentation;
import org.keycloak.representations.idm.RoleRepresentation;
import org.keycloak.representations.idm.UserRepresentation;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HarnessController {
    private final KeycloakClient kc;
    private final KeycloakConfig config;
    private final HttpClient http = HttpClient.newHttpClient();
    private final ObjectMapper mapper = new ObjectMapper();
    // 단일 프로세스 데모 하네스 전용 서버측 refresh 토큰 보관(logout/refresh 자동화용).
    private volatile String lastRefreshToken;

    public HarnessController(KeycloakClient kc, KeycloakConfig config) {
        this.kc = kc;
        this.config = config;
    }

    // Map.of는 null 값을 금지하므로 null 허용 맵을 만든다.
    private static ResponseEntity<Object> fail(int code, String msg) {
        Map<String, Object> m = new HashMap<>();
        m.put("error", msg);
        return ResponseEntity.status(code).body(m);
    }

    // id/username이 null이어도(이론상) NPE 대신 JSON null로 저하 — 다른 4언어와 동형.
    private static Map<String, Object> idUser(UserRepresentation u) {
        Map<String, Object> m = new HashMap<>();
        m.put("id", u.getId());
        m.put("username", u.getUsername());
        return m;
    }

    @GetMapping("/healthz")
    public Map<String, String> healthz() {
        return Map.of("status", "ok");
    }

    @PostMapping("/token")
    public ResponseEntity<Object> token() {
        try {
            TokenSet ts = kc.auth().clientCredentialsToken();
            // Java TokenSet은 getExpiresAt():Instant만 → expiresIn 파생
            long expiresIn = Math.max(0, ts.getExpiresAt().getEpochSecond() - Instant.now().getEpochSecond());
            Map<String, Object> m = new HashMap<>();
            m.put("tokenType", ts.getTokenType());
            m.put("expiresIn", expiresIn);
            return ResponseEntity.ok(m);
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @PostMapping("/validate")
    public ResponseEntity<Object> validate(@RequestBody Map<String, String> body) {
        String tok = body.get("token");
        if (tok == null || tok.isEmpty()) {
            return fail(400, "token required");
        }
        try {
            ValidatedToken vt = kc.auth().validate(tok);
            Map<String, Object> m = new HashMap<>();
            m.put("subject", vt.getSubject());
            m.put("audience", vt.getAudience());
            m.put("issuer", vt.getIssuer());
            m.put("expiresAt", vt.getExpiresAt().getEpochSecond());
            return ResponseEntity.ok(m);
        } catch (TokenValidationException | KeycloakAuthException e) {
            return fail(401, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @PostMapping("/introspect")
    public ResponseEntity<Object> introspect(@RequestBody Map<String, String> body) {
        String tok = body.get("token");
        if (tok == null || tok.isEmpty()) {
            return fail(400, "token required");
        }
        try {
            IntrospectionResult ir = kc.auth().introspect(tok);
            Map<String, Object> m = new HashMap<>();
            m.put("active", ir.isActive());
            m.put("username", ir.getUsername().orElse(null));
            m.put("clientId", ir.getClientId().orElse(null));
            return ResponseEntity.ok(m);
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    // ROPC(Resource Owner Password Credentials)는 SDK 표면에 없다(SDK 표면 불변 원칙 —
    // task 브리프 채택 경로). 하네스 앱이 Keycloak 토큰 엔드포인트로 직접 POST한다(8개 앱 동일 패턴).
    @PostMapping("/token/password")
    public ResponseEntity<Object> tokenPassword(@RequestBody Map<String, String> body) {
        try {
            String form = "grant_type=" + URLEncoder.encode("password", StandardCharsets.UTF_8)
                + "&client_id=" + URLEncoder.encode(config.getClientId(), StandardCharsets.UTF_8)
                + "&client_secret=" + URLEncoder.encode(new String(config.getClientSecret()), StandardCharsets.UTF_8)
                + "&username=" + URLEncoder.encode(body.get("username"), StandardCharsets.UTF_8)
                + "&password=" + URLEncoder.encode(body.get("password"), StandardCharsets.UTF_8);
            HttpRequest req = HttpRequest.newBuilder()
                .uri(URI.create(config.getServerUrl() + "/realms/" + config.getRealm()
                    + "/protocol/openid-connect/token"))
                .header("Content-Type", "application/x-www-form-urlencoded")
                .POST(HttpRequest.BodyPublishers.ofString(form))
                .build();
            HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
            if (resp.statusCode() < 200 || resp.statusCode() >= 300) {
                return fail(401, "ROPC(password) grant failed: HTTP " + resp.statusCode());
            }
            @SuppressWarnings("unchecked")
            Map<String, Object> tokenBody = mapper.readValue(resp.body(), Map.class);
            String refreshToken = (String) tokenBody.get("refresh_token");
            lastRefreshToken = refreshToken;
            Map<String, Object> m = new HashMap<>();
            m.put("tokenType", tokenBody.get("token_type"));
            m.put("expiresIn", tokenBody.get("expires_in"));
            m.put("hasRefresh", refreshToken != null);
            return ResponseEntity.ok(m);
        } catch (Exception e) {
            return fail(401, e.getMessage());
        }
    }

    @PostMapping("/refresh")
    public ResponseEntity<Object> refresh() {
        try {
            TokenSet ts = kc.auth().refresh(lastRefreshToken);
            if (ts.getRefreshToken() != null) {
                lastRefreshToken = ts.getRefreshToken();
            }
            long expiresIn = Math.max(0, ts.getExpiresAt().getEpochSecond() - Instant.now().getEpochSecond());
            Map<String, Object> m = new HashMap<>();
            m.put("tokenType", ts.getTokenType());
            m.put("expiresIn", expiresIn);
            return ResponseEntity.ok(m);
        } catch (Exception e) {
            return fail(401, e.getMessage());
        }
    }

    @PostMapping("/logout")
    public ResponseEntity<Object> logout() {
        try {
            kc.auth().logout(lastRefreshToken);
            return ResponseEntity.noContent().build();
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @GetMapping("/authz-url")
    public ResponseEntity<Object> authzUrl(@RequestParam(required = false) String redirect_uri) {
        try {
            String redirectUri = (redirect_uri == null || redirect_uri.isBlank()) ? "http://x/cb" : redirect_uri;
            AuthorizationUrlRequest ar = kc.auth().createAuthorizationRequest(URI.create(redirectUri));
            Map<String, Object> m = new HashMap<>();
            m.put("url", ar.getAuthorizationUrl().toString());
            m.put("state", ar.getState());
            return ResponseEntity.ok(m);
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @PostMapping("/admin/users")
    public ResponseEntity<Object> createUser(@RequestBody Map<String, String> body) {
        String username = body.get("username");
        if (username == null || username.isEmpty()) {
            return fail(400, "username required");
        }
        try {
            UserRepresentation rep = new UserRepresentation();
            rep.setUsername(username);
            rep.setEmail(body.get("email"));
            rep.setEnabled(true);
            String id = kc.admin().users().create(rep);
            return ResponseEntity.status(201).body(Map.of("id", id));
        } catch (KeycloakConflictException e) {
            return fail(409, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @GetMapping("/admin/users/{id}")
    public ResponseEntity<Object> getUser(@PathVariable String id) {
        try {
            UserRepresentation u = kc.admin().users().get(id).orElseThrow();
            return ResponseEntity.ok(idUser(u));
        } catch (KeycloakNotFoundException e) {
            return fail(404, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @GetMapping("/admin/users")
    public ResponseEntity<Object> searchUsers(@RequestParam(required = false) String username) {
        try {
            List<UserRepresentation> us = kc.admin().users().search(username, 0, 20);
            List<Map<String, Object>> out = us.stream()
                .map(HarnessController::idUser)
                .toList();
            return ResponseEntity.ok(out);
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @DeleteMapping("/admin/users/{id}")
    public ResponseEntity<Object> deleteUser(@PathVariable String id) {
        try {
            kc.admin().users().delete(id);
            return ResponseEntity.noContent().build();
        } catch (KeycloakNotFoundException e) {
            return fail(404, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    // ---- admin: clients ----

    @PostMapping("/admin/clients")
    public ResponseEntity<Object> createClient(@RequestBody Map<String, String> body) {
        try {
            ClientRepresentation rep = new ClientRepresentation();
            rep.setClientId(body.get("clientId"));
            rep.setEnabled(true);
            String id = kc.admin().clients().create(rep);
            Map<String, Object> m = new HashMap<>();
            m.put("id", id);
            return ResponseEntity.status(201).body(m);
        } catch (KeycloakConflictException e) {
            return fail(409, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @GetMapping("/admin/clients/{id}")
    public ResponseEntity<Object> getClient(@PathVariable String id) {
        try {
            ClientRepresentation c = kc.admin().clients().get(id).orElseThrow();
            Map<String, Object> m = new HashMap<>();
            m.put("id", c.getId());
            m.put("clientId", c.getClientId());
            return ResponseEntity.ok(m);
        } catch (KeycloakNotFoundException e) {
            return fail(404, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @DeleteMapping("/admin/clients/{id}")
    public ResponseEntity<Object> deleteClient(@PathVariable String id) {
        try {
            kc.admin().clients().delete(id);
            return ResponseEntity.noContent().build();
        } catch (KeycloakNotFoundException e) {
            return fail(404, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    // ---- admin: roles (realm role — client role 아님·name 키) ----

    @PostMapping("/admin/roles")
    public ResponseEntity<Object> createRole(@RequestBody Map<String, String> body) {
        try {
            String name = body.get("name");
            RoleRepresentation rep = new RoleRepresentation();
            rep.setName(name);
            kc.admin().roles().create(rep);
            Map<String, Object> m = new HashMap<>();
            m.put("name", name);
            return ResponseEntity.status(201).body(m);
        } catch (KeycloakConflictException e) {
            return fail(409, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @GetMapping("/admin/roles/{name}")
    public ResponseEntity<Object> getRole(@PathVariable String name) {
        try {
            RoleRepresentation r = kc.admin().roles().get(name).orElseThrow();
            Map<String, Object> m = new HashMap<>();
            m.put("name", r.getName());
            return ResponseEntity.ok(m);
        } catch (KeycloakNotFoundException e) {
            return fail(404, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @DeleteMapping("/admin/roles/{name}")
    public ResponseEntity<Object> deleteRole(@PathVariable String name) {
        try {
            kc.admin().roles().delete(name);
            return ResponseEntity.noContent().build();
        } catch (KeycloakNotFoundException e) {
            return fail(404, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    // ---- admin: groups ----

    @PostMapping("/admin/groups")
    public ResponseEntity<Object> createGroup(@RequestBody Map<String, String> body) {
        try {
            GroupRepresentation rep = new GroupRepresentation();
            rep.setName(body.get("name"));
            String id = kc.admin().groups().create(rep);
            Map<String, Object> m = new HashMap<>();
            m.put("id", id);
            return ResponseEntity.status(201).body(m);
        } catch (KeycloakConflictException e) {
            return fail(409, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @GetMapping("/admin/groups/{id}")
    public ResponseEntity<Object> getGroup(@PathVariable String id) {
        try {
            GroupRepresentation g = kc.admin().groups().get(id).orElseThrow();
            Map<String, Object> m = new HashMap<>();
            m.put("id", g.getId());
            m.put("name", g.getName());
            return ResponseEntity.ok(m);
        } catch (KeycloakNotFoundException e) {
            return fail(404, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    @DeleteMapping("/admin/groups/{id}")
    public ResponseEntity<Object> deleteGroup(@PathVariable String id) {
        try {
            kc.admin().groups().delete(id);
            return ResponseEntity.noContent().build();
        } catch (KeycloakNotFoundException e) {
            return fail(404, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }

    // ---- admin: realms (master 전용 — 하네스는 realm SA라 항상 403, CONTRACT.md 참고) ----

    @PostMapping("/admin/realms")
    public ResponseEntity<Object> createRealm(@RequestBody Map<String, String> body) {
        try {
            String realm = body.get("realm");
            RealmRepresentation rep = new RealmRepresentation();
            rep.setRealm(realm);
            rep.setEnabled(true);
            kc.admin().realms().create(rep);
            Map<String, Object> m = new HashMap<>();
            m.put("realm", realm);
            return ResponseEntity.status(201).body(m);
        } catch (KeycloakForbiddenException e) {
            return fail(403, e.getMessage());
        } catch (Exception e) {
            return fail(500, e.getMessage());
        }
    }
}
