// §4(b)(a) — admin 파사드의 representation 타입은 문서화된 노출이다(그리고 그것이 정상 경로다).
import type UserRepresentation from '@keycloak/keycloak-admin-client/lib/defs/userRepresentation';
export declare class UsersResource {
    search(query?: string): Promise<UserRepresentation[]>;
}
