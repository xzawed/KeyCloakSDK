import type RoleRepresentation from '@keycloak/keycloak-admin-client/lib/defs/roleRepresentation.js'
import { call, requireFound } from './call.js'
import { type AdminHttp, adminPath, create, omit, orEmpty, read, readOne, write } from './http.js'

/**
 * 렐름 역할(role) CRUD 파사드. 공식 admin-client의 `roles` 리소스가 보내는 것과 같은 요청을 직접 보내며(`http.ts`)
 * {@link call}로 경계 변환한다. ⚠️ API 편차: 역할은 이름으로 조회/삭제한다(admin-client 의 `findOneByName`/`delByName` 경로).
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

  /** 역할을 만든다. 응답의 `Location` 은 admin-client 처럼 요구하되 돌려주지 않는다. */
  async create(representation: RoleRepresentation): Promise<void> {
    await call(() =>
      create(
        this.http,
        adminPath(this.realm, 'roles'),
        omit({ ...representation, realm: this.realm }, ['realm']),
      ),
    )
  }

  /** 역할 이름으로 조회한다. 없으면 `KeycloakNotFoundError`. */
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
   * 현재 이름으로 주소를 잡아 역할을 갱신한다. `representation.name`에 새 이름을 주면 rename이다.
   *
   * ⚠️ 경로(`name`)와 body(`representation`)를 **합치지 말 것**.
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
