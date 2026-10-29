# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "openssl"
require_relative "../support/unsendable"

# The bearer token grammar, identical in the nine SDKs (registry bearer-token-grammar-divergent, decision 2026-10-29).
#
# SP, HTAB, CR and LF are trimmed from both ends of the token, and nothing else is — not NBSP, U+3000, VT or FF, so
# never `strip`, which also takes NUL, VT and FF. What is left must be a non-empty RFC 6750 b64token
# (`\A[A-Za-z0-9\-._~+/]+=*\z` — ASCII only, `=` only as trailing padding). Such a token goes out trimmed. Any other
# is never sent: the admin request fails before a byte reaches the server, with the AuthError the admin lane gives a
# bearer it cannot send, quoting none of the token. The SDK's own ClientCredentialsTokenProvider refuses it the same
# way and caches nothing. The rule runs on the provider value's text (#874 turns a value that is not a String into
# text first).
#
# Every row runs through every lane the SDK supplies the bearer on: (a) a facade call, (b) `raw`, (c) the SDK's own
# grant through KeycloakClient#admin, and the provider itself.
module BearerGrammarSpec
  SEND = "admin request not sent: the access token is not an RFC 6750 bearer token (b64token)"
  GRANT = "token response has no usable access_token: it is not an RFC 6750 bearer token (b64token)"
  # Answered before the grammar is asked, as before: TokenSet refuses an empty access_token, and the response decoder
  # one that is not valid UTF-8 (`Http.decode_json`).
  NO_TOKEN = "token response has no usable access_token"
  UNDECODABLE = "token endpoint transport error: Faraday::ParsingError"
  TOKEN_URL = "#{UnsendableTokenSpec::OIDC}/token".freeze
  # A real three-segment JWS — an RS256 signature over a claims set, from a key made for the test.
  JWS = JWT.encode({ sub: "x", aud: "c" }, OpenSSL::PKey::RSA.generate(2048), "RS256").freeze
  BAD_BYTE = "abc#{0xFF.chr}".force_encoding(Encoding::UTF_8).freeze

  # One row: want is the token "Bearer " is followed by — nil when the request must not be sent.
  Row = Data.define(:input, :want)
  CASES = {
    "plain" => Row.new("abc.DEF-ghi_jkl~mno+pqr/stu", "abc.DEF-ghi_jkl~mno+pqr/stu"),
    "pad" => Row.new("abc==", "abc=="),
    "jwt" => Row.new(JWS, JWS),
    "lf" => Row.new("abc\n", "abc"),
    "crlf" => Row.new("abc\r\n", "abc"),
    "lead-tab" => Row.new(" \tabc\t ", "abc"),
    "inner-sp" => Row.new("a bc", nil),
    "inner-tab" => Row.new("a\tbc", nil),
    "inner-crlf" => Row.new("a\r\nX-Evil: 1", nil),
    "mid-pad" => Row.new("a=bc", nil),
    "empty" => Row.new("", nil),
    "blank" => Row.new(" \t\r\n", nil),
    "latin1" => Row.new("abcé", nil),
    "above-ff" => Row.new("abcĀ", nil),
    "c1" => Row.new("abc\u0085", nil),
    "nul" => Row.new("abc\u0000", nil),
    "del" => Row.new("abc\u007f", nil),
    "nbsp" => Row.new("abc ", nil),
    "ideographic" => Row.new("　abc", nil),
    "vt" => Row.new("abc\v", nil),
    # Byte strings: a byte no UTF-8 string has.
    "invalid-utf8" => Row.new(BAD_BYTE, nil)
  }.freeze

  module_function

  def admin(token)
    KeycloakSdk::Admin::AdminClient.new(config: UnsendableTokenSpec.config,
                                        token_provider: UnsendableTokenSpec::Fixed.new(token))
  end

  def provider
    config = UnsendableTokenSpec.config
    http = KeycloakSdk::Http.build(config) do |f|
      f.request :url_encoded
      f.response :json, content_type: /\bjson$/
    end
    KeycloakSdk::ClientCredentialsTokenProvider.new(config: config, http: http)
  end

  # The token response carrying the row's token. JSON is not generated from a string that is not valid UTF-8, so that
  # row's body is written byte for byte.
  def token_response(token)
    fields = { access_token: token, token_type: "Bearer", expires_in: 300 }
    body = if token.valid_encoding?
             fields.to_json
           else
             [%({"access_token":"), token, %(","token_type":"Bearer","expires_in":300})].map(&:b).join
           end
    { status: 200, headers: UnsendableTokenSpec::JSON_TYPE, body: body }
  end

  # The grant lane's refusal: the decoder and TokenSet answer two rows first, the grammar the rest.
  def grant_refusal(id)
    case id
    when "empty" then [KeycloakSdk::AuthError, NO_TOKEN]
    when "invalid-utf8" then [KeycloakSdk::TransportError, UNDECODABLE]
    else [KeycloakSdk::AuthError, GRANT]
    end
  end

  # Whether an error or one of its causes shows the token: every row with anything to leak holds "bc", inner-crlf also
  # "X-Evil".
  def quotes_token?(err)
    texts = []
    while err
      texts.push(err.message, err.inspect)
      err = err.cause
    end
    texts.any? { |s| s.b.include?("bc") || s.b.include?("X-Evil") }
  end
