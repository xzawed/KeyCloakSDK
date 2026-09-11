// authz-url 판정 — `conformance.mjs`가 쓰고 `scripts/test/test-conformance-authz-url.sh`가 잰다.
//
// ⚠️ **왜 모듈로 뽑는가**: 이 판정은 Docker 전체 런 없이는 시험할 수 없었고, 그래서 아무도
// 재보지 않은 채 아홉 언어에 초록을 발급했다. 모듈로 나오면 픽스처로 잴 수 있다.

// ⚠️ **단언하지 않기로 한 것**: `response_type`·`client_id`·`scope`·`nonce`의 값. 아홉 앱을
// 실제로 재보기 전에는 넣지 않는다 — 미측정 단언은 이 항목과 무관한 이유로 초록을 빨갛게
// 만들고, 그 빨강은 「계약 위반」과 구분되지 않는다.
//
// ⚠️ `code_challenge` **길이**도 같은 이유로 단언하지 않는다(S256이면 43자가 되어야 하나
// 아홉을 재지 않았다). 여기서 죽이는 것은 빈 값·비base64url이라는 **증명된** 공허다.

/**
 * @param {{status: number, body: any, requestedRedirectUri: string}} input
 * @returns {{ok: boolean, detail: string}}
 */
export function judgeAuthzUrl({ status, body, requestedRedirectUri }) {
  const fail = (reason, extra = "") => ({ ok: false, detail: `${reason} ${extra}`.trim().slice(0, 300) });

  if (status !== 200) return fail("status-not-200", String(status));

  const raw = body?.url;
  if (typeof raw !== "string" || raw === "") return fail("url-missing");
  let q;
  try {
    q = new URL(raw).searchParams;
  } catch {
    return fail("url-unparseable", raw.slice(0, 80));
  }

  // PKCE verifier는 인가 URL에 실려서는 안 된다(앞단계부터 본다 — 누출이 가장 비싸다).
  if (raw.includes("code_verifier")) return fail("code-verifier-leaked");

  const method = q.get("code_challenge_method");
  if (method !== "S256") return fail("challenge-method-not-s256", String(method));

  // ⚠️ 옛 판정은 `/code_challenge=/`였다 — `code_challenge=`(빈 값)도 통과했다.
  const challenge = q.get("code_challenge") || "";
  if (!/^[A-Za-z0-9_-]+$/.test(challenge)) {
    return fail("code-challenge-invalid", challenge === "" ? "(empty)" : challenge.slice(0, 40));
  }

  // ⚠️ 옛 판정은 URL의 state와 돌려준 state의 **존재**를 따로 봤을 뿐 대조하지 않았다.
  // 소비자는 돌려받은 값으로 콜백을 대조하므로, 둘이 갈리면 CSRF 방어가 헛돈다.
  const urlState = q.get("state") || "";
  const bodyState = typeof body?.state === "string" ? body.state : "";
  if (urlState === "" || bodyState === "") return fail("state-missing");
  if (urlState !== bodyState) return fail("state-mismatch", `url=${urlState} body=${bodyState}`);

  // ⚠️ 이 줄이 이 판정의 존재 이유다. 옛 검사는 요청과 응답을 대조하지 않았고, 보내는 값이
  // 아홉 앱 전부의 폴백과 같아서 「무시」와 「준수」가 같은 초록을 냈다.
  const got = q.get("redirect_uri");
  if (got !== requestedRedirectUri) {
    return fail("redirect-uri-mismatch", `requested=${requestedRedirectUri} got=${got}`);
  }

  return { ok: true, detail: `redirect_uri=${got} state=${urlState.slice(0, 8)}` };
}

// ── CLI: 픽스처 하나를 판정한다(자가테스트용). ───────────────────────────────
// ⚠️ 엔트리 가드는 `pathToFileURL(argv[1])`로 비교한다 — Windows 경로를 문자열로 비교하면
// 빗나가고, 그러면 이 파일은 실행해도 아무 일도 하지 않는 조용한 통과가 된다.
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const path = process.argv[2];
  if (!path) {
    process.stderr.write("usage: authz-url.mjs <fixture.json>\n");
    process.exit(2);
  }
  const input = JSON.parse(readFileSync(path, "utf8"));
  const verdict = judgeAuthzUrl(input);
  process.stdout.write(`${verdict.ok ? "PASS" : "FAIL"} ${verdict.detail}\n`);
  process.exit(verdict.ok ? 0 : 1);
}
