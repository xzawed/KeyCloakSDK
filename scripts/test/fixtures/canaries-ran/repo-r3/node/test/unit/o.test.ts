const handler = () => {}
const SLOW_MS = 5000
const retried = (f) => f

describe('O', () => {
  it('o1 timeout options', { timeout: 5000 }, () => {})
  it('o2 fails false', { fails: false }, () => {})
  it('o3 function reference', handler)
  it('o3b function reference and timeout', handler, 5000)
  it('o3c single-parameter arrow', ctx => {})
  it('o3d async arrow', async () => {})
  it('o3e function keyword', function () {})
  it('o3f comment before the function', /* #742 */ async () => {})
  it('o3g named timeout constant', handler, SLOW_MS)
  it('o3h comment mentions fails', { retry: 2 /* mock fails */ }, () => {})
  describe('o3i describe', /* #742 */ () => {
    it('o3i inside a commented describe', () => {})
  })
  it('o3j wrapped function', retried(async () => {
    const doc = `
  multi-line ) template } with { brackets ( ${`nested ) template`}
`
    return doc
  }))
  it('o4 fails true', { fails: true }, () => {
    throw new Error('the canary assertion failed')
  })
  it('o5 fails multi-line', {
    timeout: 5000,
    fails: true,
  }, () => {
    throw new Error('the canary assertion failed')
  })
  describe('o6 describe', { fails: true }, () => {
    it('o6 inside a fails describe', () => {
      throw new Error('the canary assertion failed')
    })
  })
  it('o7 comment with a brace', { /* } */ fails: true }, () => {
    throw new Error('the canary assertion failed')
  })
  /**/ describe('o8 commented describe', { fails: true }, () => {
    it('o8 inside a commented fails describe', () => {
      throw new Error('the canary assertion failed')
    })
  })
  it.skipIf(false).fails('o9 chained fails', () => {
    throw new Error('the canary assertion failed')
  })
  it('o10 regex with a brace', { meta: { r: /}/ }, fails: true }, () => {
    throw new Error('the canary assertion failed')
  })
  it('o12 regex after return', { meta: (() => { return /}/ })(), fails: true }, () => {
    throw new Error('the canary assertion failed')
  })
})
