# frozen_string_literal: true

require "spec_helper"
require "uri"
require_relative "../support/keycloak_container"
require_relative "../support/browser_login"

# 인가 코드 교환 E2E — 실제 Keycloak 이 발급한 코드·id_token 으로(python `test_code_exchange_it.py` 의 이식).
#
# `exchange_code` 의 nonce 대조와 id_token 서명 검증은 지금까지 목 토큰으로만 돌았다. 여기서는 `BrowserLogin` 으로
# 실제 로그인해 받은 코드를 교환하고, **서버가 서명한** 토큰에 대고 거부 경로까지 돈다. JWKS 밖 키로 서명한
# RS256 id_token 은 실서버가 만들 수 없어 단위(`spec/unit/exchange_code_forged_id_token_spec.rb`)가 맡는다.
module CodeExchangeIT
  # realm JSON 의 `it-web`(RS256)·`it-web-hs256`(id_token 을 HS256 서명)과 짝.
  # ⚠️ `it-web` 의 audience 매퍼는 introspect 용이다 — `aud` 가 없는 접근 토큰을 Keycloak 26.6 은 발급한 그
  # 클라이언트가 물어도 `{"active": false}` 로 답한다(python 파일럿 실측).
  REDIRECT_URI = "http://localhost/it-callback"
  WEB_CLIENT_SECRETS = { "it-web" => "it-web-secret", "it-web-hs256" => "it-web-hs256-secret" }.freeze
  ALICE = %w[alice alice-password].freeze

  # ⚠️ 기본값(알고리즘 핀·오디언스)은 **넘기지 않는다** — 늘 명시하면 `Config` 기본값이 넓어져도 이 스펙이 못 본다(Grok 레그 실측).
  def self.web_config(base, client_id = "it-web", **overrides)
    KeycloakSdk::Config.new(server_url: base, realm: "it-realm", client_id: client_id,
                            client_secret: WEB_CLIENT_SECRETS.fetch(client_id), **overrides)
  end

  # 인가 URL 에서 `nonce` 만 뺀다 — 서버가 nonce 클레임 **없는** id_token 을 서명하게 한다.
  def self.strip_nonce(request)
    url = URI(request.url)
    url.query = URI.encode_www_form(URI.decode_www_form(url.query).to_h.except("nonce"))
    request.with(url: url.to_s)
  end

  # 예외와 그 `cause` 사슬(바깥부터).
  def self.cause_chain(error)
    chain = []
    while error && chain.size < 10
      chain << error
      error = error.cause
    end
    chain
  end

  # 예외가 사람·로거에게 보일 수 있는 표현 전부 — `full_message`(잡히지 않은 예외·로거가 찍는 것, 사슬 포함)·
  # `detailed_message` · 각 고리의 message·inspect·인스턴스 변수(`inspect` 는 ivar 를 안 찍는다).
  def self.renderings(error)
    texts = [error.full_message(highlight: false), error.detailed_message(highlight: false)]
    cause_chain(error).each do |link|
      texts << link.message << link.inspect
      texts.concat(link.instance_variables.map { |ivar| link.instance_variable_get(ivar).inspect })
    end
    texts
  end
end

