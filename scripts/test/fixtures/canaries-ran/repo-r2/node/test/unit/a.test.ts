describe('TokenSet', () => {
  describe('nested', () => {
    it('inner', () => {})
  })
  it.each([['number', 1]])(
    'r2 healthy each: %s',
    () => {},
  )
  it.fails.each([
    ['r01', 1],
    ['r02', 2],
    ['r03', 3],
    ['r04', 4],
    ['r05', 5],
    ['r06', 6],
    ['r07', 7],
    ['r08', 8],
    ['r09', 9],
    ['r10', 10],
    ['r11', 11],
    ['r12', 12],
    ['r13', 13],
    ['r14', 14],
    ['r15', 15],
    ['r16', 16],
    ['r17', 17],
    ['r18', 18],
    ['r19', 19],
    ['r20', 20],
    ['r21', 21],
    ['r22', 22],
  ])(
    'r2 fails each: %s',
    () => {
      throw new Error('the canary assertion failed')
    },
  )
  it.fails(
    'r2 fails it (call): number',
    () => {
      throw new Error('the canary assertion failed')
    },
  )
})
