RSpec.describe Selective::Ruby::Core::Init do
  describe ".run" do
    let(:mock_runner_class) { double("Selective::Ruby::MockRunner", new: mock_runner_instance) }
    let(:mock_runner_instance) { double("Selective::Ruby::MockRunner - Instance") }
    let(:mock_controller) { instance_double(Selective::Ruby::Core::Controller, exec: nil, start: nil) }

    before do
      allow(Selective::Ruby::Core::Controller).to receive(:new).and_return(mock_controller)
      allow(Selective::Ruby::Core).to receive(:runner_for).with("mock_runner").and_return(mock_runner_class)
      described_class.run(args)
    end

    context "with 'selective exec mock_runner'" do
      let(:args) { %w[exec mock_runner] }

      it "initializes runner and calls exec" do
        expect(Selective::Ruby::Core::Controller).to have_received(:new).with(mock_runner_instance, debug: false, log: false)
        expect(mock_runner_class).to have_received(:new).with([])
        expect(mock_controller).to have_received(:exec)
      end
    end

    context "with 'selective exec mock_runner --dry-run'" do
      let(:args) { %w[exec mock_runner --dry-run] }

      it "initializes runner with the --dry-run option and calls exec" do
        expect(Selective::Ruby::Core::Controller).to have_received(:new).with(mock_runner_instance, debug: false, log: false)
        expect(mock_runner_class).to have_received(:new).with(["--dry-run"])
        expect(mock_controller).to have_received(:exec)
      end
    end

    context "with 'selective mock_runner'" do
      let(:args) { %w[mock_runner] }

      it "initializes runner and calls start" do
        expect(Selective::Ruby::Core::Controller).to have_received(:new).with(mock_runner_instance, debug: false, log: false)
        expect(mock_runner_class).to have_received(:new).with([])
        expect(mock_controller).to have_received(:start)
      end
    end

    context "with 'selective mock_runner --debug'" do
      let(:args) { %w[mock_runner --debug] }

      it "initializes runner with debug and calls start" do
        expect(Selective::Ruby::Core::Controller).to have_received(:new).with(mock_runner_instance, debug: true, log: false)
        expect(mock_runner_class).to have_received(:new).with([])
        expect(mock_controller).to have_received(:start)
      end
    end

    context "with 'selective mock_runner --log'" do
      let(:args) { %w[mock_runner --log] }

      it "initializes runner with debug and calls start" do
        expect(Selective::Ruby::Core::Controller).to have_received(:new).with(mock_runner_instance, debug: false, log: true)
        expect(mock_runner_class).to have_received(:new).with([])
        expect(mock_controller).to have_received(:start)
      end
    end

    context "with 'selective mock_runner spec/foo/bar_spec.rb'" do
      let(:args) { %w[mock_runner spec/foo/bar_spec.rb] }

      it "initializes runner with file path and calls start" do
        expect(Selective::Ruby::Core::Controller).to have_received(:new).with(mock_runner_instance, debug: false, log: false)
        expect(mock_runner_class).to have_received(:new).with(["spec/foo/bar_spec.rb"])
        expect(mock_controller).to have_received(:start)
      end
    end
  end
end
