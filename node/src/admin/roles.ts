import type RoleRepresentation from '@keycloak/keycloak-admin-client/lib/defs/roleRepresentation.js'
import { call, requireFound } from './call.js'
import { type AdminHttp, adminPath, create, omit, orEmpty, read, readOne, write } from './http.js'

/**
 * Realm role CRUD facade. It itself sends the same requests the official admin-client's `roles` resource sends
 * (`http.ts`), and converts at the boundary with {@link call}. ⚠️ API deviation: roles are looked up/deleted by
 * name (admin-client's `findOneByName`/`delByName` paths).
 */
export class RolesResource {
  /**
   * @internal `AdminClient`가 조립한다 — 소비자 생성 경로가 아니다. `@internal` + `stripInternal`로
   * 방출 `.d.ts`에서 지워, 내부 전송 타입이 공개 표면에 오르지 않게 한다(§4).
   */
  constructor(
    private readonly http: AdminHttp,
    private readonly realm: string,
  ) {}

  async create(representation: RoleRepresentation): Promise<void> {
    // 응답의 `Location` 은 admin-client 처럼 요구하되 돌려주지 않는다. (문서 주석이 아닌 것은 의도다 — api-extractor
    // 보고서의 `(undocumented)` 줄이 사라지면 공개 API 가드가 그것을 기준선에서 사라진 줄로 센다.)
    await call(() =>
      create(
        this.http,
        adminPath(this.realm, 'roles'),
        omit({ ...representation, realm: this.realm }, ['realm']),
      ),
    )
  }

  /** Looks up a role by name. `KeycloakNotFoundError` if absent. */
  async get(name: string): Promise<RoleRepresentation> {
    return requireFound(
      await call(() =>
        readOne<RoleRepresentation>(this.http, adminPath(this.realm, 'roles', name)),
      ),
      `Role not found: ${name}`,
    )
  }

  async list(): Promise<RoleRepresentation[]> {
    return call(() => read<RoleRepresentation[]>(this.http, adminPath(this.realm, 'roles')))
  }

  /**
   * Updates a role, addressed by its current name. A new name in `representation.name` is a rename.
   *
   * ⚠️ **Do not merge** the path (`name`) and the body (`representation`).
   */
  async update(name: string, representation: RoleRepresentation): Promise<void> {
    await call(() =>
      write(this.http, 'PUT', adminPath(this.realm, 'roles', name), orEmpty(representation)),
    )
  }

  async delete(name: string): Promise<void> {
    await call(() => write(this.http, 'DELETE', adminPath(this.realm, 'roles', name), {}))
  }
}
