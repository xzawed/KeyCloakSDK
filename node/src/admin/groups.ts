import type GroupRepresentation from '@keycloak/keycloak-admin-client/lib/defs/groupRepresentation.js'
import { call, requireFound } from './call.js'
import { type AdminHttp, adminPath, create, omit, orEmpty, read, readOne, write } from './http.js'

/**
 * Group CRUD facade. It itself sends the same requests the official admin-client's `groups` resource sends
 * (`http.ts`), and converts at the boundary with {@link call}.
 */
export class GroupsResource {
  /**
   * @internal `AdminClient`가 조립한다 — 소비자 생성 경로가 아니다. `@internal` + `stripInternal`로
   * 방출 `.d.ts`에서 지워, 내부 전송 타입이 공개 표면에 오르지 않게 한다(§4).
   */
  constructor(
    private readonly http: AdminHttp,
    private readonly realm: string,
  ) {}

  /** Creates a group and returns the new group's id. */
  async create(representation: GroupRepresentation): Promise<string> {
    return call(() =>
      create(
        this.http,
        adminPath(this.realm, 'groups', ''),
        omit({ ...representation, realm: this.realm }, ['realm']),
      ),
    )
  }

  /** Looks up a group by id. `KeycloakNotFoundError` if absent. */
  async get(id: string): Promise<GroupRepresentation> {
    return requireFound(
      await call(() =>
        readOne<GroupRepresentation>(this.http, adminPath(this.realm, 'groups', id)),
      ),
      `Group not found: ${id}`,
    )
  }

  /** Lists the top-level groups (pagination first/max). */
  async list(first = 0, max = 100): Promise<GroupRepresentation[]> {
    return call(() =>
      read<GroupRepresentation[]>(this.http, adminPath(this.realm, 'groups', ''), [
        ['first', first],
        ['max', max],
      ]),
    )
  }

  /**
   * Updates a group, addressed by id. A new name in `representation.name` is a rename.
   *
   * ⚠️ **Do not merge** the path (`id`) and the body (`representation`).
   */
  async update(id: string, representation: GroupRepresentation): Promise<void> {
    await call(() =>
      write(this.http, 'PUT', adminPath(this.realm, 'groups', id), orEmpty(representation)),
    )
  }

  async delete(id: string): Promise<void> {
    await call(() => write(this.http, 'DELETE', adminPath(this.realm, 'groups', id), {}))
  }
}
