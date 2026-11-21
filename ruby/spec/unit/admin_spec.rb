# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::Admin::AdminClient do
  subject(:admin) { described_class.new(config: config, token_provider: token_provider) }

  let(:config) do
    KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo",
                            client_id: "svc", client_secret: "sekret")
  end
  let(:token_provider) { instance_double(KeycloakSdk::ClientCredentialsTokenProvider, access_token: "AT") }
  let(:users_url) { "https://kc.example.com/admin/realms/demo/users" }

  it "sends a bearer token from the provider and returns the created id from Location" do
    stub = stub_request(:post, users_url)
           .with(headers: { "Authorization" => "Bearer AT" })
           .to_return(status: 201, headers: { "Location" => "#{users_url}/abc-123" })
    id = admin.users.create({ username: "alice" })
    expect(id).to eq("abc-123")
    expect(stub).to have_been_requested.once
  end

  # 아홉 SDK 가 같이 쓰는 `Location` 벡터(등록부 admin-create-relative-location) — `{base}` 는 서버, `{path}` 는 보낸
  # 컬렉션 경로, `{coll}` 은 그 마지막 조각, `{other}` 는 다른 컬렉션. 값은 돌려줄 id 이고 nil 이면 id 없음(없을 때의 그 답)이다.
  # id 는 201 의 `Location` 을 요청 URL 에 대해 푼(RFC 9110 §10.2.2) 경로의 마지막 조각이고, 그 앞 조각은 보낸 컬렉션이어야
  # 한다 — 상대 `Location` 도 읽고, 쿼리 · 조각은 id 가 아니며, 퍼센트 인코딩은 풀지 않는다. 서버가 id 를 매기는 users 는
  # 열셋 전부, clients · groups 는 L1 · L2 · L4 · L7 · L9. 이름으로 주소를 잡는 roles 는 이 규칙 밖이다(맨 아래 대조).
  describe "the id a create reads from its Location, resolved against the request URL" do
    {
      "L1 absolute" => ["{base}{path}/abc-123", "abc-123"],
      "L2 path-absolute" => ["{path}/abc-123", "abc-123"],
      "L3 relative path" => ["{coll}/abc-123", "abc-123"],
      "L4 relative" => ["abc-123", nil],
      "L5 another host" => ["https://internal.example:8443{path}/abc-123", "abc-123"],
      "L6 gateway prefix" => ["https://gw.example/kc{path}/abc-123", "abc-123"],
      "L7 query and fragment" => ["{base}{path}/abc-123?x=1#f", "abc-123"],
      "L8 trailing slash" => ["{base}{path}/abc-123/", "abc-123"],
      "L9 another collection" => ["../{other}/abc-123", nil],
      "L10 root" => ["/", nil],
      "L11 empty value" => ["", nil],
      "L12 absent" => [nil, nil],
      "L13 percent-encoded" => ["{base}{path}/abc%20123", "abc%20123"]
    }.each do |vector, (template, want)|
      %w[users clients groups].each do |coll|
        next unless coll == "users" || %w[L1 L2 L4 L7 L9].include?(vector.split.first)

        it "#{coll} #{vector} → #{want.inspect}" do
          path = "/admin/realms/demo/#{coll}"
          other = coll == "groups" ? "users" : "groups"
          headers = {}
          unless template.nil?
            headers["Location"] = template.gsub("{base}", "https://kc.example.com").gsub("{path}", path)
                                          .gsub("{coll}", coll).gsub("{other}", other)
          end
          stub_request(:post, "https://kc.example.com#{path}").to_return(status: 201, headers: headers)
          expect(admin.public_send(coll).create({ name: "x" })).to eq(want)
        end
      end
    end

    it "users: SP and HTAB around the Location are not part of it — a value of only those is empty → nil" do
      stub_request(:post, users_url).to_return(
        { status: 201, headers: { "Location" => " \t#{users_url}/abc-123\t " } },
        { status: 201, headers: { "Location" => " \t " } }
      )
      ids = [admin.users.create({ username: "alice" }), admin.users.create({ username: "bob" })]
      expect(ids).to eq(["abc-123", nil])
    end

    it "users: a Location that does not parse (a raw space) → nil, not a stdlib URI error" do
      stub_request(:post, users_url).to_return(status: 201, headers: { "Location" => "#{users_url}/abc 123" })
      expect(admin.users.create({ username: "alice" })).to be_nil
    end

    # 대조 — roles 의 create 는 이름으로 주소를 잡아(서버가 매기는 id 가 없고 `Location` 은 이름으로 끝난다) 위 규칙 밖이고
    # 예전 그대로 `Location` 원문의 마지막 `/` 조각을 돌려준다. `/` 를 품은 이름 `a/b` 의 `…/roles/a/b` 가 서버가 만든 뒤
    # nil 이 되면 안 된다 — 상대 값 · 다른 컬렉션 · 쿼리도 예전 결과 그대로다.
    it "roles: as before — the last `/` piece of the raw Location, no resolution or collection check" do
      roles_url = "https://kc.example.com/admin/realms/demo/roles"
      unchanged = {
        "#{roles_url}/a/b" => "b",
        "#{roles_url}/abc-123" => "abc-123",
        "abc-123" => "abc-123",
        "../groups/abc-123" => "abc-123",
        "#{roles_url}/abc-123?x=1#f" => "abc-123?x=1#f",
        "#{roles_url}/abc-123/" => "abc-123",
        "/" => nil,
        "" => nil,
        nil => nil
      }
      stub_request(:post, roles_url).to_return(
        *unchanged.keys.map { |loc| { status: 201, headers: loc.nil? ? {} : { "Location" => loc } } }
      )
      got = unchanged.keys.to_h { |loc| [loc, admin.roles.create({ name: "a/b" })] }
      expect(got).to eq(unchanged)
    end
  end

  it "maps 404 to NotFoundError" do
    stub_request(:get, "#{users_url}/missing").to_return(status: 404, body: "")
    expect { admin.users.get("missing") }.to raise_error(KeycloakSdk::NotFoundError)
  end

  it "maps 409 to ConflictError" do
    stub_request(:post, users_url).to_return(status: 409, body: { errorMessage: "exists" }.to_json,
                                             headers: { "Content-Type" => "application/json" })
    expect { admin.users.create({ username: "dup" }) }.to raise_error(KeycloakSdk::ConflictError)
  end

  it "maps 403 to ForbiddenError (e.g. POST /admin/realms by realm SA)" do
    stub_request(:post, "https://kc.example.com/admin/realms").to_return(status: 403, body: "")
    expect { admin.realms.create({ realm: "new" }) }.to raise_error(KeycloakSdk::ForbiddenError)
  end

  it "maps a timeout to TransportError" do
    stub_request(:get, "#{users_url}/x").to_raise(Faraday::TimeoutError.new("t"))
    expect { admin.users.get("x") }.to raise_error(KeycloakSdk::TransportError)
  end

  # ⚠️ **상태가 클래스를 정한다 — 오류 본문이 JSON 이라면서 JSON 이 아니어도.** 커넥션의 json 미들웨어가 상태 검사보다
  # 먼저 해석해, 고치기 전에는 셋 다 `TransportError`(`admin transport error: Faraday::ParsingError`)였다 — 404 를
  # 「없음」으로 다루는 소비자 분기가 전송 오류로 빠졌다(.NET 은 같은 경우 상태 클래스를 지킨다). 본문은 메시지에도
  # 원인 사슬에도 인용하지 않는다. 2xx 의 해석 실패는 그대로 전송 오류다(맨 아래 대조군).
  describe "an error status whose body claims JSON but is not" do
    let(:junk) { { body: "<html>NOT-JSON-CANARY</html>", headers: { "Content-Type" => "application/json" } } }

    def expect_status_class(klass, status, &)
      expect(&).to raise_error(klass) do |e|
        expect(e.message).to eq("admin request failed: HTTP #{status}")
        expect(e.status).to eq(status)
        expect(e.full_message(highlight: false)).not_to include("NOT-JSON-CANARY")
      end
    end

    it "keeps 404 as NotFoundError" do
      stub_request(:get, "#{users_url}/missing").to_return(status: 404, **junk)
      expect_status_class(KeycloakSdk::NotFoundError, 404) { admin.users.get("missing") }
    end

    it "keeps 409 as ConflictError" do
      stub_request(:post, users_url).to_return(status: 409, **junk)
      expect_status_class(KeycloakSdk::ConflictError, 409) { admin.users.create({ username: "dup" }) }
    end

    it "keeps 403 as ForbiddenError" do
      stub_request(:get, users_url).with(query: hash_including({})).to_return(status: 403, **junk)
      expect_status_class(KeycloakSdk::ForbiddenError, 403) { admin.users.list }
    end

    it "keeps any other error status an AdminError" do
      stub_request(:get, "#{users_url}/x").to_return(status: 500, **junk)
      expect_status_class(KeycloakSdk::AdminError, 500) { admin.users.get("x") }
    end

    it "still reports an unparsable 2xx body as a transport error" do
      stub_request(:get, "#{users_url}/x").to_return(status: 200, **junk)
      expect { admin.users.get("x") }.to raise_error(KeycloakSdk::TransportError,
                                                     "admin transport error: Faraday::ParsingError")
    end
  end

  # ⚠️ **토큰 공급자가 낸 오류의 상태는 admin 응답의 상태가 아니다.** `BearerAuth` 는 admin 요청을 보내기 전에 주입한 공급자를
  # 부른다 — 그 공급자가 낸 `Faraday::ParsingError` 가 상태를 실어도(응답 객체든, faraday 2.15.1 이
  # `RaiseError(include_request: false)` 아래에서 그것을 바꾼 Hash 든 — error.rb `omit_request_data`) admin 요청은 나가지
  # 않았다. 그 상태가 클래스를 정하던 때는 409 가 admin 요청 없이 「이미 있다」(ConflictError), 404 가 「없다」(NotFoundError)로
  # 읽혔다. 공급자의 SDK 밖 오류는 상태와 무관하게 전송 오류이고, 원인은 `RedactedCause` 다(해석기의 메시지는 본문 앞부분을
  # 인용한다). 대조군 — admin 응답 자신의 못 읽는 오류 본문은 여전히 상태가 클래스를 정한다(404 · 409 · 403 — 위
  # 「an error status whose body claims JSON but is not」).
  describe "a Faraday::ParsingError the token provider raises" do
    let(:unparsable) { JSON::ParserError.new("unexpected token at 'PROVIDER-CANARY'") }

    def raising(error)
      provider = Class.new { define_method(:access_token) { raise error } }.new
      described_class.new(config: config, token_provider: provider)
    end

    def expect_transport_error(failure)
      user = stub_request(:get, "#{users_url}/x")
      expect { raising(failure).users.get("x") }
        .to raise_error(KeycloakSdk::TransportError, "admin transport error: Faraday::ParsingError") do |e|
          expect(e.full_message(highlight: false)).not_to include("PROVIDER-CANARY")
        end
      expect(user).not_to have_been_requested
    end

    it "is a transport error even when its response Hash carries an error status" do
      expect_transport_error(Faraday::ParsingError.new(unparsable, { status: 409 }))
    end

    it "is a transport error, not NotFoundError, when it carries a response object with an error status" do
      env = Faraday::Env.from(status: 404, body: "<html>NOT-JSON</html>",
                              response_headers: Faraday::Utils::Headers.new("Content-Type" => "application/json"))
      expect_transport_error(Faraday::ParsingError.new(unparsable, Faraday::Response.new(env)))
    end

    it "reports one that carries no response as a transport error" do
      expect_transport_error(Faraday::ParsingError.new(unparsable))
    end
  end

  # ⚠️ rename은 PUT /roles/{현재 이름} + body의 **새** 이름이다. 경로를 representation에서
  # 만들면 rename을 표현할 수 없다 — 자매 Go(#275)·PHP(#279) SDK에서 실제로 그랬고, 둘 다
  # 이 테스트가 없어서 오래 살아남았다. 여기 구현은 처음부터 옳지만 그것을 붙잡는 것이 없었다.
  #
  # ⚠️ **경로가 이 예제를 지탱한다.** 병합 회귀는 경로를 새 이름으로 밀어내지 body는 건드리지
  # 않는다(body는 어차피 새 이름이다). 자매 Go는 정반대라 body가 지탱한다 — 부류가 같다고
  # 단언 위치를 복사하지 말 것.
  it "addresses a role update by its current name and carries the new name in the body" do
    stub = stub_request(:put, "https://kc.example.com/admin/realms/demo/roles/old-role")
           .with(body: { name: "new-role" }.to_json)
           .to_return(status: 204)

    admin.roles.update("old-role", { name: "new-role" })

    expect(stub).to have_been_requested.once
  end

  it "exposes the raw Faraday connection as an escape hatch" do
    expect(admin.raw).to be_a(Faraday::Connection)
  end

  # 다섯 admin 리소스가 전부 경로 세그먼트를 **날 문자열 보간**으로 만든다. 두 가지가 깨진다:
  #  (1) "../" 를 담은 값이 경로를 재작성한다 — 서비스 계정 베어러를 실은 채 다른 엔드포인트로 간다.
  #  (2) Keycloak 이 허용하는 공백 든 role/group 이름이 URI::InvalidURIError(stdlib)를 올려
  #      §4「하위 오류는 경계에서 SDK 타입으로 변환된다」를 함께 깬다.
  # 참조 구현이 이 저장소 안에 있다 — go/admin_realms.go 가 url.PathEscape 를 쓴다.
  describe "경로 세그먼트 이스케이프" do
    # 이 블록의 모든 stub 이 같은 모양이라 헬퍼 하나로 모은다.
    def stub_ok(path)
      stub_request(:get, "https://kc.example.com/#{path}")
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    end

    it "../ 를 담은 id 가 경로를 재작성하지 못한다" do
      traversed = stub_request(:get, "https://kc.example.com/admin/foo")
      escaped = stub_ok("admin/realms/demo/users/..%2F..%2F..%2Ffoo")

      admin.users.get("../../../foo")

      expect(traversed).not_to have_been_requested
      expect(escaped).to have_been_requested.once
    end

    # 공백은 Keycloak 이 role/group 이름에 허용하는데 URI.parse 는 거부한다 —
    # 이스케이프가 없으면 Faraday::Error 가 아닌 stdlib URI::InvalidURIError 가 새어
    # §4 경계 변환까지 함께 깨진다. 다섯 리소스를 전부 도는 이유는 한 곳만 고치면
    # 부류가 남기 때문이다(realms 는 realm 이름 자체가 세그먼트라 경로 모양이 다르다).
    {
      "users" => "admin/realms/demo/users/a%20b",
      "clients" => "admin/realms/demo/clients/a%20b",
      "groups" => "admin/realms/demo/groups/a%20b",
      "roles" => "admin/realms/demo/roles/a%20b",
      "realms" => "admin/realms/a%20b"
    }.each do |resource, path|
      it "#{resource}: 공백이 든 세그먼트를 이스케이프하고 stdlib 예외를 새지 않는다" do
        stub = stub_ok(path)
        expect { admin.public_send(resource).get("a b") }.not_to raise_error
        expect(stub).to have_been_requested.once
      end
    end
  end
end
