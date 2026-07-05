import express from 'express'
import {
  KeycloakClient,
  KeycloakNotFoundError,
  KeycloakConflictError,
  KeycloakTokenValidationError,
} from '@xzawed/keycloak-sdk'

const env = (k, d) => process.env[k] || d
const kc = KeycloakClient.create({
  serverUrl: env('KC_SERVER_URL', 'http://localhost:8080'),
  realm: env('KC_REALM', 'it-realm'),
  clientId: env('KC_CLIENT_ID', 'it-client'),
  clientSecret: env('KC_CLIENT_SECRET', 'it-secret'),
})

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

const port = env('APP_PORT', '8090')
app.listen(Number(port), () => console.log(`listening on ${port}`))
