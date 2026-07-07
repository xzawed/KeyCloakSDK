// 보안 하드닝 프로브. 앱 /validate에 적대적 토큰을 주입해 "거부(401)되어야 함"을 검증 + 마스킹 스캔.
import crypto from "node:crypto";
import fs from "node:fs";
const BASE = process.env.BASE, LANG = process.env.LANG || "unknown";
const probes = [];
const rec = (name, defended, detail = "") => probes.push({ name, defended, detail: String(detail).slice(0, 200) });
const b64u = (buf) => Buffer.from(buf).toString("base64url");
const seg = (obj) => b64u(JSON.stringify(obj));

async function validate(token) {
  const r = await fetch(BASE + "/validate", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token }) });
  let body = ""; try { body = await r.text(); } catch {}
  return { status: r.status, body };
}
// "거부되어야 함" = 200이 아니면 방어 성공(정상은 401). 200이면 BYPASS(방어 실패).
const expectReject = async (name, token) => { const r = await validate(token); rec(name, r.status !== 200, `status=${r.status}`); };

const run = async () => {
  const now = Math.floor(Date.now() / 1000);
  const claims = { sub: "attacker", iss: `${process.env.KC_URL}/realms/it-realm`, aud: "it-client", exp: now + 3600, iat: now };

  // 1) alg=none
  await expectReject("alg=none rejected", `${seg({ alg: "none", typ: "JWT" })}.${seg(claims)}.`);

  // 2) alg=HS256 (RS/HS confusion — 공격자 임의 시크릿 서명)
  {
    const h = seg({ alg: "HS256", typ: "JWT", kid: "test-key-1" }), p = seg(claims);
    const sig = crypto.createHmac("sha256", "attacker-secret").update(`${h}.${p}`).digest("base64url");
    await expectReject("alg=HS256 confusion rejected", `${h}.${p}.${sig}`);
  }

  // 3) RS256 signed by an UNKNOWN key (kid not in realm JWKS) — 서명은 유효하나 키 미해결
  {
    const { privateKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
    const h = seg({ alg: "RS256", typ: "JWT", kid: "attacker-kid-" + Date.now() }), p = seg(claims);
    const sig = crypto.sign("RSA-SHA256", Buffer.from(`${h}.${p}`), privateKey).toString("base64url");
    await expectReject("RS256 unknown-kid rejected", `${h}.${p}.${sig}`);
  }

  // 4) RS256 with NO kid header (일부 검증기가 kid 없으면 첫 키로 폴백하는 취약)
  {
    const { privateKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
    const h = seg({ alg: "RS256", typ: "JWT" }), p = seg(claims);
    const sig = crypto.sign("RSA-SHA256", Buffer.from(`${h}.${p}`), privateKey).toString("base64url");
    await expectReject("RS256 missing-kid rejected", `${h}.${p}.${sig}`);
  }

  // 5) malformed
  await expectReject("malformed rejected", "not.a.valid.jwt");
  await expectReject("empty rejected", "");

  // 6) 마스킹 — 응답에 원문 JWT/시크릿 미노출
  {
    const t = await (await fetch(BASE + "/token", { method: "POST" })).text();
    const leaksJwt = /eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\./.test(t); // JWT 3-세그먼트 패턴
    const leaksSecret = /it-secret/.test(t);
    rec("masking: /token no raw jwt/secret", !leaksJwt && !leaksSecret, leaksJwt ? "jwt leaked" : leaksSecret ? "secret leaked" : "ok");
  }

  // 7) DoS-safe JWKS 관찰(선택·부분): 위조 kid 폭주 시 앱→KC certs 히트가 폭증하지 않아야(정확 카운트는 KC 로그 필요 — 여기선 앱이 죽지 않고 계속 401을 반환하는지만)
  {
    let allRejected = true;
    for (let i = 0; i < 10; i++) { const r = await validate(`${seg({ alg: "RS256", kid: "flood-" + i })}.${seg(claims)}.x`); if (r.status === 200) allRejected = false; }
    rec("forged-kid flood stays rejected (no crash)", allRejected, "10x forged");
  }

  const defended = probes.filter(p => p.defended).length;
  fs.writeFileSync(`/out/${LANG}.security.json`, JSON.stringify({ lang: LANG, probes, defended, total: probes.length }, null, 2));
  console.log(`[security ${LANG}] ${defended}/${probes.length} defended`);
  process.exit(defended < probes.length ? 1 : 0);
};
run().catch(e => { console.error(e); process.exit(2); });
