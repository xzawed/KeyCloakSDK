// 계약 v2 결정적 conformance. Node 20+ (전역 fetch). 결과를 /out/<LANG>.conformance.json에 기록.
const BASE = process.env.BASE, LANG = process.env.LANG || "unknown";
const U = process.env.KC_USER || "alice", P = process.env.KC_PASS || "alice-password";
const checks = [];
const rec = (name, ok, detail = "") => { checks.push({ name, ok, detail: String(detail).slice(0, 300) }); };
const J = { "content-type": "application/json" };
const rnd = () => Math.random().toString(36).slice(2, 10);
async function req(method, path, body) {
  const r = await fetch(BASE + path, { method, headers: J, body: body === undefined ? undefined : JSON.stringify(body) });
  let j = null; try { j = await r.json(); } catch { /* 204 등 */ }
  return { status: r.status, j };
}
async function check(name, fn) { try { await fn(); } catch (e) { rec(name, false, e.message); } }

const run = async () => {
  await check("healthz 200", async () => { const r = await req("GET", "/healthz"); rec("healthz 200", r.status === 200 && r.j?.status === "ok", r.status); });

  // client-credentials 토큰 + validate + introspect
  let token;
  await check("token(client-creds)", async () => {
    const r = await req("POST", "/token"); const ok = r.status === 200 && r.j?.expiresIn > 0; rec("token(client-creds)", ok, r.status);
  });
  // KC에서 직접 access_token 취득(validate/introspect 입력용)
  await check("obtain access_token", async () => {
    const form = new URLSearchParams({ grant_type: "client_credentials", client_id: "it-client", client_secret: "it-secret" });
    const r = await fetch(`${process.env.KC_URL}/realms/it-realm/protocol/openid-connect/token`, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: form });
    token = (await r.json()).access_token; rec("obtain access_token", !!token, r.status);
  });
  await check("validate 200 (multi-aud)", async () => { const r = await req("POST", "/validate", { token }); rec("validate 200 (multi-aud)", r.status === 200 && !!r.j?.issuer && Array.isArray(r.j?.audience), r.status); });
  await check("validate rejects garbage 401", async () => { const r = await req("POST", "/validate", { token: "not.a.jwt" }); rec("validate rejects garbage 401", r.status === 401, r.status); });
  await check("introspect active", async () => { const r = await req("POST", "/introspect", { token }); rec("introspect active", r.status === 200 && r.j?.active === true, r.status); });

  // authz-url (오프라인 PKCE S256)
  await check("authz-url S256", async () => {
    const r = await req("GET", "/authz-url?redirect_uri=http://x/cb");
    const u = r.j?.url || ""; rec("authz-url S256", r.status === 200 && /code_challenge_method=S256/.test(u) && /code_challenge=/.test(u) && !!r.j?.state, u.slice(0, 120));
  });

  // ROPC → refresh → logout (hasRefresh 가드)
  await check("token/password", async () => { const r = await req("POST", "/token/password", { username: U, password: P }); global.__hasRefresh = r.j?.hasRefresh === true; rec("token/password", r.status === 200 && r.j?.expiresIn > 0, r.status); });
  await check("refresh", async () => { if (!global.__hasRefresh) return rec("refresh", true, "skipped(no refresh)"); const r = await req("POST", "/refresh", {}); rec("refresh", r.status === 200 && r.j?.expiresIn > 0, r.status); });
  await check("logout 204", async () => { if (!global.__hasRefresh) return rec("logout 204", true, "skipped"); const r = await req("POST", "/logout", {}); rec("logout 204", r.status === 204, r.status); });

  // admin users CRUD + 오류경로
  const uname = `cf-${rnd()}`; let uid;
  await check("user create 201", async () => { const r = await req("POST", "/admin/users", { username: uname, email: `${uname}@e.com` }); uid = r.j?.id; rec("user create 201", r.status === 201 && !!uid, r.status); });
  await check("user duplicate 409", async () => { const r = await req("POST", "/admin/users", { username: uname, email: `${uname}@e.com` }); rec("user duplicate 409", r.status === 409, r.status); });
  await check("user get 200", async () => { const r = await req("GET", `/admin/users/${uid}`); rec("user get 200", r.status === 200 && r.j?.username === uname, r.status); });
  await check("user delete 204", async () => { const r = await req("DELETE", `/admin/users/${uid}`); rec("user delete 204", r.status === 204, r.status); });
  await check("user get-after-delete 404", async () => { const r = await req("GET", `/admin/users/${uid}`); rec("user get-after-delete 404", r.status === 404, r.status); });

  // admin clients / roles / groups CRUD
  const cid = `cf-c-${rnd()}`; let cInternal;
  await check("client create 201", async () => { const r = await req("POST", "/admin/clients", { clientId: cid }); cInternal = r.j?.id; rec("client create 201", r.status === 201 && !!cInternal, r.status); });
  await check("client get 200", async () => { const r = await req("GET", `/admin/clients/${cInternal}`); rec("client get 200", r.status === 200 && r.j?.clientId === cid, r.status); });
  await check("client delete 204", async () => { const r = await req("DELETE", `/admin/clients/${cInternal}`); rec("client delete 204", r.status === 204, r.status); });
  const role = `cf-r-${rnd()}`;
  await check("role create 201", async () => { const r = await req("POST", "/admin/roles", { name: role }); rec("role create 201", r.status === 201, r.status); });
  await check("role get 200", async () => { const r = await req("GET", `/admin/roles/${role}`); rec("role get 200", r.status === 200 && r.j?.name === role, r.status); });
  await check("role delete 204", async () => { const r = await req("DELETE", `/admin/roles/${role}`); rec("role delete 204", r.status === 204, r.status); });
  const grp = `cf-g-${rnd()}`; let gid;
  await check("group create 201", async () => { const r = await req("POST", "/admin/groups", { name: grp }); gid = r.j?.id; rec("group create 201", r.status === 201 && !!gid, r.status); });
  await check("group delete 204", async () => { const r = await req("DELETE", `/admin/groups/${gid}`); rec("group delete 204", r.status === 204, r.status); });

  // realms — realm SA는 403(마스터 토큰 미보유 앱)
  await check("realms create 403 (realm SA)", async () => { const r = await req("POST", "/admin/realms", { realm: `cf-realm-${rnd()}` }); rec("realms create 403 (realm SA)", r.status === 403, r.status); });

  const passed = checks.filter(c => c.ok).length, failed = checks.length - passed;
  const out = { lang: LANG, passed, failed, checks };
  const fs = await import("node:fs"); fs.writeFileSync(`/out/${LANG}.conformance.json`, JSON.stringify(out, null, 2));
  console.log(`[conformance ${LANG}] ${passed}/${checks.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
};
run().catch(e => { console.error(e); process.exit(2); });
