# frozen_string_literal: true

require "spec_helper"
require_relative "../support/body_server"

# Location 없는 3xx 는 admin 파사드 호출의 결과가 아니다 — 오류다(등록부 go-admin-3xx-read-as-success 부류 재스캔, ruby 칸).
#
# go 는 파사드 호출 25 중 24 가 3xx 에 0 값을 돌려줬고 php 는 302 에 User 를 돌려줬다. ruby 는 2026-10-26/27 에 한 칸
# (`admin_response_body_spec.rb` 의 300 행)만 쟀다. 여기서는 통합 admin 표면 스위트가 도는 25 연산 전부(다섯 리소스 × create ·
# get · list · update · delete)를 300 · 302(Location 없음) · 399 로 잰다. 본문은 그 호출의 성공 본문 모양인 유효한 JSON 이다
# (get · create · update · delete 는 객체, list 는 배열). 토큰 엔드포인트는 정상으로 답한다 — 칸마다 진짜 그랜트를 거친다.
#
# 칸마다 오류 클래스(`AdminError` 그 자체 — 404 가 받는 계층, 하위 클래스 아님)와 그 상태를 **함께** 본다. 전송 · 해석 오류는
# 실패다 — 본문 모양이 어긋나 난 오류가 거짓 초록을 내지 않게. 호출이 그 동사 · 경로의 admin 요청 하나로 서버에 닿았는지도 본다.
module Admin3xxSpec
  REALM = "r"
  BASE = "/admin/realms/#{REALM}".freeze
  TOKEN = "/realms/#{REALM}/protocol/openid-connect/token".freeze
  STATUSES = [300, 302, 399].freeze

  # 리소스마다 성공 본문의 representation.
  REPS = {
    "users" => { id: "u1", username: "alice", enabled: true },
    "clients" => { id: "c1", clientId: "c" },
    "groups" => { id: "g1", name: "g", path: "/g" },
    "roles" => { id: "ro1", name: "ro" },
    "realms" => { id: "re", realm: "re", enabled: true }
  }.freeze

  # 연산 → [동사, 경로, 부르는 법]
  OPS = {
    "users.create" => ["POST", "#{BASE}/users", ->(a) { a.users.create(username: "alice") }],
    "users.get" => ["GET", "#{BASE}/users/u1", ->(a) { a.users.get("u1") }],
    "users.list" => ["GET", "#{BASE}/users", ->(a) { a.users.list }],
    "users.update" => ["PUT", "#{BASE}/users/u1", ->(a) { a.users.update("u1", username: "alice") }],
    "users.delete" => ["DELETE", "#{BASE}/users/u1", ->(a) { a.users.delete("u1") }],
    "clients.create" => ["POST", "#{BASE}/clients", ->(a) { a.clients.create(clientId: "c") }],
    "clients.get" => ["GET", "#{BASE}/clients/c1", ->(a) { a.clients.get("c1") }],
    "clients.list" => ["GET", "#{BASE}/clients", ->(a) { a.clients.list }],
    "clients.update" => ["PUT", "#{BASE}/clients/c1", ->(a) { a.clients.update("c1", clientId: "c") }],
    "clients.delete" => ["DELETE", "#{BASE}/clients/c1", ->(a) { a.clients.delete("c1") }],
    "groups.create" => ["POST", "#{BASE}/groups", ->(a) { a.groups.create(name: "g") }],
    "groups.get" => ["GET", "#{BASE}/groups/g1", ->(a) { a.groups.get("g1") }],
    "groups.list" => ["GET", "#{BASE}/groups", ->(a) { a.groups.list }],
    "groups.update" => ["PUT", "#{BASE}/groups/g1", ->(a) { a.groups.update("g1", name: "g") }],
    "groups.delete" => ["DELETE", "#{BASE}/groups/g1", ->(a) { a.groups.delete("g1") }],
    "roles.create" => ["POST", "#{BASE}/roles", ->(a) { a.roles.create(name: "ro") }],
    "roles.get" => ["GET", "#{BASE}/roles/ro", ->(a) { a.roles.get("ro") }],
    "roles.list" => ["GET", "#{BASE}/roles", ->(a) { a.roles.list }],
    "roles.update" => ["PUT", "#{BASE}/roles/ro", ->(a) { a.roles.update("ro", name: "ro") }],
    "roles.delete" => ["DELETE", "#{BASE}/roles/ro", ->(a) { a.roles.delete("ro") }],
    "realms.create" => ["POST", "/admin/realms", ->(a) { a.realms.create(realm: "re") }],
    "realms.get" => ["GET", "/admin/realms/re", ->(a) { a.realms.get("re") }],
    "realms.list" => ["GET", "/admin/realms", ->(a) { a.realms.list }],
    "realms.update" => ["PUT", "/admin/realms/re", ->(a) { a.realms.update("re", realm: "re") }],
    "realms.delete" => ["DELETE", "/admin/realms/re", ->(a) { a.realms.delete("re") }]
  }.freeze

  # 성공 본문이 배열인 연산 — 나머지는 객체다.
  LISTS = %w[users.list clients.list groups.list roles.list realms.list].freeze

  RESOURCES = {
    "users" => KeycloakSdk::Admin::Users,
    "clients" => KeycloakSdk::Admin::Clients,
    "groups" => KeycloakSdk::Admin::Groups,
    "roles" => KeycloakSdk::Admin::Roles,
    "realms" => KeycloakSdk::Admin::Realms
  }.freeze

  module_function

  def body(operation)
    rep = REPS.fetch(operation.split(".").first)
    (LISTS.include?(operation) ? [rep] : rep).to_json
  end

  # 토큰 엔드포인트는 정상으로, 그 연산의 경로는 정한 3xx(Location 없음)와 본문으로 답한다.
  def server(status, path, body)
    server = BodyServer.new(framing: :length)
    server.route(TOKEN) { [200, {}, { access_token: "at-3xx", token_type: "Bearer", expires_in: 300 }.to_json, 0] }
    server.route(path) { [status, {}, body, 0] }
    server
  end

  def client(server)
    KeycloakSdk::KeycloakClient.new(
      KeycloakSdk::Config.new(server_url: server.url, realm: REALM, client_id: "c", client_secret: "s")
    )
  end

  # SDK 오류가 아닌 것(새어 나온 하위 예외)도 칸의 결과로 적는다 — rspec 오류가 아니라 실패한 칸이다.
  def outcome
    [:ok, yield]
  rescue StandardError => e
    [e.class, e.respond_to?(:status) ? e.status : nil, e.message]
  end
