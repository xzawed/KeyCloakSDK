# frozen_string_literal: true

require "spec_helper"
require_relative "../support/body_server"

# admin 이 쓰지 않는 응답 본문과 오류 본문을 끝까지 읽지 않는다 — 등록부 admin-response-body-unbounded(ruby).
# 파사드 쓰기(다섯 리소스 × create·update·delete)의 2xx 본문은 읽지 않고, 오류 본문(300 이상)은 1 MiB 에서 자른다
# — `raw` 커넥션의 오류 본문도. 그 밖의 성공 본문은 지금처럼 끝까지 읽는다.
module AdminResponseBodySpec
  CAP = 1_048_576 # 시험의 신탁 — SDK 상수와 따로 쓴다
  HUGE = 64 * 1_048_576 # 소켓 버퍼가 다 담지 못하는 본문
  STALL_TIMEOUT = 4 # 재스캔(2026-10-25)의 읽기 타임아웃
  REALM = "r"
  BASE = "/admin/realms/#{REALM}".freeze
  ERROR_HEAD = { error: "HTTP 404 Not Found" }.to_json.freeze

  # 이름 → [동사, 경로, 부르는 법, 돌려받을 값]
  WRITES = {
    "users.create" => ["POST", "#{BASE}/users", ->(a) { a.users.create(username: "u") }, "new-id"],
    "users.update" => ["PUT", "#{BASE}/users/u1", ->(a) { a.users.update("u1", username: "u") }, nil],
    "users.delete" => ["DELETE", "#{BASE}/users/u1", ->(a) { a.users.delete("u1") }, nil],
    "clients.create" => ["POST", "#{BASE}/clients", ->(a) { a.clients.create(clientId: "c") }, "new-id"],
    "clients.update" => ["PUT", "#{BASE}/clients/c1", ->(a) { a.clients.update("c1", clientId: "c") }, nil],
    "clients.delete" => ["DELETE", "#{BASE}/clients/c1", ->(a) { a.clients.delete("c1") }, nil],
    "groups.create" => ["POST", "#{BASE}/groups", ->(a) { a.groups.create(name: "g") }, "new-id"],
    "groups.update" => ["PUT", "#{BASE}/groups/g1", ->(a) { a.groups.update("g1", name: "g") }, nil],
    "groups.delete" => ["DELETE", "#{BASE}/groups/g1", ->(a) { a.groups.delete("g1") }, nil],
    "roles.create" => ["POST", "#{BASE}/roles", ->(a) { a.roles.create(name: "n") }, "new-id"],
    "roles.update" => ["PUT", "#{BASE}/roles/n", ->(a) { a.roles.update("n", name: "n") }, nil],
    "roles.delete" => ["DELETE", "#{BASE}/roles/n", ->(a) { a.roles.delete("n") }, nil],
    "realms.create" => ["POST", "/admin/realms", ->(a) { a.realms.create(realm: "x") }, "x"],
    "realms.update" => ["PUT", "/admin/realms/x", ->(a) { a.realms.update("x", realm: "x") }, nil],
    "realms.delete" => ["DELETE", "/admin/realms/x", ->(a) { a.realms.delete("x") }, nil]
  }.freeze

  # 오류 본문을 저마다 읽는 호출 — 읽기 둘 · 쓰기 · create.
  ERROR_CALLS = {
    "users.get" => ["#{BASE}/users/u1", ->(a) { a.users.get("u1") }],
    "clients.list" => ["#{BASE}/clients", ->(a) { a.clients.list }],
    "users.update" => ["#{BASE}/users/u1", ->(a) { a.users.update("u1", username: "u") }],
    "users.create" => ["#{BASE}/users", ->(a) { a.users.create(username: "u") }]
  }.freeze

  class Fixed
    def access_token = "AT"
  end

  module_function

  def admin(server, read_timeout: 10, provider: Fixed.new)
    config = KeycloakSdk::Config.new(server_url: server.url, realm: REALM, client_id: "c", client_secret: "s",
                                     read_timeout: read_timeout)
    KeycloakSdk::Admin::AdminClient.new(config: config, token_provider: provider)
  end

  # 쓰기의 2xx — create 는 201 + Location, 나머지는 200. 본문은 `total` 바이트(아무도 읽지 않는다).
  def unread(server, verb, total, stop_after: nil)
    created = verb == "POST"
    headers = created ? { "Location" => "#{server.url}/whatever/new-id" } : {}
    [created ? 201 : 200, headers, "{}", total - 2, stop_after]
  end

  def error(status, total, stop_after: nil)
    [status, {}, ERROR_HEAD, total - ERROR_HEAD.bytesize, stop_after]
  end

  def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    [result, ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round]
  end

  def outcome
    [:ok, yield]
  rescue KeycloakSdk::Error => e
    [e.class, e.respond_to?(:status) ? e.status : nil, e.message]
  end

  # 측정 줄 — `KCSDK_MEASURE=1` 일 때만 리포터로 낸다(평소 실행은 조용하다).
  def note(line)
    RSpec.configuration.reporter.message(line) if ENV["KCSDK_MEASURE"]
  end
