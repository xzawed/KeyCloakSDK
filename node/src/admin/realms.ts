import type RealmRepresentation from '@keycloak/keycloak-admin-client/lib/defs/realmRepresentation.js'
import { call, requireFound } from './call.js'
import { type AdminHttp, adminPath, create, omit, orEmpty, read, readOne, write } from './http.js'

/**
 * Realm create/get/delete facade. `RealmsResource` is not realm-scoped; it takes the realm name as an argument
 * (the `realm` field of the create payload is the target realm's name). It itself sends the same requests the
 * official admin-client's `realms` resource sends (`http.ts`), and converts at the boundary with {@link call}.
 */
export class RealmsResource {
  /**
   * @internal `AdminClient`가 조립한다 — 소비자 생성 경로가 아니다. `@internal` + `stripInternal`로
   * 방출 `.d.ts`에서 지워, 내부 전송 타입이 공개 표면에 오르지 않게 한다(§4).
   */
  constructor(private readonly http: AdminHttp) {}

  /**
   * Creates a new realm. `representation.realm` is the new realm's name. Like admin-client, it requires the
   * response's `Location` but does not return it.
   */
  async create(representation: RealmRepresentation): Promise<void> {
    await call(() => create(this.http, adminPath(''), omit(orEmpty(representation) as object, [])))
  }

  /** Looks up a realm by name. `KeycloakNotFoundError` if absent. */
  async get(realmName: string): Promise<RealmRepresentation> {
    return requireFound(
      await call(() => readOne<RealmRepresentation>(this.http, adminPath(realmName))),
      `Realm not found: ${realmName}`,
    )
  }

  /** Every realm the caller can see. A service account usually sees only its own realm — do not assume all of them. */
  async list(): Promise<RealmRepresentation[]> {
    return call(() => read<RealmRepresentation[]>(this.http, adminPath('')))
  }

  /**
   * Updates a realm, addressed by its current name. A new name in `representation.realm` is a rename.
   *
   * ⚠️ **Do not merge** the path (`realmName`) and the body (`representation`) — overwriting the path argument
   * with the body's name turns a rename into a silent no-op.
   */
  async update(realmName: string, representation: RealmRepresentation): Promise<void> {
    await call(() => write(this.http, 'PUT', adminPath(realmName), orEmpty(representation)))
  }

  async delete(realmName: string): Promise<void> {
    await call(() => write(this.http, 'DELETE', adminPath(realmName), {}))
  }
}
