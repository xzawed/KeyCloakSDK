import type UserRepresentation from '@keycloak/keycloak-admin-client/lib/defs/userRepresentation.js'
import { call, requireFound } from './call.js'
import { type AdminHttp, adminPath, create, omit, orEmpty, read, readOne, write } from './http.js'

/**
 * 사용자 CRUD 파사드. 공식 admin-client의 `users` 리소스가 보내는 것과 같은 요청을 직접 보내며(`http.ts` — 오류 본문은
 * 상한까지만, 쓰기의 2xx 본문은 읽지 않는다) 모든 호출을 {@link call}로 경계 변환한다. 모델 타입은 admin-client의
 * {@link UserRepresentation}을 그대로 노출한다(안정적 Keycloak 타입 재사용 — 문서화된 은닉성 예외, Java admin 파사드와
 * 동형).
 */
export class UsersResource {
  /**
   * @internal `AdminClient`가 조립한다 — 소비자 생성 경로가 아니다. `@internal` + `stripInternal`로
   * 방출 `.d.ts`에서 지워, 내부 전송 타입이 공개 표면에 오르지 않게 한다(§4).
   */
  constructor(
    private readonly http: AdminHttp,
    private readonly realm: string,
  ) {}

  /** 사용자를 생성하고 신규 사용자 id를 반환한다. */
  async create(representation: UserRepresentation): Promise<string> {
    return call(() =>
      create(
        this.http,
        adminPath(this.realm, 'users', ''),
        omit({ ...representation, realm: this.realm }, ['realm']),
      ),
    )
  }

  /** id로 사용자를 조회한다. 없으면 `KeycloakNotFoundError`(null/undefined를 반환하지 않는다). */
  async get(id: string): Promise<UserRepresentation> {
    return requireFound(
      await call(() => readOne<UserRepresentation>(this.http, adminPath(this.realm, 'users', id))),
      `User not found: ${id}`,
    )
  }

  /** username(선택)으로 사용자를 검색한다(페이지네이션 first/max). */
  async search(username?: string, first = 0, max = 100): Promise<UserRepresentation[]> {
    return call(() =>
      read<UserRepresentation[]>(this.http, adminPath(this.realm, 'users', ''), [
        ['username', username],
        ['first', first],
        ['max', max],
      ]),
    )
  }

  async update(id: string, representation: UserRepresentation): Promise<void> {
    await call(() =>
      write(this.http, 'PUT', adminPath(this.realm, 'users', id), orEmpty(representation)),
    )
  }

  async delete(id: string): Promise<void> {
    await call(() => write(this.http, 'DELETE', adminPath(this.realm, 'users', id), {}))
  }
}
