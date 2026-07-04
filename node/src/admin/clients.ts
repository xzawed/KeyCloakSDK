import type KcAdminClient from '@keycloak/keycloak-admin-client'
import type ClientRepresentation from '@keycloak/keycloak-admin-client/lib/defs/clientRepresentation.js'
import { KeycloakNotFoundError } from '../errors.js'
import { call } from './call.js'

/**
 * 클라이언트 CRUD 파사드. 공식 admin-client의 `clients` 리소스를 감싸며 {@link call}로 경계
 * 변환한다. `id`는 클라이언트의 내부 UUID, `clientId`는 사람이 지정한 식별자다.
 */
export class ClientsResource {
  constructor(
    private readonly kc: KcAdminClient,
    private readonly realm: string,
  ) {}

  /** 클라이언트를 생성하고 신규 클라이언트 내부 id(UUID)를 반환한다. */
  async create(representation: ClientRepresentation): Promise<string> {
    const created = await call(() =>
      this.kc.clients.create({ ...representation, realm: this.realm }),
    )
    return created.id
  }

  /** 내부 id(UUID)로 클라이언트를 조회한다. 없으면 {@link KeycloakNotFoundError}. */
  async get(id: string): Promise<ClientRepresentation> {
    const client = await call(() => this.kc.clients.findOne({ id, realm: this.realm }))
    if (client === undefined) {
      throw new KeycloakNotFoundError(`Client not found: ${id}`)
    }
    return client
  }

  /** 사람이 지정한 `clientId`로 클라이언트를 검색한다(0..N개). */
  async findByClientId(clientId: string): Promise<ClientRepresentation[]> {
    return call(() => this.kc.clients.find({ realm: this.realm, clientId }))
  }

  async update(id: string, representation: ClientRepresentation): Promise<void> {
    await call(() => this.kc.clients.update({ id, realm: this.realm }, representation))
  }

  async delete(id: string): Promise<void> {
    await call(() => this.kc.clients.del({ id, realm: this.realm }))
  }
}
