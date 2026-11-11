const handler = () => {}

describe('O', () => {
  it('o1 timeout options', { timeout: 5000 }, () => {})
  it('o2 fails false', { fails: false }, () => {})
  it('o3 function reference', handler)
  it('o3b function reference and timeout', handler, 5000)
  it('o3c single-parameter arrow', ctx => {})
  it('o3d async arrow', async () => {})
  it('o3e function keyword', function () {})
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
})
