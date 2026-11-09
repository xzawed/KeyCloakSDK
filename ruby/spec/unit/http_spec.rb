# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::Http do
  let(:config) do
    KeycloakSdk::Config.new(server_url: "https://k", realm: "r", client_id: "c",
                            connect_timeout: 3, read_timeout: 7)
  end

  it "injects timeouts from config" do
    conn = described_class.build(config)
    expect(conn.options.open_timeout).to eq(3)
    expect(conn.options.timeout).to eq(7)
  end

  it "does not install a follow-redirects middleware (SSRF hardening)" do
    conn = described_class.build(config) { |f| f.response :json }
    names = conn.builder.handlers.map(&:name)
    expect(names.join).not_to match(/FollowRedirects/i)
  end

  # 공개 헬퍼의 계약은 그대로다 — 토큰·introspection 레인은 이제 그 판정을 쓰지 않고 끝까지 온 응답의 규칙(AuthError)을 건다
  # (token_response_class_spec). logout 은 `check_utf8: false` 로 미들웨어의 판정만 쓴다.
  describe ".decode_json" do
    def response(body)
      env = Faraday::Env.from(status: 200, body: body.b,
                              response_headers: Faraday::Utils::Headers.new("Content-Type" => "application/json"))
      Faraday::Response.new(env)
    end

    let(:undecodable) { ['{"a":"x', 0xFF.chr, '"}'].map(&:b).join }

    it "parses a JSON body as the connection's json middleware does" do
      expect(described_class.decode_json(response('{"a":1}')).body).to eq("a" => 1)
    end

    it "raises Faraday::ParsingError for a parsed string that is not valid UTF-8" do
      expect { described_class.decode_json(response(undecodable)) }.to raise_error(Faraday::ParsingError) { |e|
        expect(e.cause).to be_a(JSON::ParserError)
      }
    end

    it "keeps that string with check_utf8: false" do
      decoded = described_class.decode_json(response(undecodable), check_utf8: false)
      expect(decoded.body["a"].valid_encoding?).to be(false)
    end
  end
end
