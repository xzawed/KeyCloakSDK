// 이 가드를 만든 실제 사고의 축소판 — public 생성자가 jose 타입을 받아 선언에 박혔다.
import type { JWTVerifyGetKey } from 'jose';
export declare class JwtValidator {
    constructor(getKey: JWTVerifyGetKey);
    validate(token: string): Promise<unknown>;
}
