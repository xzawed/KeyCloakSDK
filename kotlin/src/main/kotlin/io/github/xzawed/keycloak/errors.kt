package io.github.xzawed.keycloak

// errors.kt — sealed 계층 전체를 한 패키지/파일에(sealed same-module+package 요건)
public sealed class KeycloakException(message: String, cause: Throwable? = null) : Exception(message, cause)

public class KeycloakConfigException(m: String, c: Throwable? = null) : KeycloakException(m, c)

public class KeycloakAuthException(m: String, public val oauthError: String? = null, c: Throwable? = null) :
    KeycloakException(m, c)

public class KeycloakTransportException(m: String, c: Throwable? = null) : KeycloakException(m, c)

public class TokenValidationException(m: String, c: Throwable? = null) : KeycloakException(m, c)

public sealed class KeycloakAdminException(public val status: Int, public val keycloakError: String?, c: Throwable? = null) :
    KeycloakException("Keycloak admin error (HTTP $status)", c) {
    public class NotFound(s: Int, e: String?, c: Throwable? = null) : KeycloakAdminException(s, e, c)

    public class Conflict(s: Int, e: String?, c: Throwable? = null) : KeycloakAdminException(s, e, c)

    public class Forbidden(s: Int, e: String?, c: Throwable? = null) : KeycloakAdminException(s, e, c)

    public class Other(s: Int, e: String?, c: Throwable? = null) : KeycloakAdminException(s, e, c) // 500 등 필수 리프
}
