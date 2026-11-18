# frozen_string_literal: true

require "spec_helper"

# admin 쓰기 본문을 JSON 이 충실히 실을 수 없으면 요청 전에 TransportError 다 — 문구는 아홉 언어 공통
# 「admin request failed: the request body could not be encoded as JSON」(등록부 admin-unencodable-body-residuals ·
# php #1139 · node · python 과 같다).
#
# 본문은 커넥션의 json 요청 미들웨어(`Faraday::Request::Json` → `JSON.generate`)가 쓴다. 그 미들웨어는 BearerAuth 보다
# 앞이라 토큰 그랜트도 admin 요청도 나가기 전에 실패하고, 그 실패는 `JSON::GeneratorError`(NaN · Infinity · -Infinity ·
# 잘못된 UTF-8 — 수정 전 실측 json 3.1.0: 「NaN not allowed in JSON」 · 「source sequence is illegal/malformed utf-8」)나
# `JSON::NestingError`(깊이 100 초과 — ParserError 의 하위라 GeneratorError 가 아니다)다. 수정 전에는 경계의 마지막
# rescue 가 그것을 「admin transport error: JSON::GeneratorError」로 냈다 — 요청이 나가지도 않았는데 전송 실패라는 말이다.
# Ruby 의 인코더는 바꿔 쓰지 않고 던지므로(.NET · Go 와 다르다) 잘못된 텍스트도 같은 거부다. 짝 없는 서로게이트는 UTF-8
# String 이 쥘 수 없다(`"\u{D800}"` 은 문법 오류) — 대조군이 없다.
RSpec.describe KeycloakSdk::Admin::AdminClient, "#users / #clients writing a body JSON cannot carry" do
  let(:server) { "https://kc.unencodable.test" }
  let(:kc) do
    KeycloakSdk::KeycloakClient.new(
      KeycloakSdk::Config.new(server_url: server, realm: "r", client_id: "c", client_secret: "s")
    )
  end
  let(:message) { "admin request failed: the request body could not be encoded as JSON" }
  let!(:token) do
    stub_request(:post, "#{server}/realms/r/protocol/openid-connect/token")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { access_token: "AT", token_type: "Bearer", expires_in: 300 }.to_json)
  end
  let!(:admin_api) do
    stub_request(:any, %r{\A#{Regexp.escape(server)}/admin/})
      .to_return(status: 201, headers: { "Location" => "#{server}/admin/realms/r/users/new-id" })
  end

  # 쓰기 연산 둘 — 동사(POST · PUT)와 리소스가 다르다.
  writes = {
    "users.create" => ->(admin, rep) { admin.users.create(rep) },
    "clients.update" => ->(admin, rep) { admin.clients.update("c1", rep) }
  }
  # 자유 형식 필드(attributes) 안의 수.
  numbers = { "NaN" => Float::NAN, "+Infinity" => Float::INFINITY, "-Infinity" => -Float::INFINITY }

  def deep
    rep = []
    200.times { rep = [rep] }
    rep
  end

  def expect_refused(&)
    expect(&).to raise_error(KeycloakSdk::TransportError) do |e|
      expect(e.message).to eq(message)
      expect(e.cause).to be_a(KeycloakSdk::RedactedCause) # 원본(GeneratorError#invalid_object 가 값을 쥔다)은 달지 않는다
    end
    expect(token).not_to have_been_requested
    expect(admin_api).not_to have_been_requested
  end

  writes.each do |op, call|
    numbers.each do |name, number|
      it "#{op} refuses #{name} in a free-form field before any request" do
        expect_refused { call.call(kc.admin, { "name" => "x", "attributes" => { "n" => [number] } }) }
      end
    end

    it "#{op} refuses a string that is not valid UTF-8 before any request" do
      bad = "x#{0xFF.chr}y".force_encoding(Encoding::UTF_8)
      expect_refused { call.call(kc.admin, { "name" => "x", "attributes" => { "s" => [bad] } }) }
    end

    it "#{op} refuses a body nested deeper than JSON writes before any request" do
      expect_refused { call.call(kc.admin, { "name" => "x", "attributes" => { "d" => deep } }) }
    end

    # 대조 — 하네스가 공허하지 않다: 쓸 수 있는 본문은 그랜트 하나 · admin 요청 하나로 닿는다.
    it "#{op} still sends an encodable body" do
      call.call(kc.admin, { "name" => "x", "attributes" => { "n" => [1.5] } })
      expect(token).to have_been_requested.once
      expect(admin_api).to have_been_requested.once
    end
  end
end
