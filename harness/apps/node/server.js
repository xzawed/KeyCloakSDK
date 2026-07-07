import express from 'express'
import {
  KeycloakClient,
  KeycloakNotFoundError,
  KeycloakConflictError,
  KeycloakForbiddenError,
  KeycloakTokenValidationError,
} from '@xzawed/keycloak-sdk'

const env = (k, d) => process.env[k] || d
const serverUrl = env('KC_SERVER_URL', 'http://localhost:8080')
const realm = env('KC_REALM', 'it-realm')
const clientId = env('KC_CLIENT_ID', 'it-client')
const clientSecret = env('KC_CLIENT_SECRET', 'it-secret')
const kc = KeycloakClient.create({ serverUrl, realm, clientId, clientSecret })

// ROPC(Resource Owner Password Credentials)는 SDK 표면에 없다 — 하네스 앱이 Keycloak 토큰
// 엔드포인트로 직접 POST한다(8개 앱 동일 패턴, harness/apps/ruby/app.rb 참고).
let lastRefreshToken

const app = express()
app.use(express.json())
const fail = (res, code, msg) => res.status(code).json({ error: msg })

app.get('/healthz', (_req, res) => res.json({ status: 'ok' }))

app.post('/token', async (_req, res) => {
  try {
    const ts = await kc.auth.clientCredentialsToken()
    res.json({ tokenType: ts.tokenType, expiresIn: ts.expiresIn })
  } catch (e) { fail(res, 500, e.message) }
})

app.post('/validate', async (req, res) => {
  const token = req.body?.token
  if (!token) return fail(res, 400, 'token required')
  try {
    const vt = await kc.auth.validate(token)
    res.json({ subject: vt.subject, audience: vt.audience, issuer: vt.issuer, expiresAt: vt.expiresAt })
  } catch (e) {
    if (e instanceof KeycloakTokenValidationError) return fail(res, 401, e.message)
    fail(res, 500, e.message)
  }
})

app.post('/introspect', async (req, res) => {
  const token = req.body?.token
  if (!token) return fail(res, 400, 'token required')
  try {
    const ir = await kc.auth.introspect(token)
    res.json({ active: ir.active, username: ir.username, clientId: ir.clientId })
  } catch (e) { fail(res, 500, e.message) }
})

app.post('/token/password', async (req, res) => {
  const { username, password } = req.body || {}
  try {
    const resp = await fetch(`${serverUrl}/realms/${realm}/protocol/openid-connect/token`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'password',
        client_id: clientId,
        client_secret: clientSecret,
        username,
        password,
      }),
    })
    const body = await resp.json()
    if (!resp.ok) return fail(res, 401, body.error_description || body.error || 'ROPC failed')
    lastRefreshToken = body.refresh_token
    res.json({
      tokenType: body.token_type,
      expiresIn: body.expires_in,
      hasRefresh: Boolean(body.refresh_token),
    })
  } catch (e) {
    fail(res, 401, e.message)
  }
})

app.post('/refresh', async (_req, res) => {
  try {
    const ts = await kc.auth.refresh(lastRefreshToken)
    if (ts.refreshToken) lastRefreshToken = ts.refreshToken
    res.json({ tokenType: ts.tokenType, expiresIn: ts.expiresIn })
  } catch (e) {
    fail(res, 401, e.message)
  }
})

app.post('/logout', async (_req, res) => {
  try {
    await kc.auth.logout(lastRefreshToken)
    res.status(204).end()
  } catch (e) {
    fail(res, 500, e.message)
  }
})

app.get('/authz-url', (req, res) => {
  try {
    const redirectUri = req.query.redirect_uri || 'http://x/cb'
    const ar = kc.auth.createAuthorizationRequest(redirectUri)
    res.json({ url: ar.url, state: ar.state })
  } catch (e) {
    fail(res, 500, e.message)
  }
})

app.post('/admin/users', async (req, res) => {
  const { username, email } = req.body || {}
  if (!username) return fail(res, 400, 'username required')
  try {
    const admin = await kc.admin()
    const id = await admin.users.create({ username, email, enabled: true })
    res.status(201).json({ id })
  } catch (e) {
    if (e instanceof KeycloakConflictError) return fail(res, 409, e.message)
    fail(res, 500, e.message)
  }
})

app.get('/admin/users/:id', async (req, res) => {
  try {
    const admin = await kc.admin()
    const u = await admin.users.get(req.params.id)
    res.json({ id: u.id, username: u.username })
  } catch (e) {
    if (e instanceof KeycloakNotFoundError) return fail(res, 404, e.message)
    fail(res, 500, e.message)
  }
})