end

RSpec.describe KeycloakSdk::Admin::AdminClient do
  let(:spec) { Admin3xxSpec }

  around do |example|
    WebMock.disable!
    example.run
  ensure
    WebMock.enable!
  end

  # 표가 파사드의 공개 연산 전부인가 — 새 연산이 생기면 이 표에 칸이 생길 때까지 운다.
  Admin3xxSpec::RESOURCES.each do |resource, klass|
    it "covers every public #{resource} operation" do
      table = Admin3xxSpec::OPS.keys.filter_map { |op| op.split(".").last if op.start_with?("#{resource}.") }
      expect(klass.public_instance_methods(false).map(&:to_s)).to match_array(table)
      expect([Admin3xxSpec::OPS.size, Admin3xxSpec::LISTS.size]).to eq([25, 5])
      expect(Admin3xxSpec::LISTS - Admin3xxSpec::OPS.keys).to be_empty
    end
  end

  Admin3xxSpec::STATUSES.each do |status|
    Admin3xxSpec::OPS.each do |op, (verb, path, call)|
      it "#{op} fails on a #{status} without Location as AdminError #{status}" do
        server = spec.server(status, path, spec.body(op))
        kc = spec.client(server)
        got = spec.outcome { call.call(kc.admin) }
        kc.close
        server.close
        seen = server.requests.map { |r| [r.verb, r.path] }
        expect(seen).to eq([["POST", Admin3xxSpec::TOKEN], [verb, path]])
        expect(got.first(2)).to eq([KeycloakSdk::AdminError, status]), "#{status} #{op} → #{got.inspect}"
      end
    end
  end
end
