package io.github.xzawed.keycloak.examples;

import io.github.xzawed.keycloak.KeycloakClient;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.Secrets;
import io.github.xzawed.keycloak.core.TokenSet;
import java.util.List;
import org.keycloak.representations.idm.UserRepresentation;

/**
 * QuickStart example (WBS 7.3). Assembles the SDK with {@link KeycloakClient#create(KeycloakConfig)},
 * obtains a token with the client-credentials grant and prints it only masked with {@link Secrets#mask(String)}
 * (the raw token is never written to a log), then lists the realm's users.
 *
 * <p>Because it needs a real Keycloak server, this class is not deployed — the parent POM's
 * {@code <excludeArtifacts>} keeps this module out of the Central bundle — and only its compilation is
 * verified. To run it, set the environment variables below to real values:
 *
 * <pre>{@code
 * KEYCLOAK_URL=https://kc.example.com \
 * KEYCLOAK_REALM=myrealm \
 * KEYCLOAK_CLIENT_ID=admin-cli \
 * KEYCLOAK_CLIENT_SECRET=*** \
 * java -cp ... io.github.xzawed.keycloak.examples.QuickStart
 * }</pre>
 */
public final class QuickStart {

  private QuickStart() {}

  public static void main(String[] args) {
    KeycloakConfig config = KeycloakConfig.builder()
        .serverUrl(env("KEYCLOAK_URL", "https://kc.example.com"))
        .realm(env("KEYCLOAK_REALM", "myrealm"))
        .clientId(env("KEYCLOAK_CLIENT_ID", "admin-cli"))
        .clientSecret(env("KEYCLOAK_CLIENT_SECRET", "changeme").toCharArray())
        .build();

    try (KeycloakClient client = KeycloakClient.create(config)) {
      // 1) Obtain a client-credentials token. Never print the raw value; mask it with Secrets.mask.
      TokenSet tokens = client.auth().clientCredentialsToken();
      System.out.println("Access token: " + Secrets.mask(tokens.getAccessToken()));

      // 2) List users through the admin API (up to 20).
      List<UserRepresentation> users = client.admin().users().search(null, 0, 20);
      System.out.println("Users in realm '" + config.getRealm() + "':");
      users.forEach(u -> System.out.println(" - " + u.getUsername()));
    }
  }

  private static String env(String name, String defaultValue) {
    String v = System.getenv(name);
    return (v == null || v.isBlank()) ? defaultValue : v;
  }
}
