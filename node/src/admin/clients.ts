import type ClientRepresentation from '@keycloak/keycloak-admin-client/lib/defs/clientRepresentation.js'
import { call, requireFound } from './call.js'
import { type AdminHttp, adminPath, create, omit, orEmpty, read, readOne, write } from './http.js'

/**
 * 클라이언트 CRUD 파사드. 공식 admin-client의 `clients` 리소스가 보내는 것과 같은 요청을 직접 보내며(`http.ts`)
 * {@link call}로 경계 변환한다. `id`는 클라이언트의 내부 UUID, `clientId`는 사람이 지정한 식별자다.
 */
export class ClientsResource {
  /**
   * @internal `AdminClient`가 조립한다 — 소비자 생성 경로가 아니다. `@internal` + `stripInternal`로
   * 방출 `.d.ts`에서 지워, 내부 전송 타입이 공개 표면에 오르지 않게 한다(§4).
   */
  constructor(
    private readonly http: AdminHttp,
    private readonly realm: string,
  ) {}

  /** 클라이언트를 생성하고 신규 클라이언트 내부 id(UUID)를 반환한다. */
  async create(representation: ClientRepresentation): Promise<string> {
    return call(() =>
      create(
        this.http,
        adminPath(this.realm, 'clients', ''),
        omit({ ...representation, realm: this.realm }, ['realm']),
      ),
    )
  }

  /** 내부 id(UUID)로 클라이언트를 조회한다. 없으면 `KeycloakNotFoundError`. */
  async get(id: string): Promise<ClientRepresentation> {
    return requireFound(
      await call(() =>
        readOne<ClientRepresentation>(this.http, adminPath(this.realm, 'clients', id)),
      ),
      `Client not found: ${id}`,
    )
  }

  /** 사람이 지정한 `clientId`로 클라이언트를 검색한다(0..N개). */
  async findByClientId(clientId: string): Promise<ClientRepresentation[]> {
    return call(() =>
      read<ClientRepresentation[]>(this.http, adminPath(this.realm, 'clients', ''), [
        ['clientId', clientId],
      ]),
    )
  }

  async update(id: string, representation: ClientRepresentation): Promise<void> {
    await call(() =>
      write(this.http, 'PUT', adminPath(this.realm, 'clients', id), orEmpty(representation)),
    )
  }

  async delete(id: string): Promise<void> {
    await call(() => write(this.http, 'DELETE', adminPath(this.realm, 'clients', id), {}))
  }
}
