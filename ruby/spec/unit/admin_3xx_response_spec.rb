# frozen_string_literal: true

require "spec_helper"
require "net/http"
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
#
# 같은 25 연산으로 두 칸을 더 지킨다(실측 2026-11-14: A 300/300 · 대조군 50/50 · B 25/25 — 이미 옳았다, SDK 무변경).
#  (A) 객체가 아닌 JSON 오류 본문 — 등록부 python-admin-list-error-array-body 의 부류 재스캔(python 은 목록 다섯이 배열
#      본문의 4xx · 5xx 에 상태 없는 전송 오류다). 404 · 500 × 본문 일곱(대조군 `{"error":"x"}` 과 `[]` · `"boom"` · `42` ·
#      `true` · `null` · 깊이 100000 의 배열 200,000 바이트): 404 는 `NotFoundError`, 500 은 `AdminError` 그 자체 — 그
#      상태를 싣고 — 이고 admin 요청은 그 호출의 것 하나다. 본문이 클래스를 바꾸면 그 칸은 실패다.
#  (B) 따를 수 있는 리다이렉트 — 등록부 admin-followable-redirect-class-divergent(go 는 `*TransportError` 로 갈린다).
#      302 가 `Location: <서버>/redirected-target` 을 달고 그곳은 그 호출의 성공 본문을 200 으로 준다 — 따라가면 성공으로
#      읽힌다. `AdminError` 그 자체에 302 · admin 요청 하나 · 대상 요청 0 이어야 한다. `http_spec.rb` 는 follow_redirects
#      미들웨어가 목록에 없는지만 본다 — 302 를 실제로 모는 것은 이 칸이다.
# 두 칸은 서버 하나 · 클라이언트 하나로 칸 전부를 돌고(`AdminErrorShapeSpec`), 틀린 칸을 모아 끝에 한 번 단언한다.
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

# (A) 본문 모양 · (B) 따를 수 있는 302 칸의 도우미 — 25 연산 표 · 성공 본문 · 클라이언트 · 결과 기록은 Admin3xxSpec 의 것이다.
# 칸마다 서버를 새로 띄우지 않는다: 서버 하나가 25 경로와 리다이렉트 대상을 `plan`(칸마다 바꿔 끼우는 답)으로 답하고 클라이언트
# 하나가 토큰을 한 번 받아 칸 전부를 돈다 — 칸의 요청은 그 호출 동안 서버에 닿은 것만 센다.
module AdminErrorShapeSpec
  STATUSES = [404, 500].freeze
  # 객체 대조군과 객체가 아닌 JSON 여섯 — 깊이 100000 의 배열은 200,000 바이트다.
  BODIES = {
    "object" => '{"error":"x"}',
    "array" => "[]",
    "string" => '"boom"',
    "number" => "42",
    "boolean" => "true",
    "null" => "null",
    "deep" => ("[" * 100_000) + ("]" * 100_000)
  }.freeze
  TARGET = "/redirected-target"

  module_function

  # 그 상태에 ruby 가 주는 오류 — 404 는 NotFoundError, 그 밖은 AdminError 그 자체(하위 클래스 아님) — 와 그 상태.
  def error_for(status)
    [status == 404 ? KeycloakSdk::NotFoundError : KeycloakSdk::AdminError, status]
  end

  def server(plan)
    server = BodyServer.new(framing: :length)
    token = { access_token: "at-shape", token_type: "Bearer", expires_in: 300 }.to_json
    server.route(Admin3xxSpec::TOKEN) { [200, {}, token, 0] }
    Admin3xxSpec::OPS.each_value { |(_, path, _)| server.route(path) { plan.fetch(:reply) } }
    server.route(TARGET) { [200, {}, plan.fetch(:target), 0] }
    server
  end

  # 전제 — 서버가 실제로 보낸 [상태, content-type, Location, 본문](리다이렉트를 따르지 않는 Net::HTTP 로).
  def answered(server, path)
    resp = Net::HTTP.get_response(URI("#{server.url}#{path}"))
    [resp.code.to_i, resp["content-type"], resp["location"], resp.body.to_s]
  end

  # 칸 하나 — 옳으면 nil, 틀렸으면 그 까닭. 옳은 칸: 그 상태의 오류(`want`) · 그 호출의 admin 요청 하나 · 대상 요청 0.
  def wrong_cell(label, server, admin, entry, want)
    verb, path, call = entry
    before = server.requests.size
    got = Admin3xxSpec.outcome { call.call(admin) }
    seen = server.requests.drop(before).map { |r| [r.verb, r.path] }
    sent = seen.select { |(_, p)| p.start_with?("/admin") }
    followed = seen.count { |(_, p)| p == TARGET }
    return if got.first(2) == want && sent == [[verb, path]] && followed.zero?

    "#{label}: #{got.inspect[0, 160]} · admin requests #{sent.inspect} · target requests #{followed}"
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

  # (A) 404 · 500 × 본문 일곱 — 등록부 python-admin-list-error-array-body 의 부류 재스캔.
  it "fails every call on a 404 or 500 with any JSON error body as the error of that status" do
    shape = AdminErrorShapeSpec
    plan = { target: "{}" }
    server = shape.server(plan)
    kc = spec.client(server)
    admin = kc.admin
    wrong = shape::STATUSES.product(shape::BODIES.to_a).flat_map do |status, (name, body)|
      plan[:reply] = [status, {}, body, 0]
      premise = shape.answered(server, "#{Admin3xxSpec::BASE}/users/u1")
      cells = Admin3xxSpec::OPS.map do |op, entry|
        shape.wrong_cell("#{status} #{name} #{op}", server, admin, entry, shape.error_for(status))
      end
      premise_wrong = "#{status} #{name} premise: #{premise.first(3).inspect} · #{premise.last.bytesize} bytes"
      [(premise_wrong unless premise == [status, "application/json", nil, body]), *cells]
    end.compact
    expect(wrong).to be_empty, "#{wrong.size} cell(s) wrong:\n#{wrong.join("\n")}"
  ensure
    kc&.close
    server&.close
  end

  # (B) 따를 수 있는 302 — 등록부 admin-followable-redirect-class-divergent. 대상은 그 호출의 성공 본문을 200 으로 준다.
  it "fails every call on a 302 with a followable Location as AdminError 302 without following it" do
    shape = AdminErrorShapeSpec
    plan = { target: spec.body("users.list") }
    server = shape.server(plan)
    location = "#{server.url}#{shape::TARGET}"
    plan[:reply] = [302, { "Location" => location }, "{}", 0]
    kc = spec.client(server)
    admin = kc.admin
    premise = [shape.answered(server, "#{Admin3xxSpec::BASE}/users").first(3), shape.answered(server, shape::TARGET)[0]]
    wrong = [("premise: #{premise.inspect}" unless premise == [[302, "application/json", location], 200])]
    Admin3xxSpec::OPS.each do |op, entry|
      plan[:target] = spec.body(op)
      wrong << shape.wrong_cell("302 #{op}", server, admin, entry, shape.error_for(302))
    end
    wrong.compact!
    expect(wrong).to be_empty, "#{wrong.size} cell(s) wrong:\n#{wrong.join("\n")}"
  ensure
    kc&.close
    server&.close
  end
end
