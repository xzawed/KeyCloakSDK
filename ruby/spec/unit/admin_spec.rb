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
