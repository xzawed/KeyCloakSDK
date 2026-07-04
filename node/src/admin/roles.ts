import type KcAdminClient from '@keycloak/keycloak-admin-client'
import type RoleRepresentation from '@keycloak/keycloak-admin-client/lib/defs/roleRepresentation.js'
import { KeycloakNotFoundError } from '../errors.js'
import { call } from './call.js'

/**
 * 렐름 역할(role) CRUD 파사드. 공식 admin-client의 `roles` 리소스를 감싸며 {@link call}로 경계
 * 변환한다. ⚠️ API 편차: 역할은 이름으로 조회/삭제한다(`findOneByName`/`delByName`).
 */
export class RolesResource {
  constructor(
    private readonly kc: KcAdminClient,
    private readonly realm: string,
  ) {}

  async create(representation: RoleRepresentation): Promise<void> {
    await call(() => this.kc.roles.create({ ...representation, realm: this.realm }))
  }

  /** 역할 이름으로 조회한다. 없으면 {@link KeycloakNotFoundError}. */
  async get(name: string): Promise<RoleRepresentation> {
    const role = await call(() => this.kc.roles.findOneByName({ name, realm: this.realm }))
    if (role === undefined) {
      throw new KeycloakNotFoundError(`Role not found: ${name}`)
    }
    return role
  }

  async list(): Promise<RoleRepresentation[]> {
    return call(() => this.kc.roles.find({ realm: this.realm }))
  }

  async delete(name: string): Promise<void> {
    await call(() => this.kc.roles.delByName({ name, realm: this.realm }))
  }
}
