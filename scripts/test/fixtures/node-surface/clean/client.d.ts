// 오탐 대조군 — 하위 라이브러리 타입이 공개 선언에 없다.
import type { TokenSet } from './tokens.js';
export declare class KeycloakClient {
    get auth(): AuthClient;
    admin(): Promise<AdminClient>;
    close(): Promise<void>;
}
export declare class AuthClient {
    clientCredentialsToken(): Promise<TokenSet>;
}
export declare class AdminClient {
}
