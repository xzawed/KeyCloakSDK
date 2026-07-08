package io.github.xzawed.keycloak

import io.github.xzawed.keycloak.admin.AdminClient

// client.kt — KeycloakClient: 8언어 §4 결합 규칙의 Kotlin 구현부(통합 진입점 파사드). auth(AuthClient)는
// 즉시 생성(네트워크 없음 — OidcEndpoints 조립만), admin(AdminClient)은 최초 접근까지 지연 생성한다(`Lazy`,
// 기본 SYNCHRONIZED 모드) — admin은 KeycloakBuilder로 실 JAX-RS 클라이언트를 만들고 client-credentials
// 그랜트로 토큰 라이프사이클을 자체 관리하므로, 인증 흐름만 쓰는 소비자에게 불필요한 admin 자원 생성을
// 강제하지 않는다.
//
// ⚠️ 부록(§kotlin-idioms)의 파사드 스니펫은 `AdminClient(config, ClientCredentialsTokenProvider(config))`처럼
// admin에 전용 TokenProvider를 주입하는 형태를 보이지만, 실제 T8 `AdminClient`(Java `keycloak-sdk-admin` 동형)는
// 그런 생성자를 제공하지 않는다 — admin은 KeycloakBuilder 내장 client-credentials 그랜트로 자체 토큰을
// 관리하고 `TokenProvider`를 직접 소비하지 않는다(admin/AdminClient.kt 코멘트 참고 — admin은 auth를 직접
// 알지 못한다, §4). 공개 보조생성자 `AdminClient(config)`(내부에서 KeycloakBuilder + resteasy 타임아웃까지
// 이미 조립)를 그대로 재사용한다 — 별도 팩토리 추가는 불필요했다. `tokenprovider.kt`의
// `ClientCredentialsTokenProvider`는 §4 계약을 보이는 독립 유틸리티로 남는다(T5에서 이미 자체 테스트됨) —
// 이 파사드가 admin에 직접 배선하지는 않는다.
public class KeycloakClient internal constructor(
    public val config: KeycloakConfig,
    public val auth: AuthClient,
    private val adminLazy: Lazy<AdminClient>,
) : AutoCloseable {
    /** 관리(admin) API 파사드. 최초 접근 시 지연 생성된다(`kotlin.Lazy` 기본 스레드-세이프). */
    public val admin: AdminClient get() = adminLazy.value

    /** 테스트 전용 관측 시임 — admin lazy가 이미 실현됐는지 여부. 운영 코드 경로에서는 사용하지 않는다. */
    internal fun isAdminInitialized(): Boolean = adminLazy.isInitialized()

    /**
     * auth와(접근된 적이 있다면) admin 자원을 정리한다. **admin을 강제로 초기화하지 않는다** — 한 번도
     * 접근하지 않은 admin을 close()가 실현시키면, 인증 흐름만 쓰는 소비자에게 불필요한 KeycloakBuilder
     * 자원 생성(및 그 자체의 close 비용)을 강요하게 된다.
     */
    override fun close() {
        auth.close()
        if (adminLazy.isInitialized()) {
            adminLazy.value.close()
        }
    }

    public companion object {
        /** 운영 진입점 — auth를 즉시 생성하고 admin은 최초 접근까지 지연한다. */
        public fun create(config: KeycloakConfig): KeycloakClient = KeycloakClient(config, AuthClient(config), lazy { AdminClient(config) })
    }
}
