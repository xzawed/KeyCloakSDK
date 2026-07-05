import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';

const BASE = __ENV.BASE_URL || 'http://localhost:8090';
const KC = __ENV.KC_URL || 'http://localhost:8080';
const LANG = __ENV.LANG || 'go';
const REALM = __ENV.KC_REALM || 'it-realm';
const CLIENT = __ENV.KC_CLIENT_ID || 'it-client';
const SECRET = __ENV.KC_CLIENT_SECRET || 'it-secret';

const validateDur = new Trend('validate_duration', true);
const introspectDur = new Trend('introspect_duration', true);
const tokenDur = new Trend('token_duration', true);
const adminDur = new Trend('admin_crud_duration', true);

export const options = {
  vus: Number(__ENV.VUS || 10),
  duration: __ENV.DURATION || '30s',
  thresholds: { checks: ['rate==1.00'] },   // 기능 정확성 게이트: 100% 아니면 비0 종료
};

const JSON_H = { headers: { 'Content-Type': 'application/json' } };

// 각 VU가 자체 토큰을 1회 획득(반복 내 재사용). client-credentials → aud에 it-client 포함(realm aud 매퍼).
function getToken() {
  const res = http.post(`${KC}/realms/${REALM}/protocol/openid-connect/token`,
    { grant_type: 'client_credentials', client_id: CLIENT, client_secret: SECRET });
  check(res, { 'kc token 200': (r) => r.status === 200 });
  return res.json('access_token');
}

let token;
export default function () {
  if (!token) token = getToken();

  const v = http.post(`${BASE}/validate`, JSON.stringify({ token }), JSON_H);
  validateDur.add(v.timings.duration);
  check(v, {
    'validate 200': (r) => r.status === 200,
    'validate subject': (r) => !!r.json('subject'),
    'validate aud has client': (r) => (r.json('audience') || []).includes(CLIENT),
    'validate issuer': (r) => String(r.json('issuer') || '').endsWith(`/realms/${REALM}`),
  });

  const i = http.post(`${BASE}/introspect`, JSON.stringify({ token }), JSON_H);
  introspectDur.add(i.timings.duration);
  check(i, { 'introspect 200': (r) => r.status === 200, 'introspect active': (r) => r.json('active') === true });

  const t = http.post(`${BASE}/token`, null);
  tokenDur.add(t.timings.duration);
  check(t, { 'token 200': (r) => r.status === 200, 'token expiresIn>0': (r) => Number(r.json('expiresIn')) > 0 });

  // admin 여정: create → get → delete → get=404
  const uname = `vu-${LANG}-${__VU}-${__ITER}`;
  const c = http.post(`${BASE}/admin/users`, JSON.stringify({ username: uname, email: `${uname}@e.com` }), JSON_H);
  const adminStart = Date.now();
  const created = check(c, { 'create 201': (r) => r.status === 201, 'create id': (r) => !!r.json('id') });
  if (created) {
    const id = c.json('id');
    const g = http.get(`${BASE}/admin/users/${id}`);
    check(g, { 'get 200': (r) => r.status === 200, 'get username': (r) => r.json('username') === uname });
    const d = http.del(`${BASE}/admin/users/${id}`);
    check(d, { 'delete 204': (r) => r.status === 204 });
    const g2 = http.get(`${BASE}/admin/users/${id}`);
    check(g2, { 'get-after-delete 404': (r) => r.status === 404 });
  }
  adminDur.add(Date.now() - adminStart);
}

export function handleSummary(data) {
  return { [`/report/${LANG}.json`]: JSON.stringify(data) };
}
