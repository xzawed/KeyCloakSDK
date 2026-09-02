// 예외가 **파일 단위**였을 때 통과하던 자리 — `raw()` 가 같은 파일에 있다는 이유로
// 아래 `underlying` 게터의 노출까지 함께 통과했다.
import KcAdminClient from '@keycloak/keycloak-admin-client';
export declare class AdminClient {
    raw(): KcAdminClient;
    get underlying(): KcAdminClient;
    close(): Promise<void>;
}
