import type KcAdminClient from '@keycloak/keycloak-admin-client'
import type UserRepresentation from '@keycloak/keycloak-admin-client/lib/defs/userRepresentation.js'
import { call, requireFound } from './call.js'

/**
 * 사용자 CRUD 파사드. 공식 admin-client의 `users` 리소스를 감싸며 모든 호출을 {@link call}로
 * 경계 변환한다. 모델 타입은 admin-client의 {@link UserRepresentation}을 그대로 노출한다
 * (안정적 Keycloak 타입 재사용 — 문서화된 은닉성 예외, Java admin 파사드와 동형).
 */
export class UsersResource {
  /**
   * @internal `AdminClient`가 조립한다 — 소비자 생성 경로가 아니다. `@internal` + `stripInternal`로
   * 방출 `.d.ts`에서 지워, 하위 `KcAdminClient` 타입이 공개 표면에 오르지 않게 한다(§4).
   */
  constructor(
    private readonly kc: KcAdminClient,
    private readonly realm: string,
  ) {}

  /** 사용자를 생성하고 신규 사용자 id를 반환한다. */
  async create(representation: UserRepresentation): Promise<string> {
    const created = await call(() => this.kc.users.create({ ...representation, realm: this.realm }))
    return created.id
  }

  /** id로 사용자를 조회한다. 없으면 `KeycloakNotFoundError`(null/undefined를 반환하지 않는다). */
  async get(id: string): Promise<UserRepresentation> {
    return requireFound(
      await call(() => this.kc.users.findOne({ id, realm: this.realm })),
      `User not found: ${id}`,
    )
  }

  /** username(선택)으로 사용자를 검색한다(페이지네이션 first/max). */
  async search(username?: string, first = 0, max = 100): Promise<UserRepresentation[]> {
    return call(() => this.kc.users.find({ realm: this.realm, username, first, max }))
  }

  async update(id: string, representation: UserRepresentation): Promise<void> {
    await call(() => this.kc.users.update({ id, realm: this.realm }, representation))
  }

  async delete(id: string): Promise<void> {
    await call(() => this.kc.users.del({ id, realm: this.realm }))
  }
}
