# frozen_string_literal: true

require "spec_helper"
require "base64"

# The OAuth `error` code an SDK error carries is a code, never a value the request sent (registry
# `token-error-code-secret-echo` · `oauth-error-field-echo-unmasked`).
#
# The IdP's `error` is response body too. An IdP (or a proxy) that echoes what the request sent puts the client secret,
# the refresh token or the authorization code there — the grants copied any String into `oauth_error` (and a
# lowercase one into the message), and the provider copied any JSON value, an Array included (measured on main
# `a7d0fdf3`). One predicate now decides the attribute and the message: a String of `[a-z_]{1,64}` that overlaps no
# non-empty secret the request sent — neither contains the other, so a truncated or extended echo is withheld too.
# The price is pinned below: a secret that is a piece of a registered code (`client`) withholds that code.
module OAuthErrorCodeEchoSpec
  # Code-shaped on purpose (the shape alone cannot withhold them), and no two share a piece — an echo of one value must
  # be withheld by comparing against THAT value, not a sibling's prefix.
  REFRESH_TOKEN = "yakrefreshvq"
  CODE = "vulturecodeby"
  VERIFIER = "#{'ocelotverifier' * 3}xx".freeze
  # Every piece and every padding, so each direction of the overlap is pinned.
  ECHO_FORMS = {
    "whole" => ->(v) { v },
    "prefix" => ->(v) { v[0, 11] },
    "suffix" => ->(v) { v[-11..] },
    "middle" => ->(v) { v[2, 9] },
    "extended" => ->(v) { "#{v}_x" },
    "prefixed" => ->(v) { "x_#{v}" },
    "wrapped" => ->(v) { "x_#{v}_x" }
  }.freeze
  TOKEN_URL = "https://kc.example.com/realms/demo/protocol/openid-connect/token"
end

