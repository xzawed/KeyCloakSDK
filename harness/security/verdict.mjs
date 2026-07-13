// 적대적 프로브의 응답 상태코드를 판정한다. probe.mjs가 이 함수만 쓰도록 분리한 이유는
// probe.mjs가 컨테이너에서 실행되는 스크립트라 단위 테스트가 불가능하기 때문이다.
//
// ⚠️ 역사: 원래 판정은 `status !== 200`(200이 아니면 전부 방어 성공)이었다. 그 결과
// /validate가 500으로 크래시해도 보안 만점이 나왔다. 공격 프로브가 앱을 죽이는 것은
// 방어가 아니라 더 나쁜 결과다.

/** 토큰이 정상적으로 거부됐음을 의미하는 상태코드. Keycloak 검증 실패는 401, malformed는 400. */
export const REJECT_STATUSES = [400, 401];

/**
 * @param {number} status
 * @returns {"rejected"|"accepted"|"crashed"|"unexpected"}
 */
export function classify(status) {
  if (REJECT_STATUSES.includes(status)) return "rejected";
  if (status === 200) return "accepted";
  if (status >= 500) return "crashed";
  return "unexpected";
}

/** 방어 성공은 오직 명시적 거부뿐이다. 크래시도, 예상 밖 상태도 아니다. */
export const isDefended = (status) => classify(status) === "rejected";
