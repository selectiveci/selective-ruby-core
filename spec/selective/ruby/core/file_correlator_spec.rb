RSpec.describe Selective::Ruby::Core::FileCorrelator do
  let(:instance) { described_class.new([], 1, target_branch) }
  let(:target_branch) { "main" }

  describe "#correlate" do
    it "returns a hash with the expected shape" do
      # The fetch normally happens when the diff is generated
      # but if another runner created the manifest the fetch may
      # not have happened on the runner that is running this test.
      # So, we fetch here to ensure this test ddoes not fail.
      Open3.capture2e("git fetch origin #{target_branch} --depth=1")
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