RSpec.describe "OAuth error code echo" do # rubocop:disable RSpec/DescribeClass
  let(:secret) { "zebrasecretjk" }
  let(:config) do
    KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo", client_id: "svc",
                            client_secret: secret)
  end
  let(:client) { KeycloakSdk::KeycloakClient.new(config) }
  let(:provider) do
    http = KeycloakSdk::Http.build(config) do |f|
      f.request :url_encoded
      f.response :json, content_type: /\bjson$/
    end
    KeycloakSdk::ClientCredentialsTokenProvider.new(config: config, http: http)
  end
  let(:surfaces) do
    {
      "client_credentials" => -> { client.auth.client_credentials_token },
      "refresh" => -> { client.auth.refresh(refresh_token: OAuthErrorCodeEchoSpec::REFRESH_TOKEN) },
      "exchange_code" => lambda {
        client.auth.exchange_code(code: OAuthErrorCodeEchoSpec::CODE, code_verifier: OAuthErrorCodeEchoSpec::VERIFIER,
                                  redirect_uri: "http://localhost/cb")
      },
      "provider" => -> { provider.access_token },
      "admin" => -> { client.admin.users.get("u1") }
    }
  end

  # What this request sent: the form, plus the client secret from Basic (each part form-url-encoded, then base64).
  def sent(request)
    form = URI.decode_www_form(request.body.to_s).to_h
    auth = request.headers["Authorization"].to_s
    if auth.start_with?("Basic ")
      _, password = Base64.strict_decode64(auth.delete_prefix("Basic ")).split(":", 2)
      form["client_secret"] = URI.decode_www_form_component(password)
    end
    form
  end

  def answer_with(status: 400, &error)
    stub_request(:post, OAuthErrorCodeEchoSpec::TOKEN_URL).to_return do |request|
      { status: status, body: { error: error.call(sent(request)) }.to_json,
        headers: { "Content-Type" => "application/json" } }
    end
  end

  def failure(surface)
    surfaces.fetch(surface).call
    raise "no error"
  rescue KeycloakSdk::AuthError => e
    e
  end

  def renderings(err)
    out = [err.full_message(highlight: false)]
    node = err
    while node
      ivars = node.instance_variables.map { |v| node.instance_variable_get(v).inspect }.join
      out << node.message << node.inspect << ivars
      node = node.cause
    end
    out
  end

  def expect_withheld(err, value)
    expect(err.oauth_error).to be_nil
    expect(err.message).not_to include(value)
    renderings(err).each { |text| expect(text).not_to include(value) }
  end

  echo_forms = OAuthErrorCodeEchoSpec::ECHO_FORMS

  # Keycloak answers a bad client with 401, not 400 — an error status other than 400 takes the same rule.
  { "client_credentials" => [], "refresh" => %w[refresh_token], "exchange_code" => %w[code code_verifier],
    "provider" => [], "admin" => [] }.each do |surface, params|
    ["client_secret", *params].each do |param|
      it "withholds an echoed #{param} on a 401 on #{surface}" do
        seen = nil
        answer_with(status: 401) do |s|
          seen = s.fetch(param)
          seen
        end
        err = failure(surface)
        expect_withheld(err, seen)
      end
    end
  end

  describe "KeycloakSdk::OAuthErrorCode.carried" do
    {
      ["invalid_grant", ["s3cret-Value"]] => "invalid_grant",
      ["mysecret", ["mysecret"]] => nil,
      ["mysecret_x", ["mysecret"]] => nil,
      ["x_mysecret", ["mysecret"]] => nil,
      ["mysec", ["mysecret"]] => nil,
      ["secret", ["mysecret"]] => nil,
      ["yse", ["mysecret"]] => nil,
      ["fresh", %w[zzz myrefresh]] => nil,
      ["invalid_grant", [nil, ""]] => "invalid_grant",
      ["invalid_client", ["client"]] => nil,
      ["Invalid_grant", []] => nil,
      [["invalid_grant"], []] => nil
    }.each do |(value, sent), expected|
      it "#{value.inspect} against #{sent.inspect} is #{expected.inspect}" do
        expect(KeycloakSdk::OAuthErrorCode.carried(value, sent)).to eq(expected)
      end
    end
  end

  %w[client_credentials refresh exchange_code provider admin].each do |surface|
    echo_forms.each do |form, shape|
      it "withholds an echoed client secret (#{form}) on #{surface}" do
        answer_with { |s| shape.call(s.fetch("client_secret")) }
        expect_withheld(failure(surface), shape.call(secret))
      end
    end
  end

  { "refresh" => %w[refresh_token], "exchange_code" => %w[code code_verifier] }.each do |surface, params|
    params.product(echo_forms.to_a).each do |param, (form, shape)|
      it "withholds an echoed #{param} (#{form}) on #{surface}" do
        seen = nil
        answer_with do |s|
          seen = s.fetch(param)
          shape.call(seen)
        end
        err = failure(surface)
        expect_withheld(err, shape.call(seen))
      end
    end
  end

  not_a_code = {
    "keycloak-style secret" => "Kx7mQ2vT9pLr4WzN8bYc3FhJ6sDa1gE5",
    "jwt" => "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl",
    "capital letter" => "Invalid_client",
    "space" => "invalid client",
    "digit" => "invalid_client2",
    "65 characters" => "a" * 65,
    "empty" => "",
    "array" => ["invalid_client"],
    "number" => 400,
    "object" => { "code" => "invalid_client" }
  }
  %w[client_credentials refresh exchange_code provider admin].each do |surface|
    not_a_code.each do |name, value|
      it "carries no #{name} as a code on #{surface}" do
        answer_with { value }
        err = failure(surface)
        expect(err.oauth_error).to be_nil
        renderings(err).each { |text| expect(text).not_to include(value) } if value.is_a?(String) && !value.empty?
      end
    end

    ["invalid_client", "invalid_grant", "slow_down", "a" * 64].each do |value|
      it "still carries #{value[0, 20]} on #{surface}" do
        answer_with { value }
        expect(failure(surface).oauth_error).to eq(value)
      end
    end
  end

  it "shows a carried code in the grant message and withholds it there too" do
    answer_with { "invalid_grant" }
    expect(failure("refresh").message).to eq("refresh failed: invalid_grant (HTTP 400)")
    answer_with { |s| s.fetch("refresh_token") }
    expect(failure("refresh").message).to eq("refresh failed: non-standard error code (HTTP 400)")
  end

  context "with a public client (no secret sent)" do
    let(:config) do
      KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo", client_id: "svc")
    end

    it "still withholds the echoed refresh token and still carries a code" do
      answer_with { |s| s.fetch("refresh_token") }
      expect_withheld(failure("refresh"), OAuthErrorCodeEchoSpec::REFRESH_TOKEN)
      answer_with { "invalid_grant" }
      expect(failure("refresh").oauth_error).to eq("invalid_grant")
    end
  end

  context "when the secret is a piece of a registered code (the price, pinned)" do
    let(:secret) { "client" }

    it "withholds that code" do
      answer_with { "invalid_client" }
      expect(failure("client_credentials").oauth_error).to be_nil
      expect(failure("provider").oauth_error).to be_nil
    end
  end
end
