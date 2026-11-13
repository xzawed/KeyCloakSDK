// .NET 대상 프레임워크(TFM) 목록 — `<TargetFramework>`(단수) 또는 `<TargetFrameworks>`(복수, `;` 구분)를 읽어
// **버전 오름차순**으로 돌려준다. 읽는 쪽마다 고르는 끝이 다르다:
//   · check-docs.mjs — 가장 낮은 것 = 소비자 하한(문서의 「.NET 8+」가 대조할 값)
//   · doctor.mjs     — 가장 높은 것 = 이 PC 의 SDK 가 빌드할 수 있어야 하는 판(SDK 8 은 net10.0 을 복원조차 못 한다)
// ⚠️ 선언 순서로 고르지 않는다 — `net10.0;net8.0` 도 하한은 8.0 이다. 문자열 정렬도 틀린다(「net10.0」<「net8.0」).
// ⚠️ 모르는 모양(`net462` · `netstandard2.0` · 플랫폼 접미 `net8.0-windows`)은 조용히 버리지 않고 던진다 —
// 버리면 남은 것 중에서 하한을 골라 거짓 값을 초록으로 낸다. 그런 대상을 들이는 PR 이 여기를 함께 가르친다.
export function dotnetTfms(text) {
  const m = /<TargetFrameworks?>\s*([^<]*?)\s*<\/TargetFrameworks?>/.exec(text)
  if (!m) return []
  const tfms = m[1].split(';').map((s) => s.trim()).filter(Boolean)
  for (const t of tfms) {
    if (!/^net\d+\.\d+$/.test(t)) throw new Error(`알 수 없는 TFM 모양: ${t} — scripts/lib/dotnet-tfm.mjs 가 아직 netN.M 만 읽는다`)
  }
  const ver = (t) => t.slice(3).split('.').map(Number)
  return tfms.sort((a, b) => {
    const [x, y] = [ver(a), ver(b)]
    return x[0] - y[0] || x[1] - y[1]
  })
}
