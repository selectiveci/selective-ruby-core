RSpec.describe Selective::Ruby::Core::FileCorrelator do
  let(:instance) { described_class.new({}, [], target_branch) }
  let(:target_branch) { "main" }

  describe "#correlate" do
    it "returns a hash with the expected shape" do
      expect(instance.correlate).to match({:correlated_files => Hash, :uncorrelated_files => Hash})
    end

    context 'when an error occurs' do
      let(:target_branch) { "unknown-branch" }

      it "warns and returns nil" do
        expect(instance).to receive(:print_warning).with(/please contact support/)
        expect(instance.correlate).to eq(nil)
      end
    end
  end
end
