const ROWS = [['plain'], ['nbsp']]

describe('bearer', () => {
  it.each(ROWS)('%s — 생성 때 확보한다', async (_id) => {})
  // 미끼 — 표를 비우면 이 시험이 자리표시 제목의 꼴을 채워 카나리아 대신 통과로 읽혔다(#1033 레그 N2 · N3).
  it('d — 생성 때 확보한다', async () => {})
})
