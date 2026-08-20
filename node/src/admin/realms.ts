import type KcAdminClient from '@keycloak/keycloak-admin-client'
import type RealmRepresentation from '@keycloak/keycloak-admin-client/lib/defs/realmRepresentation.js'
import { call, requireFound } from './call.js'

/**
 * 렐름 생성/조회/삭제 파사드. `RealmsResource`는 realm 스코프가 아니라 렐름 이름을 인자로
 * 받는다(생성 payload의 `realm` 필드가 대상 렐름 이름). 공식 admin-client의 `realms`
 * 리소스를 감싸며 {@link call}로 경계 변환한다.
 */
export class RealmsResource {
  /**
   * @internal `AdminClient`가 조립한다 — 소비자 생성 경로가 아니다. `@internal` + `stripInternal`로
   * 방출 `.d.ts`에서 지워, 하위 `KcAdminClient` 타입이 공개 표면에 오르지 않게 한다(§4).
   */
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

  /** 호출자가 볼 수 있는 렐름 전부. 서비스 계정은 보통 자기 렐름만 본다 — 전체를 가정하지 말 것. */
  async list(): Promise<RealmRepresentation[]> {
    return call(() => this.kc.realms.find())
  }

  /**
   * 현재 이름으로 주소를 잡아 렐름을 갱신한다. `representation.realm`에 새 이름을 주면 rename이다.
   *
   * ⚠️ 경로(`realmName`)와 body(`representation`)를 **합치지 말 것** — 경로 인자를 body의 이름으로
   * 덮어쓰면 rename이 조용한 no-op이 된다.
   */
  async update(realmName: string, representation: RealmRepresentation): Promise<void> {
    await call(() => this.kc.realms.update({ realm: realmName }, representation))
  }

  async delete(realmName: string): Promise<void> {
    await call(() => this.kc.realms.del({ realm: realmName }))
  }
}
