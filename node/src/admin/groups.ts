import type KcAdminClient from '@keycloak/keycloak-admin-client'
import type GroupRepresentation from '@keycloak/keycloak-admin-client/lib/defs/groupRepresentation.js'
import { call, requireFound } from './call.js'

/**
 * 그룹 CRUD 파사드. 공식 admin-client의 `groups` 리소스를 감싸며 {@link call}로 경계 변환한다.
 */
export class GroupsResource {
  constructor(
    private readonly kc: KcAdminClient,
    private readonly realm: string,
  ) {}

  /** 그룹을 생성하고 신규 그룹 id를 반환한다. */
  async create(representation: GroupRepresentation): Promise<string> {
    const created = await call(() => this.kc.groups.create({ ...representation, realm: this.realm }))
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

  async delete(id: string): Promise<void> {
    await call(() => this.kc.groups.del({ id, realm: this.realm }))
  }
}
