# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk do
  # ⚠️ 이 스펙은 한때 `/\A\d+\.\d+\.\d+\z/`로 X.Y.Z만 허용했다. 그러면 **RC 릴리스가 불가능하다** —
  # `ruby-release.yml`의 release 잡은 `gem push` 앞에서 `bundle exec rspec`을 돌리므로, 매니페스트를
  # `0.1.0.rc1`로 범프한 순간 이 한 줄이 릴리스를 막는다(태그는 이미 소모된 뒤에).
  #
  # 허용 형식은 저장소의 기계가독 SSOT인 `scripts/lib/deploy-facts.sh`의 `df_version_re ruby`와
  # 같은 모양으로 유지한다: `^[0-9]+\.[0-9]+\.[0-9]+(\.(alpha|beta|rc)[0-9]+)?$`
  # 한쪽만 바꾸면 `release-trigger.sh`는 통과시키는데 CI가 막는(또는 그 반대) 상태가 된다.
  subject(:version) { KeycloakSdk::VERSION }

  let(:rubygems_version_re) { /\A\d+\.\d+\.\d+(\.(?:alpha|beta|rc)\d+)?\z/ }

  it "exposes a version in the RubyGems spelling (X.Y.Z, optionally .rcN)" do
    expect(version).to match(rubygems_version_re)
  end

  it "exposes a version RubyGems itself can parse" do
    expect { Gem::Version.create(version) }.not_to raise_error
  end

  # ⚠️ 대조군 — 정규식을 느슨하게 풀어(예: `.*`) 검사를 무력화하면 아래 두 예제가 실패한다.
  # 특히 SemVer 표기(`0.1.0-rc.1`)는 반드시 거부해야 한다: RubyGems는 점 구분(`0.1.0.rc1`)을 쓰고,
  # 하이픈 표기는 `release-trigger.sh`가 먼저 막지만 그걸 거치지 않고 직접 범프하는 경로가 있다.
  it "rejects the SemVer prerelease spelling (RubyGems uses dots, not a hyphen)" do
    expect(rubygems_version_re.match?("0.1.0-rc.1")).to be(false)
  end

  it "rejects a non-version string" do
    expect(rubygems_version_re.match?("nightly")).to be(false)
  end

  # 프리릴리스로 범프했을 때 RubyGems가 실제로 프리릴리스로 인식하는지 — 인식하지 못하면
  # 맨 `gem install keycloak-sdk`가 RC를 정식판처럼 설치해 버린다.
  it "treats an .rcN version as a prerelease" do
    expect(Gem::Version.new("0.1.0.rc1")).to be_prerelease
  end

  it "treats a plain X.Y.Z version as a final release" do
    expect(Gem::Version.new("0.1.0")).not_to be_prerelease
  end
end
