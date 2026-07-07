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
end
