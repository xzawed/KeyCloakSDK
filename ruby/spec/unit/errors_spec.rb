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
end
