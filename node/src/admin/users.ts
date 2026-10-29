import type UserRepresentation from '@keycloak/keycloak-admin-client/lib/defs/userRepresentation.js'
import { call, requireFound } from './call.js'
import { type AdminHttp, adminPath, create, omit, orEmpty, read, readOne, write } from './http.js'

/**
 * User CRUD facade. It itself sends the same requests the official admin-client's `users` resource sends
 * (`http.ts` — error bodies only up to the cap, and a write's 2xx body is not read), and converts every call at the
 * boundary with {@link call}. The model type is admin-client's {@link UserRepresentation}, exposed as is (reuse of
 * a stable Keycloak type — a documented hiding exception, isomorphic with the Java admin facade).
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

  /** Creates a user and returns the new user's id. */
  async create(representation: UserRepresentation): Promise<string> {
    return call(() =>
      create(
        this.http,
        adminPath(this.realm, 'users', ''),
        omit({ ...representation, realm: this.realm }, ['realm']),
      ),
    )
  }

  /** Looks up a user by id. `KeycloakNotFoundError` if absent (it does not return null/undefined). */
  async get(id: string): Promise<UserRepresentation> {
    return requireFound(
      await call(() => readOne<UserRepresentation>(this.http, adminPath(this.realm, 'users', id))),
      `User not found: ${id}`,
    )
  }

  /** Searches users by an optional username (pagination first/max). */
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
