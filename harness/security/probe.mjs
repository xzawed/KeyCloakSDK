// 보안 하드닝 프로브. 앱 /validate에 적대적 토큰을 주입해 "거부(401)되어야 함"을 검증 + 마스킹 스캔.
import crypto from "node:crypto";
import fs from "node:fs";
const BASE = process.env.BASE, LANG = process.env.LANG || "unknown";
const KC_URL = process.env.KC_URL;
const probes = [];
const rec = (name, defended, detail = "") => probes.push({ name, defended, detail: String(detail).slice(0, 200) });
const b64u = (buf) => Buffer.from(buf).toString("base64url");
const seg = (obj) => b64u(JSON.stringify(obj));

// 프로브 하나가 던지는 예외가 전체 실행을 무너뜨리지 않도록 격리한다 —
// 실패한 프로브는 defended:false로 기록하고 나머지는 계속 진행, 시그널 파일은 항상 기록된다.
async function probe(name, fn) {
  try {
    await fn();
  } catch (e) {
    rec(name, false, "probe error: " + e.message);
  }
}

async function validate(token) {
  const r = await fetch(BASE + "/validate", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token }) });
  let body = ""; try { body = await r.text(); } catch {}
  return { status: r.status, body };
}
// "거부되어야 함" = 200이 아니면 방어 성공(정상은 401). 200이면 BYPASS(방어 실패).
const expectReject = async (name, token) => { const r = await validate(token); rec(name, r.status !== 200, `status=${r.status}`); };

const run = async () => {
  const now = Math.floor(Date.now() / 1000);
  const claims = { sub: "attacker", iss: `${KC_URL}/realms/it-realm`, aud: "it-client", exp: now + 3600, iat: now };

  // 1) alg=none
  await probe("alg=none rejected", () =>
    expectReject("alg=none rejected", `${seg({ alg: "none", typ: "JWT" })}.${seg(claims)}.`));

  // 2) alg=HS256 (RS/HS confusion — 공격자 임의 시크릿 서명)
  await probe("alg=HS256 confusion rejected", async () => {
    const h = seg({ alg: "HS256", typ: "JWT", kid: "test-key-1" }), p = seg(claims);
    const sig = crypto.createHmac("sha256", "attacker-secret").update(`${h}.${p}`).digest("base64url");
    await expectReject("alg=HS256 confusion rejected", `${h}.${p}.${sig}`);
  });

  // 2b) RS/HS confusion — realm의 실제 RSA 공개키 바이트를 HMAC 시크릿으로 사용(고전적 alg-confusion 공격).
  // 헤더 alg를 신뢰해 kid로 찾은 "키"를 그대로 HMAC 검증에 쓰는 하드닝 안 된 검증기를 겨냥한다.
  await probe("RS/HS confusion (realm pubkey as HMAC) rejected", async () => {
    const jwksRes = await fetch(`${KC_URL}/realms/it-realm/protocol/openid-connect/certs`);
    if (!jwksRes.ok) throw new Error(`JWKS fetch failed status=${jwksRes.status}`);
    const jwks = await jwksRes.json();
    const rsKey = (jwks.keys || []).find(k => k.kty === "RSA" && (k.alg === "RS256" || k.use === "sig"));
    if (!rsKey) throw new Error("no RS256 signing key found in realm JWKS");
    const pubKey = crypto.createPublicKey({ key: rsKey, format: "jwk" });
    const pem = pubKey.export({ type: "spki", format: "pem" });
    const h = seg({ alg: "HS256", typ: "JWT", kid: rsKey.kid }), p = seg(claims);
    const sig = crypto.createHmac("sha256", pem).update(`${h}.${p}`).digest("base64url");
    await expectReject("RS/HS confusion (realm pubkey as HMAC) rejected", `${h}.${p}.${sig}`);
  });

  // 3) RS256 signed by an UNKNOWN key (kid not in realm JWKS) — 서명은 유효하나 키 미해결
  await probe("RS256 unknown-kid rejected", async () => {
    const { privateKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
    const h = seg({ alg: "RS256", typ: "JWT", kid: "attacker-kid-" + Date.now() }), p = seg(claims);
    const sig = crypto.sign("RSA-SHA256", Buffer.from(`${h}.${p}`), privateKey).toString("base64url");
    await expectReject("RS256 unknown-kid rejected", `${h}.${p}.${sig}`);
  });

  // 4) RS256 with NO kid header (일부 검증기가 kid 없으면 첫 키로 폴백하는 취약)
  await probe("RS256 missing-kid rejected", async () => {
    const { privateKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
    const h = seg({ alg: "RS256", typ: "JWT" }), p = seg(claims);
    const sig = crypto.sign("RSA-SHA256", Buffer.from(`${h}.${p}`), privateKey).toString("base64url");
    await expectReject("RS256 missing-kid rejected", `${h}.${p}.${sig}`);
  });

  // 5) malformed
  await probe("malformed rejected", () => expectReject("malformed rejected", "not.a.valid.jwt"));
  await probe("empty rejected", () => expectReject("empty rejected", ""));

  // 6) 마스킹 — /token이 실제로 성공(200 + 기대 메타데이터 형태)했을 때만 마스킹 검증이 유효하다.
  // /token이 실패(예: 500)하면 에러 바디에는 애초에 JWT/시크릿이 없으므로 "누출 없음"이 공허하게 참이 된다 —
  // 이를 defended:true로 잘못 기록하지 않도록 200 + 메타데이터 형태를 선행 게이트한다.
  await probe("masking: /token no raw jwt/secret", async () => {
    const res = await fetch(BASE + "/token", { method: "POST" });
    const t = await res.text();
    if (res.status !== 200) {
      rec("masking: /token no raw jwt/secret", false, `/token status=${res.status}`);
      return;
    }
    let parsed = null;
    try { parsed = JSON.parse(t); } catch { /* non-JSON body handled below */ }
    const hasMeta = !!parsed && typeof parsed === "object" && "tokenType" in parsed && "expiresIn" in parsed;
    if (!hasMeta) {
      rec("masking: /token no raw jwt/secret", false, `/token status=200 but missing tokenType/expiresIn`);
      return;
    }
    const leaksJwt = /eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\./.test(t); // JWT 3-세그먼트 패턴
    const leaksSecret = /it-secret/.test(t);
    rec("masking: /token no raw jwt/secret", !leaksJwt && !leaksSecret, leaksJwt ? "jwt leaked" : leaksSecret ? "secret leaked" : "ok");
  });

  // 7) DoS-safe JWKS 관찰(선택·부분): 위조 kid 폭주 시 앱이 죽지 않고 계속 거부하는지 + 실제 관측된 상태코드 분포 기록
  await probe("forged-kid flood stays rejected (no crash)", async () => {
    const statuses = new Set();
    let allRejected = true;
    for (let i = 0; i < 10; i++) {
      const r = await validate(`${seg({ alg: "RS256", kid: "flood-" + i })}.${seg(claims)}.x`);
      statuses.add(r.status);
      if (r.status === 200) allRejected = false;
    }
    rec("forged-kid flood stays rejected (no crash)", allRejected, `10x forged, statuses=${[...statuses].sort().join(",")}`);
  });

  const defended = probes.filter(p => p.defended).length;
  fs.writeFileSync(`/out/${LANG}.security.json`, JSON.stringify({ lang: LANG, probes, defended, total: probes.length }, null, 2));
  console.log(`[security ${LANG}] ${defended}/${probes.length} defended`);
  process.exit(defended < probes.length ? 1 : 0);
};
run().catch(e => { console.error(e); process.exit(2); });
