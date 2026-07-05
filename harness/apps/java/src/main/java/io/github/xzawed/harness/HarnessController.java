package io.github.xzawed.harness;

import io.github.xzawed.keycloak.KeycloakClient;
import io.github.xzawed.keycloak.auth.IntrospectionResult;
import io.github.xzawed.keycloak.auth.ValidatedToken;
import io.github.xzawed.keycloak.core.TokenSet;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import io.github.xzawed.keycloak.core.exception.KeycloakConflictException;
import io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException;
import io.github.xzawed.keycloak.core.exception.TokenValidationException;
import java.time.Instant;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
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

    public HarnessController(KeycloakClient kc) {
        this.kc = kc;
    }

    // Map.of는 null 값을 금지하므로 null 허용 맵을 만든다.
    private static ResponseEntity<Object> fail(int code, String msg) {
        Map<String, Object> m = new HashMap<>();
        m.put("error", msg);
        return ResponseEntity.status(code).body(m);
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
            return ResponseEntity.ok(Map.of("id", u.getId(), "username", u.getUsername()));
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
            List<Map<String, String>> out = us.stream()
                .map(u -> Map.of("id", u.getId(), "username", u.getUsername()))
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
}