end

RSpec.describe KeycloakSdk::Admin::BearerAuth do
  let(:spec) { BearerGrammarSpec }
  let(:users) do
    stub_request(:get, UnsendableTokenSpec::USERS).to_return(status: 200, headers: UnsendableTokenSpec::JSON_TYPE,
                                                             body: "[]")
  end

  before { users }

  def carried(want, times)
    expect(a_request(:get, UnsendableTokenSpec::USERS)
      .with { |r| r.headers["Authorization"].b == "Bearer #{want}".b }).to have_been_made.times(times)
    expect(users).to have_been_requested.times(times)
  end

  # (a) a facade call and (b) `raw` — both take the bearer from the injected provider through the middleware.
  { "a facade call" => ->(a) { a.users.list }, "raw" => ->(a) { a.raw.get("admin/realms/r/users") } }
    .each do |via, call|
    BearerGrammarSpec::CASES.each do |id, row|
      it "#{id}: #{row.want ? "sends #{row.want[0, 16].inspect}" : 'refuses it without sending'} through #{via}" do
        if row.want
          call.call(spec.admin(row.input))
          carried(row.want, 1)
        else
          expect { call.call(spec.admin(row.input)) }.to raise_error(KeycloakSdk::AuthError) { |e|
            expect(e.message).to eq(BearerGrammarSpec::SEND)
            expect(spec.quotes_token?(e)).to be(false)
          }
          expect(users).not_to have_been_requested
        end
      end
    end
  end

  # (c) The SDK's own grant: the token endpoint answers with the row's token. A refused token is not cached — the next
  # call asks the IdP again and fails the same way; a sent one is cached as it was sent — the next call asks the IdP
  # nothing.
  describe "the SDK's own grant (KeycloakClient#admin)" do
    BearerGrammarSpec::CASES.each do |id, row|
      it "#{id}: #{row.want ? 'caches the trimmed token and sends it' : 'refuses it and caches nothing'}" do
        grant = stub_request(:post, BearerGrammarSpec::TOKEN_URL).to_return(spec.token_response(row.input))
        kc = KeycloakSdk::KeycloakClient.new(UnsendableTokenSpec.config)
        if row.want
          2.times { kc.admin.users.list }
          carried(row.want, 2)
          expect(grant).to have_been_requested.once
        else
          klass, message = spec.grant_refusal(id)
          2.times do
            expect { kc.admin.users.list }.to raise_error(klass, message) { |e|
              expect(spec.quotes_token?(e)).to be(false)
            }
          end
          expect(grant).to have_been_requested.twice
          expect(users).not_to have_been_requested
        end
      end

      it "#{id}: the provider itself #{row.want ? 'hands out the trimmed token' : 'raises and caches nothing'}" do
        grant = stub_request(:post, BearerGrammarSpec::TOKEN_URL).to_return(spec.token_response(row.input))
        provider = spec.provider
        if row.want
          2.times { expect(provider.access_token).to eq(row.want) }
          expect(grant).to have_been_requested.once
        else
          klass, message = spec.grant_refusal(id)
          2.times { expect { provider.access_token }.to raise_error(klass, message) }
          expect(grant).to have_been_requested.twice
        end
      end
    end
  end
end
