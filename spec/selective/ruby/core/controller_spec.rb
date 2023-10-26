# frozen_string_literal: true

RSpec.describe Selective::Ruby::Core::Controller do
  let(:runner) { double("runner", finish: nil, exit_status: 1) }
  let(:controller) { dirty_dirty_unprivate_class(described_class).new(runner) }

  let!(:pipe) { Selective::Ruby::Core::NamedPipe.new("/tmp/#{controller.runner_id}_test_2", "/tmp/#{controller.runner_id}_test_1", skip_reset: true) }
  let!(:reverse_pipe) { Selective::Ruby::Core::NamedPipe.new("/tmp/#{controller.runner_id}_test_1", "/tmp/#{controller.runner_id}_test_2", skip_reset: true) }

  before do
    allow(Process).to receive(:spawn).and_return(123)
    allow(controller).to receive(:handle_termination_signals)
    allow(controller).to receive(:exit)
  end

  describe "#start" do
    before do
      allow(controller).to receive(:print_init)
      allow(described_class).to receive(:restore_reporting!)
    end

    it "processes commands" do
      send_commands(controller, [
        {command: "init", runner_id: controller.runner_id}
      ])

      expect(controller).to have_received(:print_init).once.with(controller.runner_id)
      expect(runner).to have_received(:finish).once
    end

    it "handles the remove_failed_test_case_result command" do
      test_case_id = "spec/abc/123_spec.rb"
      allow(runner).to receive(:remove_failed_test_case_result)

      send_commands(controller, [
        {command: "remove_failed_test_case_result", test_case_id: test_case_id}
      ])

      expect(runner).to have_received(:remove_failed_test_case_result).once.with(test_case_id)
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

    context "when a NamedPipe::PipeClosedError occurs" do
      before do
        allow(Selective::Ruby::Core::NamedPipe).to receive(:new).and_raise(Selective::Ruby::Core::NamedPipe::PipeClosedError)

        # The retry method calls start again, so we have to do some fancy mocking
        # to ensure we do not end up in an endless loop. Normally the process would
        # exit when the retires are exausted, but we're mocking exit above because
        # we don't want to actually exit the test process.
        allow(controller).to receive(:start).and_wrap_original do |original_method, *args, &block|
          allow(controller).to receive(:start)
          original_method.call(*args, &block)
        end

        allow(controller).to receive(:puts)
        expect(controller).to receive(:sleep)
        expect(controller).to receive(:kill_transport)
        expect(controller).to receive_message_chain(:pipe, :reset!)
      end

      it "increments the retries counter" do
        expect { controller.start }.to change { controller.retries }.by(1)
        expect(controller).to have_received(:puts).with("Retrying in 1 seconds...")
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
