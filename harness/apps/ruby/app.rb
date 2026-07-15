# frozen_string_literal: true

require "sinatra/base"
require "json"
require "keycloak_sdk"

CFG = KeycloakSdk::Config.new(
  server_url: ENV.fetch("KC_SERVER_URL"),
  realm: ENV.fetch("KC_REALM"),
  client_id: ENV.fetch("KC_CLIENT_ID"),
  client_secret: ENV.fetch("KC_CLIENT_SECRET")
)
KC = KeycloakSdk::KeycloakClient.new(CFG)
SESS = {} # 서버측 refresh 토큰 보관(logout/refresh 자동화용) — 단일 프로세스 데모 하네스 전용

# ROPC(Resource Owner Password Credentials)는 SDK 표면에 없다(SDK 표면 불변 원칙 —
# task 브리프 (b) 경로 채택). 하네스 앱이 Keycloak 토큰 엔드포인트로 직접 POST한다(8개 앱 동일 패턴).
# KeycloakSdk::Http.build를 재사용해 SDK 내부와 동일한 타임아웃/무-리다이렉트 하드닝을 얻는다.
ROPC_HTTP = KeycloakSdk::Http.build(CFG, base_url: "#{CFG.server_url}/") do |f|
  f.request :url_encoded
  f.response :json, content_type: /\bjson$/
end