RSpec.describe "Authorization code exchange against a real Keycloak", :integration do
  before(:all) do
    WebMock.allow_net_connect! # 통합에서는 실네트워크 허용
    @base = KeycloakContainer.shared_base_url(fixtures_dir: File.expand_path("../fixtures", __dir__))
    @alice_id = fetch_alice_id
  end

  after(:all) do
    WebMock.disable_net_connect!(allow_localhost: false)
  end

  after { @clients&.each(&:close) }

  def new_client(...)
    (@clients ||= []) << KeycloakSdk::KeycloakClient.new(CodeExchangeIT.web_config(@base, ...))
    @clients.last
  end

  # `hidden` 중 어느 것도 `error` 의 표현(`CodeExchangeIT.renderings`)에 나오지 않는다.
  def expect_no_secret_in(error, hidden)
    texts = CodeExchangeIT.renderings(error)
    hidden.each do |secret|
      expect(secret).to match(/\A\S{8,}\z/)
      texts.each { |text| expect(text).not_to include(secret) }
    end
  end

  def login(client, request = client.auth.create_authorization_request(redirect_uri: CodeExchangeIT::REDIRECT_URI))
    [request, BrowserLogin.browser_login(request, CodeExchangeIT::REDIRECT_URI, *CodeExchangeIT::ALICE)]
  end

  def exchange(client, request, code, nonce: request.nonce)
    client.auth.exchange_code(code: code, code_verifier: request.code_verifier,
                              redirect_uri: CodeExchangeIT::REDIRECT_URI, expected_nonce: nonce)
  end

  # `alice` 의 사용자 id — 토큰의 `sub` 와 대조할 **독립 원천**(admin API)에서 읽는다.
  def fetch_alice_id
    admin = KeycloakSdk::KeycloakClient.new(
      KeycloakSdk::Config.new(server_url: @base, realm: "it-realm", client_id: "it-client", client_secret: "it-secret")
    )
    users = admin.admin.users.list(username: "alice", exact: true).select { |u| u["username"] == "alice" }
    expect(users.size).to eq(1)
    users.first.fetch("id")
  ensure
    admin&.close
  end

  it "binds the tokens to the nonce and the user, then refreshes, introspects and logs out" do
    kc = new_client
    request, code = login(kc)
    tokens = exchange(kc, request, code)
    expect([tokens.access_token, tokens.refresh_token, tokens.id_token]).to all(match(/\A\S+\z/))
    id_claims = kc.auth.validate(tokens.id_token).claims
    expect(id_claims["nonce"]).to eq(request.nonce)
    expect(id_claims["sub"]).to eq(@alice_id)
    # 교환이 돌려준 접근 토큰도 서버가 발급한 그 사용자의 활성 토큰이다(Grok 레그: 자리표시자로 바꿔도 통과했다).
    access = kc.auth.validate(tokens.access_token)
    expect([access.subject, access.audience]).to match([@alice_id, include("it-web")])
    expect(kc.auth.introspect(tokens.access_token).active?).to be(true)

    # refresh: 새 접근 토큰을 준다 — 같은 사용자의 활성 토큰이다.
    refreshed = kc.auth.refresh(refresh_token: tokens.refresh_token)
    expect(refreshed.access_token).to match(/\A\S+\z/)
    expect(refreshed.access_token).not_to eq(tokens.access_token)
    expect(refreshed.refresh_token).to match(/\A\S+\z/)
    active = kc.auth.introspect(refreshed.access_token)
    expect(active.active?).to be(true)
    expect(active.username).to eq("alice")

    # logout: 세션을 끝낸다 — 그 refresh token 은 더는 갱신되지 않고 접근 토큰은 비활성이 된다.
    expect(kc.auth.logout(refresh_token: refreshed.refresh_token)).to be_nil
    expect { kc.auth.refresh(refresh_token: refreshed.refresh_token) }
      .to raise_error(KeycloakSdk::AuthError) { |e|
        expect(e.oauth_error).to eq("invalid_grant")
        # 거부된 refresh 의 오류도 보낸 refresh token·시크릿을 싣지 않는다(교환 경로와 다른 오류 자리다).
        expect_no_secret_in(e, [refreshed.refresh_token, CodeExchangeIT::WEB_CLIENT_SECRETS["it-web"]])
      }
    expect(kc.auth.introspect(refreshed.access_token).active?).to be(false)
  end

  # 문서화된 선택 해제 — `expected_nonce` 를 안 주면 id_token 을 보지 않고 돌려준다(nonce 가 실려 있어도).
  it "returns the tokens unchecked when no nonce is expected (documented opt-out)" do
    kc = new_client
    request, code = login(kc)
    tokens = exchange(kc, request, code, nonce: nil)
    expect(kc.auth.validate(tokens.id_token).claims["nonce"]).to eq(request.nonce)
  end

  # 오디언스 검사가 실서버 id_token 에서 돈다 — `expected_audience` 를 이 클라이언트가 아닌 값으로 두면 거부한다.
  it "refuses an id_token whose aud lacks the expected audience" do
    kc = new_client(expected_audience: "it-client")
    request, code = login(kc)
    expect { exchange(kc, request, code) }
      .to raise_error(KeycloakSdk::AuthError, /\Aauthorization_code exchange failed: invalid id_token: .*audience/i)
  end

  it "refuses a nonce the server did not sign" do
    kc = new_client
    request, code = login(kc)
    expect { exchange(kc, request, code, nonce: "x#{request.nonce}") }
      .to raise_error(KeycloakSdk::AuthError, "authorization_code exchange failed: unexpected nonce") { |e|
        expect(e.oauth_error).to be_nil # 서버가 아니라 SDK 가 거부했다
      }
  end

  it "refuses an id_token that carries no nonce when one is expected" do
    kc = new_client
    request = CodeExchangeIT.strip_nonce(kc.auth.create_authorization_request(redirect_uri: CodeExchangeIT::REDIRECT_URI))
    # 전제: 서버가 정말 nonce 없이 서명한다(아니면 아래는 부재가 아니라 불일치를 잰다).
    _, code = login(kc, request)
    unchecked = exchange(kc, request, code, nonce: nil)
    expect(kc.auth.validate(unchecked.id_token).claims).not_to have_key("nonce")

    _, code = login(kc, request)
    expect { exchange(kc, request, code) }
      .to raise_error(KeycloakSdk::AuthError, "authorization_code exchange failed: unexpected nonce")
  end

  it "refuses a reused code without leaking the code, verifier, secret or tokens" do
    kc = new_client
    request, code = login(kc) # 로그인 자체의 기록(콜백 URL 에 코드가 실린다)은 SDK 의 누출이 아니다 — 여기서부터 잰다.
    tokens = reused = nil
    hidden = lambda do
      [code, request.code_verifier, CodeExchangeIT::WEB_CLIENT_SECRETS["it-web"],
       tokens.access_token, tokens.refresh_token, tokens.id_token]
    end
    prints_no_secret = satisfy("print no secret") { |text| hidden.call.none? { |secret| text.include?(secret) } }
    expect do
      tokens = exchange(kc, request, code)
      reused = begin
        exchange(kc, request, code)
      rescue KeycloakSdk::Error => e
        e
      end
    end.to output(prints_no_secret).to_stdout_from_any_process.and output(prints_no_secret).to_stderr_from_any_process

    expect(reused).to be_a(KeycloakSdk::AuthError)
    expect(reused.oauth_error).to eq("invalid_grant")
    expect_no_secret_in(reused, hidden.call)
    # 거부가 **서버**의 것이었다 — Keycloak 은 코드 재사용을 보면 그 코드로 연 클라이언트 세션을 끊는다. SDK 가 두 번째
    # 요청을 안 보내고 흉내만 냈다면 첫 교환의 토큰은 살아 있다(Grok 레그: 로컬에서 invalid_grant 를 지어내도 통과했다).
    expect(kc.auth.introspect(tokens.access_token).active?).to be(false)
  end

  # `it-web-hs256` 의 id_token 은 realm 의 HMAC 키로 서명된다 — 대칭키는 JWKS 에 없다.
  # 두 변형이 서로 다른 층에서 거부되는지를 하위 원인의 클래스(`RedactedCause#lower_classes`)와 메시지로 가른다.
  # ⚠️ ruby-jwt 3.3 에서 「kid 없음」은 `DecodeError` 가 아니라 `SignatureError` 다(`jwk/key_finder.rb:36`, 실측).
  # 첫 변형은 `Config` **기본** 핀(RS256)이다 — 명시하지 않아야 기본값이 넓어지는 회귀를 잡는다.
  {
    nil => ["JWT::IncorrectAlgorithm", /Expected a different algorithm\z/], # 알고리즘 핀이 먼저 거부한다
    %w[RS256 HS256] => ["JWT::SignatureError", /Could not find public key for kid \S+\z/] # 핀을 열어도 JWKS 에 키가 없다
  }.each do |algorithms, (lower, reason)|
    it "refuses an id_token signed by a key outside the JWKS (algorithms #{algorithms&.join('+') || 'default'})" do
      kc = algorithms ? new_client("it-web-hs256", signature_algorithms: algorithms) : new_client("it-web-hs256")
      request, code = login(kc)
      expect { exchange(kc, request, code) }
        .to raise_error(KeycloakSdk::AuthError, /\Aauthorization_code exchange failed: invalid id_token: /) { |e|
          expect(e.message).to match(reason)
          expect(e.cause).to be_a(KeycloakSdk::TokenValidationError)
          expect(e.cause.cause.lower_classes.first).to eq(lower)
        }
    end
  end
end
