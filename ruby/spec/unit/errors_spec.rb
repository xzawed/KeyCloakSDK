# frozen_string_literal: true

require "spec_helper"

# rubocop:disable-next RSpec/DescribeClass -- 여러 예외 클래스로 구성된 계층을 검증하는 서술적 describe
RSpec.describe "KeycloakSdk error hierarchy" do
  it "roots every error at KeycloakSdk::Error < StandardError" do
    expect(KeycloakSdk::Error.ancestors).to include(StandardError)
    [KeycloakSdk::ConfigError, KeycloakSdk::AuthError, KeycloakSdk::TransportError,
     KeycloakSdk::TokenValidationError, KeycloakSdk::AdminError].each do |klass|
      expect(klass.ancestors).to include(KeycloakSdk::Error)
    end
  end

  it "nests admin subtypes under AdminError" do
    [KeycloakSdk::NotFoundError, KeycloakSdk::ConflictError, KeycloakSdk::ForbiddenError].each do |klass|
      expect(klass.ancestors).to include(KeycloakSdk::AdminError)
    end
  end

  it "carries oauth_error on AuthError" do
    err = KeycloakSdk::AuthError.new("bad", oauth_error: "invalid_client")
    expect(err.oauth_error).to eq("invalid_client")
  end

  it "maps status to the right admin subtype via from_status" do
    expect(KeycloakSdk::AdminError.from_status(404, "x")).to be_a(KeycloakSdk::NotFoundError)
    expect(KeycloakSdk::AdminError.from_status(409, "x")).to be_a(KeycloakSdk::ConflictError)
    expect(KeycloakSdk::AdminError.from_status(403, "x")).to be_a(KeycloakSdk::ForbiddenError)
    other = KeycloakSdk::AdminError.from_status(500, "boom")
    expect(other).to be_a(KeycloakSdk::AdminError)
    expect(other.status).to eq(500)
  end

  # 경계가 원본 하위 예외 대신 `cause` 에 다는 사본 — 경로 전수는 `hostile_token_response_spec.rb`.
  describe KeycloakSdk::RedactedCause do
    def raised
      yield
    rescue StandardError => e
      e
    end

    let(:lower) do
      raised do
        JSON.parse("RC-SECRET-BODY-TOKEN")
      rescue JSON::ParserError => e
        raise Faraday::ParsingError.new(e, { body: "RC-SECRET-BODY-TOKEN" })
      end
    end

    it "keeps the lower class chain and backtrace but never the message" do
      rc = described_class.new(lower)
      expect(lower.message).to include("RC-SECRET-BODY-TOKEN") # 대조군 — 원본은 정말 인용한다
      expect(rc.lower_classes).to eq(%w[Faraday::ParsingError JSON::ParserError])
      expect(rc.backtrace).to eq(lower.backtrace)
      [rc.message, rc.inspect, rc.full_message(highlight: false)].each do |out|
        expect(out).not_to include("RC-SECRET")
      end
    end

    it "is not an SDK error (it only ever sits in a cause)" do
      expect(described_class.ancestors).not_to include(KeycloakSdk::Error)
      expect(described_class.new(RuntimeError.new("x")).cause).to be_nil
    end

    it "describes socket, timeout and TLS failures by their message" do
      [Errno::ECONNREFUSED.new("kc:443"), SocketError.new("getaddrinfo"), Net::OpenTimeout.new("expired"),
       OpenSSL::SSL::SSLError.new("certificate verify failed")].each do |cause|
        err = Faraday::ConnectionFailed.new(cause)
        expect(described_class.describe(err)).to eq(err.message)
      end
    end

    # ⚠️ ConnectionFailed 를 통째로 믿지 않는다 — Net::HTTP 는 깨진 상태 줄을 dump 하고 어댑터가 그것을 감싼다.
    it "describes anything that can quote the response by its class name only" do
      bad_line = Faraday::ConnectionFailed.new(Net::HTTPBadResponse.new('wrong status line: "RC-SECRET-LINE"'))
      expect(described_class.describe(bad_line)).to eq("Faraday::ConnectionFailed")
      expect(described_class.describe(lower)).to eq("Faraday::ParsingError")
      expect(described_class.describe(Faraday::ConnectionFailed.new("RC-SECRET-TEXT"))).to eq("Faraday::ConnectionFailed")
    end
  end
end
