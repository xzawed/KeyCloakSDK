# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::JwksStore do
  subject(:store) { described_class.new(jwks_url: jwks_url, http: http, min_refetch: 1000.0) }

  let(:config) { KeycloakSdk::Config.new(server_url: "https://k", realm: "r", client_id: "c") }
  let(:http) { KeycloakSdk::Http.build(config) { |f| f.response :json } }
  let(:jwks_url) { "https://k/realms/r/protocol/openid-connect/certs" }

  let(:body) { { keys: [{ kty: "RSA", kid: "k1", n: "AQAB", e: "AQAB" }] }.to_json }

  # ⚠️ **2차 정의 자리 금지**(Task D1). 이 클래스는 평범한 public 클래스라 소비자가 파사드를
  # 거치지 않고 직접 생성할 수 있다. 예전에는 그 경로의 기본값이 10.0이라 문서·config가 말하는
  # 30초가 아니라 **IdP를 3배 자주** 때렸고, 한글 README도 그 10.0을 옮겨 적고 있었다.
  # 이 예제는 "생략했을 때의 값"을 config 상수에 고정한다 — 리터럴을 다시 적으면 실패한다.
  it "min_refetch를 생략하면 Config의 기본값과 같다(정의 자리는 하나여야 한다)" do
    omitted = described_class.new(jwks_url: jwks_url, http: http)
    expect(omitted.instance_variable_get(:@min_refetch))
      .to eq(KeycloakSdk::Config::DEFAULT_JWKS_MIN_REFETCH)
  end

  it "fetches once (cold) and caches subsequent non-forced reads" do
    stub = stub_request(:get, jwks_url).to_return(status: 200, body: body,
                                                  headers: { "Content-Type" => "application/json" })
    3.times { store.key_set }
    expect(store.key_set["keys"].first["kid"]).to eq("k1")
    expect(stub).to have_been_requested.once
  end

  it "rate-limits forced re-fetches (unresolved kid) within the window" do
    stub = stub_request(:get, jwks_url).to_return(status: 200, body: body,
                                                  headers: { "Content-Type" => "application/json" })
    store.key_set                    # cold load (no stamp)
    store.key_set(force: true)       # 1st forced → allowed → stamp + fetch
    store.key_set(force: true)       # within window → rate-limited → serve stale, no fetch
    expect(stub).to have_been_requested.times(2)
  end

  it "raises TransportError on non-200" do
    stub_request(:get, jwks_url).to_return(status: 500, body: "err")
    expect { store.key_set }.to raise_error(KeycloakSdk::TransportError)
  end

  it "raises TransportError on malformed body" do
    stub_request(:get, jwks_url).to_return(status: 200, body: { nope: 1 }.to_json,
                                           headers: { "Content-Type" => "application/json" })
    expect { store.key_set }.to raise_error(KeycloakSdk::TransportError)
  end

  it "raises TransportError on connection failure" do
    stub_request(:get, jwks_url).to_raise(Faraday::ConnectionFailed.new("refused"))
    expect { store.key_set }.to raise_error(KeycloakSdk::TransportError)
  end

  it "raises TransportError (not a raw Faraday::SSLError) on TLS verification failure" do
    stub_request(:get, jwks_url).to_raise(Faraday::SSLError.new("cert verify failed"))
    expect { store.key_set }.to raise_error(KeycloakSdk::TransportError)
  end

  it "keeps the rate-limit gate stamped even when a forced re-fetch fails (bounded flood, nil cache)" do
    stub = stub_request(:get, jwks_url).to_return(status: 500, body: "err")
    # cold-cache forced fetch fails but must stamp the gate at the decision point
    expect { store.key_set(force: true) }.to raise_error(KeycloakSdk::TransportError)
    # a second forced call within the min_refetch window is rate-limited -> NO further network hit
    store.key_set(force: true)
    expect(stub).to have_been_requested.once
  end

  it "allows a forced re-fetch once the cooldown has elapsed" do
    fast_store = described_class.new(jwks_url: jwks_url, http: http, min_refetch: 0.0)
    stub = stub_request(:get, jwks_url).to_return(status: 200, body: body,
                                                  headers: { "Content-Type" => "application/json" })
    fast_store.key_set(force: true) # cold forced load -> stamp + fetch
    fast_store.key_set(force: true) # cooldown (0.0) already elapsed -> refetch_allowed? true -> fetch again
    expect(stub).to have_been_requested.times(2)
  end

  it "raises TransportError on non-Hash body (array)" do
    stub_request(:get, jwks_url).to_return(status: 200, body: [1, 2, 3].to_json,
                                           headers: { "Content-Type" => "application/json" })
    expect { store.key_set }.to raise_error(KeycloakSdk::TransportError)
  end

  # ⚠️ 여기부터가 콜드 캐시 + IdP 장애 축이다. `min_refetch`(30초) 게이트는 *캐시가 찬 뒤*
  # 미해결 kid 홍수만 막는다 — 캐시가 비어 있고 fetch 가 계속 실패하면 그 게이트에 닿지도
  # 못한다. 실측(2026-09-04): 20회 검증 → IdP 요청 **20건**, 7개 언어 동일.
  describe "failed-fetch backoff (cold cache + failing IdP)" do
    it "bounds retries while the IdP is failing — 20회 시도가 요청 1건이 된다" do
      stub = stub_request(:get, jwks_url).to_return(status: 500, body: "err")
      20.times do
        store.key_set
      rescue KeycloakSdk::TransportError
        nil
      end
      expect(stub).to have_been_requested.once
    end

    # ⚠️ **이 예제를 지우지 말 것 — 위 단언은 「한 번 실패하면 영원히 차단」으로도 통과한다.**
    # 그 동작은 원래 결함보다 나쁘다(IdP 가 복구돼도 SDK 가 영영 못 쓴다).
    it "백오프가 지나면 다시 시도한다 (대조군)" do
      stub = stub_request(:get, jwks_url).to_return(status: 500, body: "err")
      now = 1000.0
      # ⚠️ 대상 객체가 아니라 **stdlib 시계**를 스텁한다(RSpec/SubjectStub 회피). 인자를 좁혀
      # 다른 clock_gettime 호출은 원본으로 흘린다.
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { now }

      expect { store.key_set }.to raise_error(KeycloakSdk::TransportError)
      expect(stub).to have_been_requested.once

      # 창 안 — 네트워크로 나가지 않고 즉시 실패한다(sleep 하지 않는다).
      expect { store.key_set }.to raise_error(KeycloakSdk::TransportError, /backing off/)
      expect(stub).to have_been_requested.once

      # 창을 넘기면(상한 5초보다 크게 민다) 다시 나간다.
      now += 10.0
      expect { store.key_set }.to raise_error(KeycloakSdk::TransportError)
      expect(stub).to have_been_requested.times(2)
    end

    # ⚠️ 대조군 둘째 — 성공이 실패 카운터를 되돌리지 않으면 오래 산 프로세스에서 백오프가
    # 상한까지 올라간 채 영영 내려오지 않는다.
    it "성공하면 실패 카운터가 0으로 돌아간다 (대조군)" do
      now = 1000.0
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { now }
      stub_request(:get, jwks_url).to_return({ status: 500, body: "err" },
                                             { status: 200, body: body,
                                               headers: { "Content-Type" => "application/json" } })
      expect { store.key_set }.to raise_error(KeycloakSdk::TransportError)
      expect(store.send(:instance_variable_get, :@failures)).to eq(1)

      now += 10.0
      expect(store.key_set["keys"].first["kid"]).to eq("k1")
      expect(store.send(:instance_variable_get, :@failures)).to eq(0)
      expect(store.send(:backing_off?)).to be(false)
    end

    # 정상 경로가 백오프에 걸리지 않는다는 것을 못 박는다(위 "fetches once (cold)" 와 함께).
    it "정상 IdP 에서는 백오프가 관여하지 않는다 (대조군)" do
      stub = stub_request(:get, jwks_url).to_return(status: 200, body: body,
                                                    headers: { "Content-Type" => "application/json" })
      20.times { store.key_set }
      expect(stub).to have_been_requested.once
      expect(store.send(:backing_off?)).to be(false)
    end
  end
end
