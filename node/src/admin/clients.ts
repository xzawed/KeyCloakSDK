import type ClientRepresentation from '@keycloak/keycloak-admin-client/lib/defs/clientRepresentation.js'
import { call, requireFound } from './call.js'
import { type AdminHttp, adminPath, create, omit, orEmpty, read, readOne, write } from './http.js'

/**
 * Client CRUD facade. It itself sends the same requests the official admin-client's `clients` resource sends
 * (`http.ts`), and converts at the boundary with {@link call}. `id` is the client's internal UUID; `clientId` is
 * the human-assigned identifier.
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

  /** Creates a client and returns the new client's internal id (UUID). */
  async create(representation: ClientRepresentation): Promise<string> {
    return call(() =>
      create(
        this.http,
        adminPath(this.realm, 'clients', ''),
        omit({ ...representation, realm: this.realm }, ['realm']),
      ),
    )
  }

  /** Looks up a client by internal id (UUID). `KeycloakNotFoundError` if absent. */
  async get(id: string): Promise<ClientRepresentation> {
    return requireFound(
      await call(() =>
        readOne<ClientRepresentation>(this.http, adminPath(this.realm, 'clients', id)),
      ),
      `Client not found: ${id}`,
    )
  }

  /** Searches clients by the human-assigned `clientId` (0..N results). */
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
