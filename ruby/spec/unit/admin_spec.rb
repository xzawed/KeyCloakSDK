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
end
