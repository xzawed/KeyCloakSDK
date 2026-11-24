// Fixture boundary module — vitest.config.ts's coverage.exclude takes it out of the unit gate, so only the ledger measures its unit reach.
const LIMIT = 3

export function helper(x: number): number {
  return x * LIMIT
}

export class AuthClient {
  #cached?: string
  readonly token = async (code: string): Promise<string> => {
    if (!code) {
      return ''
    }
    return this.exchange(code)
  }

  constructor(readonly realm: string) {}

  static from(text: string): AuthClient {
    if (text === '') {
      throw new Error('empty realm')
    }
    return new AuthClient(text)
  }

  exchange(code: string): string {
    if (!code) {
      throw new Error('empty code')
    }
    return `token-for-${code}`
  }

  scope(value: string): string {
    if (value) {
      value = value.trim()
    }
    return value
  }

  fallback(value: string): string {
    return value ? value : 'anon'
  }

  pick(items: string[], want: string): string {
    const hit = items.find((x) => {
      if (x === '') {
        return false
      }
      return x === want
    })
    return hit ?? ''
  }

  kind(n: number): string {
    switch (n) {
      case 1:
        return 'one'
      case 2:
        return 'two'
      default:
        return 'many'
    }
  }

  async load(): Promise<string> {
    return this.#load()
  }

  async #load(): Promise<string> {
    if (this.#cached !== undefined) {
      return this.#cached
    }
    this.#cached = this.realm
    return this.#cached
  }

  describe(): string {
    return `AuthClient(${this.realm})`
  }

  logoutUrl(): string {
    return `/realms/${this.realm}/logout`
  }
}
