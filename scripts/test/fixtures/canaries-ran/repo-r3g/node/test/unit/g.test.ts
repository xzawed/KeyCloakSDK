describe('G', () => {
  const doc = `
it('g1 template canary', () => {})
`
  it(`g1 template canary`, { fails: true }, () => {
    throw new Error('the canary assertion failed' + doc)
  })
})
