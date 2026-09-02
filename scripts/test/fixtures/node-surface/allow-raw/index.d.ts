// §4(b)(b) — `raw()` 탈출구. 실제 node/dist/admin/index.d.ts 의 축소판이다.
import KcAdminClient from '@keycloak/keycloak-admin-client';
/**
 * 관리(Admin) API 파사드. 공식 `@keycloak/keycloak-admin-client` 를 감싼다.
 */
export declare class AdminClient {
    get users(): UsersResource;
    raw(): KcAdminClient;
    close(): Promise<void>;
}
export declare class UsersResource {
}