app.get('/admin/users', async (req, res) => {
  try {
    const admin = await kc.admin()
    const us = await admin.users.search(req.query.username, 0, 20)
    res.json(us.map((u) => ({ id: u.id, username: u.username })))
  } catch (e) { fail(res, 500, e.message) }
})

app.delete('/admin/users/:id', async (req, res) => {
  try {
    const admin = await kc.admin()
    await admin.users.delete(req.params.id)
    res.status(204).end()
  } catch (e) {
    if (e instanceof KeycloakNotFoundError) return fail(res, 404, e.message)
    fail(res, 500, e.message)
  }
})

// ---- admin: clients ----
app.post('/admin/clients', async (req, res) => {
  const { clientId } = req.body || {}
  try {
    const admin = await kc.admin()
    const id = await admin.clients.create({ clientId, enabled: true })
    res.status(201).json({ id })
  } catch (e) {
    if (e instanceof KeycloakConflictError) return fail(res, 409, e.message)
    fail(res, 500, e.message)
  }
})

app.get('/admin/clients/:id', async (req, res) => {
  try {
    const admin = await kc.admin()
    const c = await admin.clients.get(req.params.id)
    res.json({ id: c.id, clientId: c.clientId })
  } catch (e) {
    if (e instanceof KeycloakNotFoundError) return fail(res, 404, e.message)
    fail(res, 500, e.message)
  }
})

app.delete('/admin/clients/:id', async (req, res) => {
  try {
    const admin = await kc.admin()
    await admin.clients.delete(req.params.id)
    res.status(204).end()
  } catch (e) {
    if (e instanceof KeycloakNotFoundError) return fail(res, 404, e.message)
    fail(res, 500, e.message)
  }
})

// ---- admin: roles (realm role — name 키) ----
app.post('/admin/roles', async (req, res) => {
  const { name } = req.body || {}
  try {
    const admin = await kc.admin()
    await admin.roles.create({ name })
    res.status(201).json({ name })
  } catch (e) {
    if (e instanceof KeycloakConflictError) return fail(res, 409, e.message)
    fail(res, 500, e.message)
  }
})

app.get('/admin/roles/:name', async (req, res) => {
  try {
    const admin = await kc.admin()
    const r = await admin.roles.get(req.params.name)
    res.json({ name: r.name })
  } catch (e) {
    if (e instanceof KeycloakNotFoundError) return fail(res, 404, e.message)
    fail(res, 500, e.message)
  }
})

app.delete('/admin/roles/:name', async (req, res) => {
  try {
    const admin = await kc.admin()
    await admin.roles.delete(req.params.name)
    res.status(204).end()
  } catch (e) {
    if (e instanceof KeycloakNotFoundError) return fail(res, 404, e.message)
    fail(res, 500, e.message)
  }
})

// ---- admin: groups ----
app.post('/admin/groups', async (req, res) => {
  const { name } = req.body || {}
  try {
    const admin = await kc.admin()
    const id = await admin.groups.create({ name })
    res.status(201).json({ id })
  } catch (e) {
    if (e instanceof KeycloakConflictError) return fail(res, 409, e.message)
    fail(res, 500, e.message)
  }
})

app.get('/admin/groups/:id', async (req, res) => {
  try {
    const admin = await kc.admin()
    const g = await admin.groups.get(req.params.id)
    res.json({ id: g.id, name: g.name })
  } catch (e) {
    if (e instanceof KeycloakNotFoundError) return fail(res, 404, e.message)
    fail(res, 500, e.message)
  }
})

app.delete('/admin/groups/:id', async (req, res) => {
  try {
    const admin = await kc.admin()
    await admin.groups.delete(req.params.id)
    res.status(204).end()
  } catch (e) {
    if (e instanceof KeycloakNotFoundError) return fail(res, 404, e.message)
    fail(res, 500, e.message)
  }
})

// ---- admin: realms (master 전용 — 하네스는 realm SA라 항상 403 예상) ----
app.post('/admin/realms', async (req, res) => {
  const { realm: newRealm } = req.body || {}
  try {
    const admin = await kc.admin()
    await admin.realms.create({ realm: newRealm, enabled: true })
    res.status(201).json({ realm: newRealm })
  } catch (e) {
    if (e instanceof KeycloakForbiddenError) return fail(res, 403, e.message)
    fail(res, 500, e.message)
  }
})

const port = env('APP_PORT', '8090')
app.listen(Number(port), () => console.log(`listening on ${port}`))
