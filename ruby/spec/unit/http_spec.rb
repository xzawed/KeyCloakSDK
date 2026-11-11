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

  # 스트리밍 본문의 빈 자리표시를 커넥션의 json 미들웨어가 파싱하다 낸 ParsingError(어댑터가 dummy 인코딩 charset 으로 바꾼
  # 자리표시의 `strip` — token_response_class_spec r11 · r12 가 실소켓으로 잰다)는 아무것도 판정하지 않았다: 그 응답에 흘려
  # 받은 본문을 실어 돌려준다. 그 응답이 Faraday::Response 가 아니면(요청 데이터를 뺀 Hash) 실을 자리가 없어 그대로 던진다.
  describe ".read_capped when the connection's json middleware fails on the streamed placeholder" do
    # 본문을 on_data 로 흘린 뒤 `failure` 를 던지는 커넥션 — 어댑터 · 미들웨어 순서 그대로다.
    def connection(failure)
      Class.new do
        define_method(:run_request) do |_method, _url, _body, _headers, &block|
          req = Faraday::Request.create(:post) { |r| r.options = Faraday::RequestOptions.new }
          block.call(req)
          req.options.on_data.call("{\"a\":".b, 5)
          req.options.on_data.call("1}".b, 7)
          raise failure
        end
      end.new
    end

    def env
      Faraday::Env.from(status: 200, body: "", response_headers: Faraday::Utils::Headers.new(
        "Content-Type" => "application/json; charset=utf-16"
      ))
    end

    # 모든 레인이 같은 읽기를 지난다 — JWKS · logout 도(독립 레그가 살린 축소 편집 「token · introspection 일 때만」, 2026-11-11).
    %w[token introspection logout JWKS].each do |what|
      it "returns that response carrying the streamed body (#{what})" do
        failure = Faraday::ParsingError.new(Encoding::CompatibilityError.new("x"), Faraday::Response.new(env))
        resp = described_class.read_capped(connection(failure), :post, "https://k/t", max_bytes: 64, what: what)
        expect(resp.status).to eq(200)
        expect(resp.body).to eq('{"a":1}'.b)
      end
    end

    it "re-raises it when its response is not a Faraday::Response" do
      failure = Faraday::ParsingError.new(Encoding::CompatibilityError.new("x"), { status: 200 })
      expect do
        described_class.read_capped(connection(failure), :post, "https://k/t", max_bytes: 64, what: "token")
      end.to raise_error(Faraday::ParsingError)
    end
  end
end
