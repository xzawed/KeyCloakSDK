// Fixture: every shape the node name-range parser reads (prettier-formatted).
const SYM = Symbol.for('fixture.inspect')

export interface Shape {
  readonly name: string
  render(): string
}

const banner = `
}
${'{'}
class NotAClass {
`

class Masked implements Shape {
  constructor(readonly name: string) {}

  #secret(): string {
    return '***'
  }

  render(): string {
    return this.#secret()
  }

  describe(): string {
    return `
  }
function fake() {
`
  }

  toString(): string { return 'Masked{' }

  [SYM](): string {
    return 'Masked(***)'
  }
}

function helper(x: number): number {
  return x + 1
}

export const twice = (x: number): number => {
  return helper(x) * 2
}

export const inc = (x: number): number => x + 1

export class Client {
  #n = 0
  readonly cb = (x: number): number => x * 3

  get count(): number {
    return this.#n
  }

  set count(v: number) {
    this.#n = v
  }

  run(items: number[]): number[] {
    return items.map((i) => {
      this.#n++
      return twice(i)
    })
  }

  overload(a: string): string
  overload(a: number): string
  overload(a: string | number): string {
    return String(a)
  }

  async longSignature(
    a: number,
    b: number,
  ): Promise<number> {
    return a + b
  }

  /*
function hidden() {
  */
  close(): void {
    this.#n = 0
  }
}

export { banner, Masked }
