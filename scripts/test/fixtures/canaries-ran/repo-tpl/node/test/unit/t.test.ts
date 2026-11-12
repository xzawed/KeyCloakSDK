const ROWS = [['plain'], ['nbsp']]

describe('bearer', () => {
  for (const [route] of [['파사드'], ['raw()']] as const) {
    it.each(ROWS)(`%s — ${route} 가 보낸다`, async (_id) => {})
  }
  // 형제 — 꼴에 맞지 않는 제목. `${…}` 자리표시가 제목 끝까지 먹으면 이것이 카나리아 대신 읽힌다(#1033 레그 K4).
  it('plain — 다른 일', async () => {})
})
