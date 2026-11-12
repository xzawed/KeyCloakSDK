# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "json"
require "securerandom"
require_relative "../support/keycloak_container"

RSpec.describe "Keycloak full flow", :integration do
  before(:all) do
    WebMock.allow_net_connect! # 통합에서는 실네트워크 허용
    # 컨테이너는 통합 스펙 파일들이 나눠 쓴다(정리는 support 의 after(:suite)).
    @base = KeycloakContainer.shared_base_url(fixtures_dir: File.expand_path("../fixtures", __dir__))
  end

  after(:all) do
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
    expect(admin.users.list(username: username, exact: true).map { |u| u["id"] }).to include(uid)
    admin.users.update(uid, { firstName: "Ruby" })
    expect(admin.users.get(uid)["firstName"]).to eq("Ruby")
    admin.users.delete(uid)
    expect { admin.users.get(uid) }.to raise_error(KeycloakSdk::NotFoundError)

    # 4) client CRUD — 목록은 clientId 필터, 갱신은 내부 uuid 로 주소를 잡는다
    cid = admin.clients.create({ clientId: "created-by-sdk", enabled: true })
    expect(admin.clients.get(cid)["clientId"]).to eq("created-by-sdk")
    expect(admin.clients.list(clientId: "created-by-sdk").map { |c| c["id"] }).to include(cid)
    admin.clients.update(cid, { clientId: "created-by-sdk", description: "updated by ruby it" })
    expect(admin.clients.get(cid)["description"]).to eq("updated by ruby it")
    admin.clients.delete(cid)
    expect { admin.clients.get(cid) }.to raise_error(KeycloakSdk::NotFoundError)

    # 5) role CRUD(name 키) — 갱신은 현재 이름으로 주소를 잡고, body 가 이름을 그대로 나른다(rename 계약)
    admin.roles.create({ name: "sdk-role" })
    expect(admin.roles.get("sdk-role")["name"]).to eq("sdk-role")
    expect(admin.roles.list(search: "sdk-role").map { |r| r["name"] }).to include("sdk-role")
    admin.roles.update("sdk-role", { name: "sdk-role", description: "updated by ruby it" })
    expect(admin.roles.get("sdk-role")["description"]).to eq("updated by ruby it")
    admin.roles.delete("sdk-role")
    expect { admin.roles.get("sdk-role") }.to raise_error(KeycloakSdk::NotFoundError)

    # 6) group CRUD — 갱신은 id 로 주소를 잡고 body 가 새 이름을 나른다
    gid = admin.groups.create({ name: "sdk-group" })
    expect(admin.groups.get(gid)["name"]).to eq("sdk-group")
    expect(admin.groups.list(search: "sdk-group").map { |g| g["id"] }).to include(gid)
    admin.groups.update(gid, { name: "sdk-group-renamed" })
    expect(admin.groups.get(gid)["name"]).to eq("sdk-group-renamed")
    admin.groups.delete(gid)
    expect { admin.groups.get(gid) }.to raise_error(KeycloakSdk::NotFoundError)

    # 7) realm CRUD via master-admin(realm SA는 403 — master bootstrap admin 토큰 사용) — 버리는 realm 은 고유 이름이다
    master_token = fetch_master_token
    master_tp = Struct.new(:access_token).new(master_token)
    master_admin = KeycloakSdk::Admin::AdminClient.new(config: config, token_provider: master_tp)
    realm_name = "ruby-it-realm-#{SecureRandom.hex(4)}"
    master_admin.realms.create({ realm: realm_name, enabled: true })
    expect(master_admin.realms.get(realm_name)["realm"]).to eq(realm_name)
    expect(master_admin.realms.list.map { |r| r["realm"] }).to include(realm_name)
    master_admin.realms.update(realm_name, { realm: realm_name, displayName: "updated by ruby it" })
    expect(master_admin.realms.get(realm_name)["displayName"]).to eq("updated by ruby it")
    master_admin.realms.delete(realm_name)
    expect { master_admin.realms.get(realm_name) }.to raise_error(KeycloakSdk::NotFoundError)

    # 8) raw() 탈출구
    raw_resp = admin.raw.get("admin/realms/it-realm/users", { max: 1 })
    expect(raw_resp.status).to eq(200)
  ensure
    # 단언이 중간에 실패해도 만든 것을 지운다(컨테이너는 스펙 파일들이 나눠 쓴다). 끝까지 돌았으면 이미 없다(NotFoundError).
    best_effort { admin.users.delete(uid) } if uid
    best_effort { admin.clients.delete(cid) } if cid
    best_effort { admin.roles.delete("sdk-role") } if admin
    best_effort { admin.groups.delete(gid) } if gid
    best_effort { master_admin.realms.delete(realm_name) } if realm_name
    master_admin&.close
    client&.close
  end

  private

  # 정리는 원래 실패를 가리지 않는다 — 이미 지워졌으면 조용히 넘기고, 그 밖의 SDK 오류는 경고만 남긴다.
  def best_effort
    yield
  rescue KeycloakSdk::NotFoundError
    nil
  rescue KeycloakSdk::Error => e
    warn("integration cleanup failed: #{e.class}: #{e.message}")
  end

  # master realm admin-cli 비밀번호 그랜트로 부트스트랩 토큰 획득(realm 생성 권한).
  def fetch_master_token
    uri = URI("#{@base}/realms/master/protocol/openid-connect/token")
    res = Net::HTTP.post_form(uri, grant_type: "password", client_id: "admin-cli",
                                   username: "admin", password: "admin")
    JSON.parse(res.body).fetch("access_token")
  end
end
