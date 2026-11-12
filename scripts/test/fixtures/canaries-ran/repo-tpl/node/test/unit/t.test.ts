const ROWS = [['plain'], ['nbsp']]

describe('bearer', () => {
  for (const [route] of [['파사드'], ['raw()']] as const) {
    it.each(ROWS)(`%s — ${route} 가 보낸다`, async (_id) => {})
  }
})
