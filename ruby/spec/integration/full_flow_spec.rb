# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "json"
require "securerandom"
require_relative "../support/keycloak_container"

RSpec.describe "Keycloak full flow", :integration do
  before(:all) do
    WebMock.allow_net_connect! # 통합에서는 실네트워크 허용
    @container = KeycloakContainer.new(fixtures_dir: File.expand_path("../fixtures", __dir__))
    @base = @container.start
  end

  after(:all) do
    @container&.stop
    WebMock.disable_net_connect!(allow_localhost: false)
  end

  let(:config) do
    KeycloakSdk::Config.new(server_url: @base, realm: "it-realm",
                            client_id: "it-client", client_secret: "it-secret")
  end
  let(:client) { KeycloakSdk::KeycloakClient.new(config) }

  it "runs client-credentials -> validate -> introspect -> CRUD -> realm CRUD -> raw -> NotFound" do
    # 1) client-credentials 토큰 + 강화 검증(다중 aud 수용 — realm fixture의 audience mapper가 it-client를 aud에 포함)
    token = client.auth.client_credentials_token
    expect(token.access_token).to be_a(String)
    validated = client.auth.validate(token.access_token)
    expect(validated.issuer).to eq("#{@base}/realms/it-realm")
    expect(validated.audience).to include("it-client")

    # 2) introspection
    intro = client.auth.introspect(token.access_token)
    expect(intro.active?).to be(true)

    # 3) user CRUD (realm fixture에 이미 "alice"가 시딩되어 있으므로 충돌을 피해 고유 사용자명 사용)
    admin = client.admin
    username = "ruby-it-user-#{SecureRandom.hex(4)}"
    uid = admin.users.create({ username: username, enabled: true, email: "#{username}@example.com" })
    expect(uid).to be_a(String)
    expect(admin.users.get(uid)["username"]).to eq(username)
    admin.users.update(uid, { firstName: "Ruby" })
    admin.users.delete(uid)
    expect { admin.users.get(uid) }.to raise_error(KeycloakSdk::NotFoundError)

    # 4) client CRUD
    cid = admin.clients.create({ clientId: "created-by-sdk", enabled: true })
    expect(admin.clients.get(cid)["clientId"]).to eq("created-by-sdk")
    admin.clients.delete(cid)

    # 5) role CRUD(name 키)
    admin.roles.create({ name: "sdk-role" })
    expect(admin.roles.get("sdk-role")["name"]).to eq("sdk-role")
    admin.roles.delete("sdk-role")

    # 6) group CRUD
    gid = admin.groups.create({ name: "sdk-group" })
    expect(admin.groups.get(gid)["name"]).to eq("sdk-group")
    admin.groups.delete(gid)

    # 7) realm CRUD via master-admin(realm SA는 403 — master bootstrap admin 토큰 사용)
    master_token = fetch_master_token
    master_tp = Struct.new(:access_token).new(master_token)
    master_admin = KeycloakSdk::Admin::AdminClient.new(config: config, token_provider: master_tp)
    master_admin.realms.create({ realm: "sdk-created-realm", enabled: true })
    expect(master_admin.realms.get("sdk-created-realm")["realm"]).to eq("sdk-created-realm")
    master_admin.realms.delete("sdk-created-realm")

    # 8) raw() 탈출구
    raw_resp = admin.raw.get("admin/realms/it-realm/users", { max: 1 })
    expect(raw_resp.status).to eq(200)
  ensure
    client&.close
  end

  private

  # master realm admin-cli 비밀번호 그랜트로 부트스트랩 토큰 획득(realm 생성 권한).
  def fetch_master_token
    uri = URI("#{@base}/realms/master/protocol/openid-connect/token")
    res = Net::HTTP.post_form(uri, grant_type: "password", client_id: "admin-cli",
                                   username: "admin", password: "admin")
    JSON.parse(res.body).fetch("access_token")
  end
end
