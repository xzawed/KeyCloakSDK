import type GroupRepresentation from '@keycloak/keycloak-admin-client/lib/defs/groupRepresentation.js'
import { call, requireFound } from './call.js'
import { type AdminHttp, adminPath, create, omit, orEmpty, read, readOne, write } from './http.js'

/**
 * 그룹 CRUD 파사드. 공식 admin-client의 `groups` 리소스가 보내는 것과 같은 요청을 직접 보내며(`http.ts`)
 * {@link call}로 경계 변환한다.
 */
export class GroupsResource {
  /**
   * @internal `AdminClient`가 조립한다 — 소비자 생성 경로가 아니다. `@internal` + `stripInternal`로
   * 방출 `.d.ts`에서 지워, 내부 전송 타입이 공개 표면에 오르지 않게 한다(§4).
   */
  constructor(
    private readonly http: AdminHttp,
    private readonly realm: string,
  ) {}

  /** 그룹을 생성하고 신규 그룹 id를 반환한다. */
  async create(representation: GroupRepresentation): Promise<string> {
    return call(() =>
      create(
        this.http,
        adminPath(this.realm, 'groups', ''),
        omit({ ...representation, realm: this.realm }, ['realm']),
      ),
    )
  }

  /** id로 그룹을 조회한다. 없으면 `KeycloakNotFoundError`. */
  async get(id: string): Promise<GroupRepresentation> {
    return requireFound(
      await call(() =>
        readOne<GroupRepresentation>(this.http, adminPath(this.realm, 'groups', id)),
      ),
      `Group not found: ${id}`,
    )
  }

  /** 최상위 그룹을 나열한다(페이지네이션 first/max). */
  async list(first = 0, max = 100): Promise<GroupRepresentation[]> {
    return call(() =>
      read<GroupRepresentation[]>(this.http, adminPath(this.realm, 'groups', ''), [
        ['first', first],
        ['max', max],
      ]),
    )
  }

  /**
   * id로 주소를 잡아 그룹을 갱신한다. `representation.name`에 새 이름을 주면 rename이다.
   *
   * ⚠️ 경로(`id`)와 body(`representation`)를 **합치지 말 것**.
   */
  async update(id: string, representation: GroupRepresentation): Promise<void> {
    await call(() =>
      write(this.http, 'PUT', adminPath(this.realm, 'groups', id), orEmpty(representation)),
    )
  }

  async delete(id: string): Promise<void> {
    await call(() => write(this.http, 'DELETE', adminPath(this.realm, 'groups', id), {}))
  }
}
