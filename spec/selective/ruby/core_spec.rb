# frozen_string_literal: true

RSpec.describe Selective::Ruby::Core do
  let(:mock_runner_class) { double("Selective::Ruby::MockRunner") }

  describe "self.runner_for" do
    it "returns the registered runner" do
      described_class.register_runner("mock-runner", mock_runner_class)
      expect(described_class.runner_for("mock-runner")).to eq(mock_runner_class)
    end
  end
end
