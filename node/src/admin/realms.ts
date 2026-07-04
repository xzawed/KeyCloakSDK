import type KcAdminClient from '@keycloak/keycloak-admin-client'
import type RealmRepresentation from '@keycloak/keycloak-admin-client/lib/defs/realmRepresentation.js'
import { call, requireFound } from './call.js'

/**
 * 렐름 생성/조회/삭제 파사드. `RealmsResource`는 realm 스코프가 아니라 렐름 이름을 인자로
 * 받는다(생성 payload의 `realm` 필드가 대상 렐름 이름). 공식 admin-client의 `realms`
 * 리소스를 감싸며 {@link call}로 경계 변환한다.
 */
export class RealmsResource {
  constructor(private readonly kc: KcAdminClient) {}

  /** 새 렐름을 생성한다. `representation.realm`이 새 렐름의 이름이다. */
  async create(representation: RealmRepresentation): Promise<void> {
    await call(() => this.kc.realms.create(representation))
  }

  /** 렐름 이름으로 조회한다. 없으면 `KeycloakNotFoundError`. */
  async get(realmName: string): Promise<RealmRepresentation> {
    return requireFound(
      await call(() => this.kc.realms.findOne({ realm: realmName })),
      `Realm not found: ${realmName}`,
    )
  }

  async delete(realmName: string): Promise<void> {
    await call(() => this.kc.realms.del({ realm: realmName }))
  }
}