class App < Sinatra::Base
  set :port, ENV.fetch("APP_PORT", "8090").to_i
  set :bind, "0.0.0.0"
  # Sinatra 4.x는 Rack::Protection::HostAuthorization를 기본 활성화해, Host 헤더가 기본 허용목록
  # (localhost 등)에 없으면 모든 요청을 403("Host not permitted")으로 거부한다. 하네스의 conformance·
  # k6·verify.sh는 전부 compose DNS명(http://app-ruby:8090)으로 접근하므로 Host가 `app-ruby:8090`이 되어
  # healthz까지 전멸했다(defect C: 2/26 — KC 직접호출 1 + realms-403 우연통과 1만 남음). rack-protection
  # host_authorization의 accepts?는 permitted_hosts가 비면 true를 반환하므로, 빈 배열로 전체 허용한다
  # (신뢰된 하네스 네트워크 전용 — 프로덕션 앱이라면 실제 호스트를 명시할 것. 다른 8개 앱 프레임워크는
  # 호스트 인증을 기본 강제하지 않아 무영향).
  set :host_authorization, { permitted_hosts: [] }
  before { content_type :json }

  helpers do
    def body_json
      JSON.parse(request.body.read)
    rescue StandardError
      {}
    end

    def err(code, msg)
      status code
      { error: msg }.to_json
    end

    # KeycloakSdk 오류 → HTTP 상태(계약 오류 매핑 규약).
    def map_admin(e)
      case e
      when KeycloakSdk::NotFoundError then 404
      when KeycloakSdk::ConflictError then 409
      when KeycloakSdk::ForbiddenError then 403
      else 500
      end
    end

    def ropc_token(username, password)
      resp = ROPC_HTTP.post("realms/#{CFG.realm}/protocol/openid-connect/token", {
                               grant_type: "password",
                               client_id: CFG.client_id,
                               client_secret: CFG.client_secret,
                               username: username,
                               password: password
                             })
      raise "ROPC(password) grant failed: HTTP #{resp.status}" unless resp.success?

      resp.body
    rescue Faraday::Error => e
      raise "ROPC transport error: #{e.message}"
    end
  end

  get("/healthz") { { status: "ok" }.to_json }

  post "/token" do
    t = KC.auth.client_credentials_token
    { tokenType: t.token_type, expiresIn: t.expires_in }.to_json
  rescue StandardError => e
    err(500, e.message)
  end

  post "/token/password" do
    b = body_json
    body = ropc_token(b["username"], b["password"])
    SESS[:refresh] = body["refresh_token"]
    { tokenType: body["token_type"], expiresIn: body["expires_in"],
      hasRefresh: !body["refresh_token"].nil? }.to_json
  rescue StandardError => e
    err(401, e.message)
  end

  post "/refresh" do
    t = KC.auth.refresh(refresh_token: SESS[:refresh])
    SESS[:refresh] = t.refresh_token if t.refresh_token
    { tokenType: t.token_type, expiresIn: t.expires_in }.to_json
  rescue StandardError => e
    err(401, e.message)
  end

  post "/logout" do
    KC.auth.logout(refresh_token: SESS[:refresh])
    status 204
  rescue StandardError => e
    err(500, e.message)
  end

  get "/authz-url" do
    r = KC.auth.create_authorization_request(redirect_uri: params["redirect_uri"] || "http://x/cb")
    { url: r.url, state: r.state }.to_json
  rescue StandardError => e
    err(500, e.message)
  end

  post "/validate" do
    v = KC.auth.validate(body_json["token"])
    { subject: v.subject, audience: v.audience, issuer: v.issuer, expiresAt: v.expires_at }.to_json
  rescue StandardError => e
    err(401, e.message)
  end

  post "/introspect" do
    r = KC.auth.introspect(body_json["token"])
    { active: r.active?, username: r.username, clientId: r.client_id }.to_json
  rescue StandardError => e
    err(500, e.message)
  end

  # ---- admin: users ----
  post "/admin/users" do
    b = body_json
    id = KC.admin.users.create({ username: b["username"], email: b["email"], enabled: true })
    status 201
    { id: id }.to_json
  rescue StandardError => e
    err(map_admin(e), e.message)
  end

  get "/admin/users/:id" do
    u = KC.admin.users.get(params["id"])
    { id: u["id"], username: u["username"] }.to_json
  rescue StandardError => e
    err(map_admin(e), e.message)
  end

  get "/admin/users" do
    q = {}
    q[:username] = params["username"] if params["username"] && !params["username"].empty?
    KC.admin.users.list(**q).map { |u| { id: u["id"], username: u["username"] } }.to_json
  rescue StandardError => e
    err(map_admin(e), e.message)
  end

  delete "/admin/users/:id" do
    KC.admin.users.delete(params["id"])
    status 204
  rescue StandardError => e
    err(map_admin(e), e.message)
  end

  # ---- admin: clients ----
  post "/admin/clients" do
    id = KC.admin.clients.create({ clientId: body_json["clientId"], enabled: true })
    status 201
    { id: id }.to_json
  rescue StandardError => e
    err(map_admin(e), e.message)
  end

  get "/admin/clients/:id" do
    c = KC.admin.clients.get(params["id"])
    { id: c["id"], clientId: c["clientId"] }.to_json
  rescue StandardError => e
    err(map_admin(e), e.message)
  end

  delete "/admin/clients/:id" do
    KC.admin.clients.delete(params["id"])
    status 204
  rescue StandardError => e
    err(map_admin(e), e.message)
  end

  # ---- admin: roles (realm role — client role 아님·name 키) ----
  post "/admin/roles" do
    name = body_json["name"]
    KC.admin.roles.create({ name: name })
    status 201
    { name: name }.to_json
  rescue StandardError => e
    err(map_admin(e), e.message)
  end

  get "/admin/roles/:name" do
    r = KC.admin.roles.get(params["name"])
    { name: r["name"] }.to_json
  rescue StandardError => e
    err(map_admin(e), e.message)
  end

  delete "/admin/roles/:name" do
    KC.admin.roles.delete(params["name"])
    status 204
  rescue StandardError => e
    err(map_admin(e), e.message)
  end

  # ---- admin: groups ----
  post "/admin/groups" do
    id = KC.admin.groups.create({ name: body_json["name"] })
    status 201
    { id: id }.to_json
  rescue StandardError => e
    err(map_admin(e), e.message)
  end

  get "/admin/groups/:id" do
    g = KC.admin.groups.get(params["id"])
    { id: g["id"], name: g["name"] }.to_json
  rescue StandardError => e
    err(map_admin(e), e.message)
  end

  delete "/admin/groups/:id" do
    KC.admin.groups.delete(params["id"])
    status 204
  rescue StandardError => e
    err(map_admin(e), e.message)
  end

  # ---- admin: realms (master 전용 — 하네스는 realm SA라 항상 403, CONTRACT.md 참고) ----
  post "/admin/realms" do
    realm = body_json["realm"]
    KC.admin.realms.create({ realm: realm, enabled: true })
    status 201
    { realm: realm }.to_json
  rescue StandardError => e
    err(map_admin(e), e.message)
  end
end

App.run! if __FILE__ == $PROGRAM_NAME
