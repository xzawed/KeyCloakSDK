import type KcAdminClient from '@keycloak/keycloak-admin-client'
import type GroupRepresentation from '@keycloak/keycloak-admin-client/lib/defs/groupRepresentation.js'
import { call, requireFound } from './call.js'

/**
 * 그룹 CRUD 파사드. 공식 admin-client의 `groups` 리소스를 감싸며 {@link call}로 경계 변환한다.
 */
export class GroupsResource {
  /**
   * @internal `AdminClient`가 조립한다 — 소비자 생성 경로가 아니다. `@internal` + `stripInternal`로
   * 방출 `.d.ts`에서 지워, 하위 `KcAdminClient` 타입이 공개 표면에 오르지 않게 한다(§4).
   */
  constructor(
    private readonly kc: KcAdminClient,
    private readonly realm: string,
  ) {}

  /** 그룹을 생성하고 신규 그룹 id를 반환한다. */
  async create(representation: GroupRepresentation): Promise<string> {
    const created = await call(() =>
      this.kc.groups.create({ ...representation, realm: this.realm }),
    )
    return created.id
  }

  /** id로 그룹을 조회한다. 없으면 `KeycloakNotFoundError`. */
  async get(id: string): Promise<GroupRepresentation> {
    return requireFound(
      await call(() => this.kc.groups.findOne({ id, realm: this.realm })),
      `Group not found: ${id}`,
    )
  }

  /** 최상위 그룹을 나열한다(페이지네이션 first/max). */
  async list(first = 0, max = 100): Promise<GroupRepresentation[]> {
    return call(() => this.kc.groups.find({ realm: this.realm, first, max }))
  }

  /**
   * id로 주소를 잡아 그룹을 갱신한다. `representation.name`에 새 이름을 주면 rename이다.
   *
   * ⚠️ 경로(`id`)와 body(`representation`)를 **합치지 말 것**.
   */
  async update(id: string, representation: GroupRepresentation): Promise<void> {
    await call(() => this.kc.groups.update({ id, realm: this.realm }, representation))
  }

  async delete(id: string): Promise<void> {
    await call(() => this.kc.groups.del({ id, realm: this.realm }))
  }
}
