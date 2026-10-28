# frozen_string_literal: true

RSpec.describe "with_env" do
  it "restores a variable that was already set when the block raises" do
    key = "SELECTIVE_TRANSPORT"
    with_env(key => "ci-value") do
      expect {
        with_env(key => "replacement") { raise "boom" }
      }.to raise_error("boom")

      expect(ENV[key]).to eq("ci-value")
    end
  end

  it "leaves an unset variable unset when the block raises" do
    key = "SELECTIVE_WITH_ENV_PROBE"
    with_env(key => nil) do
      expect {
        with_env(key => "temporary") { raise "boom" }
      }.to raise_error("boom")

      expect(ENV[key]).to be_nil
    end
  end
end
