package io.github.xzawed.harness;

import io.github.xzawed.keycloak.KeycloakClient;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;

@SpringBootApplication
public class App {
    public static void main(String[] args) {
        SpringApplication.run(App.class, args);
    }

    private static String env(String k, String d) {
        String v = System.getenv(k);
        return (v != null && !v.isEmpty()) ? v : d;
    }

    // HarnessController가 ROPC(raw HTTP) 경로에서 server_url/realm/client_id/client_secret에
    // 접근해야 해서 KeycloakConfig를 별도 빈으로 분리(v2). KeycloakClient가 이를 파라미터로 받는다.
    @Bean
    KeycloakConfig keycloakConfig() {
        return KeycloakConfig.builder()
            .serverUrl(env("KC_SERVER_URL", "http://localhost:8080"))
            .realm(env("KC_REALM", "it-realm"))
            .clientId(env("KC_CLIENT_ID", "it-client"))
            .clientSecret(env("KC_CLIENT_SECRET", "it-secret").toCharArray())
            .scopes("openid")
            .build();
    }

    // 단일 장수명 KeycloakClient(스레드-안전, admin lazy). 종료 시 close()로 커넥션 풀 정리.
    @Bean(destroyMethod = "close")
    KeycloakClient keycloakClient(KeycloakConfig config) {
        return KeycloakClient.create(config);
    }
}