end

RSpec.describe KeycloakSdk::Admin::AdminClient do
  let(:spec) { AdminResponseBodySpec }

  around do |example|
    WebMock.disable!
    example.run
  ensure
    WebMock.enable!
  end

  %i[chunked length].each do |framing|
    context "with #{framing} framing" do
      AdminResponseBodySpec::WRITES.each do |name, (verb, path, call, result)|
        it "#{name} leaves its 2xx body unread — the server cannot write it all" do
          server = BodyServer.new(framing: framing)
          server.route(path) { spec.unread(server, verb, AdminResponseBodySpec::HUGE) }
          got, ms = spec.timed { spec.outcome { call.call(spec.admin(server)) } }
          server.close
          spec.note("  [#{framing}] #{name}: #{ms} ms · server wrote #{server.written.last} body bytes · " \
                    "#{got.inspect}")
          expect(got).to eq([:ok, result])
          expect(server.written.last).to be < AdminResponseBodySpec::HUGE
        end
      end

      AdminResponseBodySpec::ERROR_CALLS.each do |name, (path, call)|
        [404, 300].each do |status|
          it "#{name} cuts a #{status} error body at the cap and keeps the class and status" do
            server = BodyServer.new(framing: framing)
            server.route(path) { spec.error(status, AdminResponseBodySpec::HUGE) }
            got, ms = spec.timed { spec.outcome { call.call(spec.admin(server)) } }
            server.close
            spec.note("  [#{framing}] #{name} #{status}: #{ms} ms · server wrote #{server.written.last} body bytes · " \
                      "#{got.first(2).inspect}")
            want = status == 404 ? KeycloakSdk::NotFoundError : KeycloakSdk::AdminError
            expect(got.first(2)).to eq([want, status])
            expect(server.written.last).to be < AdminResponseBodySpec::HUGE
          end
        end
      end
    end
  end

  AdminResponseBodySpec::WRITES.each do |name, (verb, path, call, result)|
    it "#{name} returns without waiting for a 2xx body that stalls after its first bytes" do
      server = BodyServer.new(framing: :length)
      server.route(path) { spec.unread(server, verb, AdminResponseBodySpec::CAP, stop_after: 2) }
      admin = spec.admin(server, read_timeout: AdminResponseBodySpec::STALL_TIMEOUT)
      got, ms = spec.timed { spec.outcome { call.call(admin) } }
      server.close
      spec.note("  #{name} stalled: #{ms} ms · #{got.inspect}")
      expect(got).to eq([:ok, result])
    end
  end

  # 청크면 상한을 넘긴 조각이 청크 한가운데다 — net-http 의 청크 읽기는 `ensure` 에서 그 청크의 CRLF 를 읽으려 한다.
  %i[length chunked].each do |framing|
    AdminResponseBodySpec::ERROR_CALLS.each do |name, (path, call)|
      it "#{name} ends a #{framing} error body that passes the cap and stalls, without waiting for the rest" do
        server = BodyServer.new(framing: framing)
        server.route(path) { spec.error(404, 2 * AdminResponseBodySpec::CAP, stop_after: AdminResponseBodySpec::CAP + 1) }
        admin = spec.admin(server, read_timeout: AdminResponseBodySpec::STALL_TIMEOUT)
        got, ms = spec.timed { spec.outcome { call.call(admin) } }
        server.close
        spec.note("  [#{framing}] #{name} past the cap, stalled: #{ms} ms · #{got.first(2).inspect}")
        expect(got.first(2)).to eq([KeycloakSdk::NotFoundError, 404])
      end
    end
  end

  # 흘려 받는 요청(`on_data`)의 본문은 호출자에게 그대로 간다 — Faraday 가 쥐지 않으니 SDK 가 정하지 않는다.
  it "streams a raw error body to the caller's on_data, whole" do
    total = 2 * AdminResponseBodySpec::CAP
    server = BodyServer.new(framing: :chunked)
    server.route("#{AdminResponseBodySpec::BASE}/users/u1") { [404, { "Content-Type" => "text/plain" }, "nf", total - 2] }
    received = 0
    resp = spec.admin(server).raw.get("admin/realms/#{AdminResponseBodySpec::REALM}/users/u1") do |req|
      req.options.on_data = proc { |chunk, _| received += chunk.bytesize }
    end
    server.close
    expect([resp.status, received]).to eq([404, total])
  end

  it "keeps the 2xx body of a write sent on the raw connection — the mark is on the facade's request alone" do
    big = 2 * AdminResponseBodySpec::CAP
    server = BodyServer.new(framing: :length)
    server.route("#{AdminResponseBodySpec::BASE}/users") do
      [201, { "Content-Type" => "text/plain", "Location" => "#{server.url}/x/new-id" }, "x", big - 1]
    end
    admin = spec.admin(server)
    expect(admin.users.create(username: "u")).to eq("new-id")
    expect(admin.raw.post("admin/realms/#{AdminResponseBodySpec::REALM}/users", { username: "u" }).body.bytesize)
      .to eq(big)
    server.close
  end

  it "cuts the raw connection's error body at the cap too" do
    server = BodyServer.new(framing: :chunked)
    server.route("#{AdminResponseBodySpec::BASE}/users/u1") do
      [404, { "Content-Type" => "text/plain" }, "not found", AdminResponseBodySpec::HUGE]
    end
    resp = spec.admin(server).raw.get("admin/realms/#{AdminResponseBodySpec::REALM}/users/u1")
    server.close
    expect(resp.status).to eq(404)
    expect(resp.body.bytesize).to eq(AdminResponseBodySpec::CAP)
    expect(server.written.last).to be < AdminResponseBodySpec::HUGE
  end

  # 쓰기 도중의 토큰 요청은 auth 커넥션으로 간다 — `SettleBody` 가 `BearerAuth` 뒤에 서야 그 요청에 admin 규칙이 닿지 않는다.
  it "fetches a token over HTTP in the middle of a write and still writes" do
    server = BodyServer.new(framing: :length)
    server.route("/realms/#{AdminResponseBodySpec::REALM}/protocol/openid-connect/token") do
      [200, {}, { access_token: "AT", token_type: "Bearer", expires_in: 300 }.to_json, 0]
    end
    server.route("#{AdminResponseBodySpec::BASE}/users/u1") { [200, {}, "{}", AdminResponseBodySpec::HUGE - 2] }
    kc = KeycloakSdk::KeycloakClient.new(KeycloakSdk::Config.new(server_url: server.url, realm: AdminResponseBodySpec::REALM,
                                                                 client_id: "c", client_secret: "s"))
    expect(spec.outcome { kc.admin.users.update("u1", username: "u") }).to eq([:ok, nil])
    server.close
    expect(server.requests.map(&:path).last).to eq("#{AdminResponseBodySpec::BASE}/users/u1")
  end

  # 토큰 공급자는 `BearerAuth` 안에서 돈다 — 쓰기 도중 그것이 보내는 admin 요청은 표시가 없는 다른 요청이다.
  it "lets an admin GET the token provider sends during a write read its body" do
    provider = Class.new do
      attr_accessor :admin, :got

      def access_token
        if admin && got.nil?
          self.got = :pending
          self.got = admin.users.get("u1")
        end
        "AT"
      end
    end.new
    server = BodyServer.new(framing: :length)
    server.route("#{AdminResponseBodySpec::BASE}/users/u1") do |req|
      req.verb == "GET" ? [200, {}, { id: "u1", username: "alice" }.to_json, 0] : [204, {}, "", 0]
    end
    provider.admin = spec.admin(server, provider: provider)
    provider.admin.users.update("u1", username: "u")
    server.close
    expect(provider.got).to eq("id" => "u1", "username" => "alice")
  end

  # 잘림이 JSON 을 갈라도 상태가 클래스를 정한다(`Call#unparsable_error_status` · .NET 과 같다).
  [404, 300].each do |status|
    it "keeps the class and status of a #{status} whose JSON the cut splits" do
      server = BodyServer.new(framing: :length)
      head = "{\"error\":\"#{'x' * (2 * AdminResponseBodySpec::CAP)}\"}"
      server.route("#{AdminResponseBodySpec::BASE}/users/u1") { [status, {}, head, 0] }
      got = spec.outcome { spec.admin(server).users.get("u1") }
      server.close
      expect(got).to eq([status == 404 ? KeycloakSdk::NotFoundError : KeycloakSdk::AdminError, status,
                         "admin request failed: HTTP #{status}"])
    end
  end

  # 상한 위에서 푸는 곳이 없다 — admin 요청은 인코딩 없는 본문을 청하고(net-http 가 gzip 을 청해 풀지 않는다),
  # 청하지 않은 gzip 이 와도 받은 바이트가 상한을 센다.
  it "asks for an unencoded body and never inflates a gzip error body sent anyway" do
    server = BodyServer.new(compress: :always)
    server.route("#{AdminResponseBodySpec::BASE}/users/u1") { spec.error(404, AdminResponseBodySpec::HUGE) }
    admin = spec.admin(server)
    allocated = BodyServer.allocated_bytes { expect { admin.users.get("u1") }.to raise_error(KeycloakSdk::NotFoundError) }
    server.close
    spec.note("  users.get 404 gzip (64 MiB inflated): allocated #{allocated} bytes")
    expect(server.requests.last.headers["accept-encoding"]).to eq("identity")
    expect(allocated).to be < 16 * AdminResponseBodySpec::CAP
  end

  # identity 를 청했는데도 gzip 을 보내는 서버 — 규격을 어긴 그 서버 앞에서 무엇이 되는지 고정한다(절충 · CHANGELOG ⚠️).
  # 아무도 풀지 않으니 성공 본문은 JSON 으로 읽히지 않아 TransportError 이고, raw 의 JSON 오류 본문은 ParsingError 다.
  it "leaves a gzip body a server sends despite identity undecoded — facade success fails, raw JSON error raises" do
    server = BodyServer.new(compress: :always)
    server.route("#{AdminResponseBodySpec::BASE}/users/u1") { [200, {}, { id: "u1" }.to_json, 0] }
    server.route("#{AdminResponseBodySpec::BASE}/users/u2") { [404, {}, { error: "missing" }.to_json, 0] }
    admin = spec.admin(server)
    expect(spec.outcome { admin.users.get("u1") }.first).to eq(KeycloakSdk::TransportError)
    expect { admin.raw.get("admin/realms/#{AdminResponseBodySpec::REALM}/users/u2") }
      .to raise_error(Faraday::ParsingError)
    server.close
  end

  it "reads a success body the call uses whole, past the cap" do
    list = (1..20_000).map { |i| { id: format("%012d", i), username: "user-#{format('%012d', i)}" } }.to_json
    server = BodyServer.new(framing: :chunked)
    server.route("#{AdminResponseBodySpec::BASE}/users") { [200, {}, list, 0] }
    got = spec.admin(server).users.list
    server.close
    expect(list.bytesize).to be > AdminResponseBodySpec::CAP
    expect(got.size).to eq(20_000)
  end

  # net-http 내부에 기대는 모양 — 읽은 응답(`@read`)의 `body` 는 소켓을 다시 읽지 않고 `@body` 다.
  it "relies on net-http returning a read response's @body without touching the socket (pin)" do
    res = Net::HTTPOK.new("1.1", "200", "OK")
    res.instance_variable_set(:@body, "settled")
    res.instance_variable_set(:@read, true)
    expect(res.body).to eq("settled")
    expect(res.read_body).to eq("settled")
  end

  it "reads a 64 MiB error body with allocation in proportion to the cap, not to the body" do
    server = BodyServer.new(framing: :chunked)
    server.route("#{AdminResponseBodySpec::BASE}/users/u1") { spec.error(404, AdminResponseBodySpec::HUGE) }
    admin = spec.admin(server)
    allocated = BodyServer.allocated_bytes { spec.outcome { admin.users.get("u1") } }
    server.close
    spec.note("  users.get 404 + 64 MiB: allocated #{allocated} bytes")
    expect(allocated).to be < 16 * AdminResponseBodySpec::CAP
  end
end
