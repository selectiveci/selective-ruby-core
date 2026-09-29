# frozen_string_literal: true

RSpec.describe Selective::Ruby::Core::Controller do
  let(:runner_class) { class_double("runner_class", new: runner) }
  let(:runner) { double("runner", finish: nil, exit_status: 1, framework: 'rspec', framework_version: "1.0", wrapper_version: "1.0") }
  let(:controller) { dirty_dirty_unprivate_class(described_class).new(runner_class, nil) }

  let!(:pipe) { Selective::Ruby::Core::NamedPipe.new("/tmp/#{controller.runner_id}_test_2", "/tmp/#{controller.runner_id}_test_1", skip_reset: true) }
  let!(:reverse_pipe) { Selective::Ruby::Core::NamedPipe.new("/tmp/#{controller.runner_id}_test_1", "/tmp/#{controller.runner_id}_test_2", skip_reset: true) }

  before do
    allow(Process).to receive(:spawn).and_return(123)
    allow(controller).to receive(:kill_transport)
    allow(controller).to receive(:handle_termination_signals)
    allow(controller).to receive(:wait_for_connectivity)
    allow(controller).to receive(:exit)
  end

  describe "#start" do
    before do
      allow(controller).to receive(:print_notice)
      allow(described_class).to receive(:restore_reporting!)
    end

    it "processes commands" do
      message = "Hello World"

      send_commands(controller, [
        {command: "print_notice", message: message}
      ])

      expect(controller).to have_received(:print_notice).once.with(message)
      expect(runner).to have_received(:finish).once
    end

    it "handles the remove_failed_test_case_result command" do
      test_case_id = "spec/abc/123_spec.rb"
      allow(runner).to receive(:remove_test_case_result)

      send_commands(controller, [
        {command: "remove_failed_test_case_result", test_case_id: test_case_id}
      ])

      expect(runner).to have_received(:remove_test_case_result).once.with(test_case_id)
    end

    it "handles the print_message command" do
      allow(controller).to receive(:puts_indented)
      allow(controller).to receive(:print_warning).and_call_original

      send_commands(controller, [
        {command: "print_message", message: "Hello World"}
      ])

      expect(controller).to have_received(:print_warning).once.with("Hello World")
    end

    it "handles the reconnect command" do
      expect(controller).to receive(:kill_transport).twice # Once for the reconnect, once for the close
      expect(pipe).to receive(:reset!)
      allow(controller).to receive(:start).with(no_args).and_call_original
      expect(controller).to receive(:start).with(reconnect: true).once

      send_commands(controller, [
        {command: "reconnect"}
      ])
    end

    context "when a ConnectionLostError occurs" do
      before do
        allow(controller).to receive(:puts)
        allow(controller).to receive(:sleep)
        allow(pipe).to receive(:reset!)
      end

      # Loses the first connection, then runs `commands` (and a close) on the
      # second. Returns how many connections were attempted.
      def lose_connection_once(controller, commands = [])
        attempts = 0
        allow(Selective::Ruby::Core::NamedPipe).to receive(:new).and_call_original
        allow(Selective::Ruby::Core::NamedPipe).to receive(:new)
          .with("/tmp/#{controller.runner_id}_2", "/tmp/#{controller.runner_id}_1") do
            attempts += 1
            raise Selective::Ruby::Core::ConnectionLostError if attempts == 1
            pipe
          end
        # The first attempt fails before a pipe exists; retrying resets the
        # (mocked) one.
        allow(controller).to receive(:pipe).and_return(pipe)

        allow(controller).to receive(:run_main_loop).and_wrap_original do |original_method, *args, &block|
          sleep(0.1) # NamedPipe opens its ends in threads
          (commands | [{command: "close"}]).each { |command| reverse_pipe.write(command.to_json) }
          original_method.call(*args, &block)
        end

        controller.start
        attempts
      end

      it "reconnects and increments the retries counter" do
        expect(lose_connection_once(controller)).to eq(2)
        expect(controller.retries).to eq(1)
        expect(Process).to have_received(:spawn).with(anything, /reconnect=true/, anything)
        expect(runner).to have_received(:finish).once
      end

      # SimpleCov's after_run hook exits 1 when `$!` holds an exception, so a
      # reconnected runner must not finish inside the rescue of the lost one.
      it "finishes the reconnected run with no pending exception" do
        seen = :not_called
        allow(runner).to receive(:finish) { seen = $! }

        lose_connection_once(controller)

        expect(seen).to be_nil
        expect(controller).to have_received(:exit).with(1) # the double's exit_status
      end

      it "gives up after too many retries" do
        allow(Selective::Ruby::Core::NamedPipe).to receive(:new).and_raise(Selective::Ruby::Core::ConnectionLostError)
        allow(controller).to receive(:pipe).and_return(pipe)
        allow(controller).to receive(:puts_indented)
        allow(controller).to receive(:exit).with(1).and_raise(SystemExit.new(1))

        expect { controller.start }.to raise_error(SystemExit)
        expect(controller.retries).to eq(11)
      end
    end

    context "when an error occurs" do
      before do
        allow(controller).to receive(:puts_indented)
        allow(Selective::Ruby::Core::NamedPipe).to receive(:new).and_raise(StandardError.new("error"))
      end

      it "exits and prints a message about the error" do
        controller.start
        expect(controller).to have_received(:exit).with(1)
        expect(controller).to have_received(:puts_indented).with(/error/)
      end
    end
  end

  describe "#validate_build_env" do
    before do
      allow(controller).to receive(:puts_indented)
    end

    it 'raises an error when required configuration is missing' do
      controller.validate_build_env({})
      expect(controller).to have_received(:puts_indented).with(/Missing required environment variables: SELECTIVE_HOST/)
    end
  end

  describe "exec" do
    context "when an error occurs" do
      before do
        allow(controller).to receive(:puts_indented)
        expect(runner).to receive(:exec).and_raise(StandardError.new("error"))
      end

      it "prints an error message and exits" do
        controller.exec
        expect(controller).to have_received(:exit).with(1)
        expect(controller).to have_received(:puts_indented).with(/error/)
      end
    end
  end

  def send_commands(controller, commands)
    allow(Selective::Ruby::Core::NamedPipe).to receive(:new).and_call_original
    allow(Selective::Ruby::Core::NamedPipe).to receive(:new).with("/tmp/#{controller.runner_id}_2", "/tmp/#{controller.runner_id}_1").and_return(pipe)

    allow(controller).to receive(:run_main_loop).and_wrap_original do |original_method, *args, &block|
      # Sleep here because of threads in NamedPipe
      sleep(0.1)
      (commands | [{command: "close"}]).each { |command| reverse_pipe.write(command.to_json) }
      original_method.call(*args, &block)
    end

    controller.start
  end
end
