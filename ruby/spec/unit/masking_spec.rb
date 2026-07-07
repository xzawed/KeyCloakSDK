# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::Masking do
  it "masks a non-nil secret fully opaque" do
    expect(described_class.mask("super-secret")).to eq("***")
  end

  it "returns nil for nil" do
    expect(described_class.mask(nil)).to be_nil
  end
end
