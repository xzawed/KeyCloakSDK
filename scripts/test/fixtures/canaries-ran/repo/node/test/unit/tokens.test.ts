describe('TokenSet', () => {
  it.each([
    ['number', 1],
    ['null', null],
  ])(
    'access_token 이 비문자열이면 throw: %s',
    (_label, _value) => {},
  )
})
