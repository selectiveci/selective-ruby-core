# frozen_string_literal: true

require "fileutils"
require "json"
require "timeout"
require "tmpdir"

RSpec.describe "stdio controller" do
  let(:fake_transport) { File.expand_path("../../../support/fake_stdio_transport.rb", __dir__) }
  let(:fake_fifo_transport) { File.expand_path("../../../support/fake_fifo_transport.rb", __dir__) }
  let(:directory) { Dir.mktmpdir("selective-stdio-controller") }
  let(:build_env) do
    {
      "host" => "ws://example.test",
      "api_key" => "test-api-key",
      "platform" => "github_actions",
      "run_id" => "1",
      "run_attempt" => "1",
      "runner_id" => "stdio-runner",
      "branch" => "main",
      "sha" => "abc123",
      "git_repo_full_name" => "selectiveci/selective-ruby-core",
      "git_provider" => "github"
    }
  end
  let(:batches) { [] }
  let(:events) { [] }
  let(:batch_state) { {in_batch: false} }
  let(:runner) do
    double(
      "runner",
      finish: nil,
      exit_status: 0,
      framework: "rspec",
      framework_version: "3.13.0",
      wrapper_version: "0.1.6",
      base_test_path: "spec",
      manifest: {
        "examples" => [
          {"id" => "a", "file_path" => "spec/a_spec.rb", "run_time" => 0.0}
        ]
      }
    )
  end
  let(:runner_class) { class_double("runner_class", new: runner) }
  let(:controller) do
    dirty_dirty_unprivate_class(Selective::Ruby::Core::Controller).new(runner_class, nil).tap do |controller|
      allow(controller).to receive(:build_env).and_return(build_env)
      allow(controller).to receive(:sleep)
    end
  end

  around do |example|
    threads = Thread.list
    with_env(
      "SELECTIVE_TRANSPORT" => fake_transport,
      "SELECTIVE_TRANSPORT_FIFO" => nil,
      "SELECTIVE_FAKE_MODE" => ENV["SELECTIVE_FAKE_MODE"],
      "SELECTIVE_FAKE_DIR" => directory
    ) { example.run }
  ensure
    (Thread.list - threads).each(&:kill)
    FileUtils.rm_rf(directory) if directory
  end

  before do
    File.chmod(0o755, fake_transport)
    allow(controller).to receive(:handle_termination_signals)
    allow(Selective::Ruby::Core::Controller).to receive(:restore_reporting!)
    allow(runner).to receive(:run_test_cases) do |ids|
      expect(File.exist?("/tmp/#{build_env["runner_id"]}_1")).to be(false)
      expect(File.exist?("/tmp/#{build_env["runner_id"]}_2")).to be(false)
      batch_state[:in_batch] = true
      events << [:run, ids.dup]
      batches << ids.dup
      ids.each do |id|
        controller.test_case_callback({id: id, status: (id == "bad") ? "failed" : "passed"})
        sleep 0.25 if %w[a bad].include?(id)
      end
      batch_state[:in_batch] = false
    end
    allow(runner).to receive(:remove_test_case_result) do |id|
      raise "remove applied during a batch" if batch_state[:in_batch]

      events << [:remove, id]
    end
    allow(controller).to receive(:puts_indented)
  end

  def reports
    Dir[File.join(directory, "*.json")].map { |path| JSON.parse(File.read(path)) }
  end

  def client_messages
    reports.flat_map { |report| report["stdin"] }.filter_map { |line| parse_line(line) }
  end

  def parse_line(line)
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end

  def result_ids
    client_messages.filter_map { |message|
      message.dig("data", "id") if message["type"] == "test_case_result"
    }
  end

  it "runs batches over stdio without creating fifos or putting the key on argv" do
    with_env("SELECTIVE_FAKE_MODE" => "topup") do
      statuses = []
      allow(controller).to receive(:exit) { |code| statuses << code }

      Timeout.timeout(5) { controller.start }

      expect(batches).to eq([["a", "b"], ["c"]])
      expect(result_ids).to eq(%w[a b c])
      expect(statuses).to eq([0])
      expect(reports.map { |report| report["argv"] }.uniq).to eq([["--stdio"]])
      expect(reports.map { |report| report["url"] }.join).to include("api_key=test-api-key")
      reports.each do |report|
        expect(report["stdin"]).to include("exit")
      end
      reports.each do |report|
        expect { Process.getpgid(report["pid"]) }.to raise_error(Errno::ESRCH)
      end
    end
  end

  it "applies a remove that arrives during a batch only after the batch returns" do
    with_env("SELECTIVE_FAKE_MODE" => "remove_during") do
      allow(controller).to receive(:exit)

      Timeout.timeout(5) { controller.start }

      expect(events).to eq([
        [:run, ["bad"]],
        [:remove, "bad"],
        [:run, ["bad"]]
      ])
    end
  end

  it "holds a command that arrives before connected and then answers the manifest" do
    with_env("SELECTIVE_FAKE_MODE" => "before_connected") do
      allow(runner).to receive(:run_test_cases)
      allow(controller).to receive(:exit)

      Timeout.timeout(5) { controller.start }

      manifest = client_messages.find { |message| message["type"] == "test_manifest" }
      expect(manifest.dig("data", "test_cases", 0, "id")).to eq("a")
      expect(reports.first["early_write"]).to be_nil
      expect(reports.first["manifest_missing"]).to be_nil
    end
  end

  it "exits 1 from the first attempt's watchdog when no attempt has connected in time" do
    stub_const("Selective::Ruby::Core::Controller::CONNECT_TIMEOUT", 0.4)
    allow(controller).to receive(:sleep).and_call_original
    allow(controller).to receive(:puts)
    with_env("SELECTIVE_FAKE_MODE" => "retry_after_drop") do
      allow(controller).to receive(:exit).with(1).and_raise(SystemExit.new(1))

      expect { Timeout.timeout(3) { controller.start } }.to raise_error(SystemExit)
      expect(controller).to have_received(:puts).with("Transport process failed to start. Exiting...")
      expect(controller.retries).to eq(1)
    end
  end

  it "reconnects after the child dies and reports the retry" do
    with_env("SELECTIVE_FAKE_MODE" => "die_after_connected") do
      statuses = []
      allow(controller).to receive(:exit) { |code| statuses << code }

      Timeout.timeout(5) { controller.start }

      expect(controller.retries).to eq(1)
      expect(statuses).to eq([0])
      expect(reports.size).to eq(2)
      expect(reports.map { |report| report["count"] }).to contain_exactly(1, 2)
    end
  end

  it "opens the next session with reconnect=true when the server asks" do
    with_env("SELECTIVE_FAKE_MODE" => "reconnect") do
      allow(controller).to receive(:exit) { |code| raise SystemExit.new(code) }

      expect { Timeout.timeout(5) { controller.start } }.to raise_error(SystemExit) { |error|
        expect(error.status).to eq(0)
      }

      urls = reports.map { |report| report["url"] }
      expect(urls.grep(/reconnect=true/).size).to eq(1)
      expect(urls.grep_v(/reconnect/).size).to eq(1)
      expect(runner).to have_received(:finish).once
    end
  end

  it "exits 1 after the eleventh refused connect and reaps every child" do
    with_env("SELECTIVE_FAKE_MODE" => "refuse") do
      allow(controller).to receive(:exit).with(1).and_raise(SystemExit.new(1))

      expect { Timeout.timeout(30) { controller.start } }.to raise_error(SystemExit)
      expect(controller.retries).to eq(11)
      expect(reports.size).to eq(11)
      reports.each do |report|
        expect { Timeout.timeout(5) { loop { Process.getpgid(report["pid"]) && sleep(0.05) } } }.to raise_error(Errno::ESRCH)
      end
    end
  end

  it "parses stdout when the transport writes logs to stderr" do
    with_env("SELECTIVE_FAKE_MODE" => "stderr") do
      allow(controller).to receive(:exit)

      Timeout.timeout(5) { controller.start }

      expect(runner).to have_received(:finish).once
    end
  end

  it "falls back to the FIFO sidecar with one warning when the binary predates stdio" do
    File.chmod(0o755, fake_fifo_transport)
    with_env("SELECTIVE_TRANSPORT" => fake_fifo_transport) do
      statuses = []
      allow(controller).to receive(:exit) { |code| statuses << code }

      Timeout.timeout(10) { controller.start }

      spawns = Dir[File.join(directory, "fifo-*.json")].sort.map { |path| JSON.parse(File.read(path))["argv"] }
      expect(spawns.size).to eq(2)
      expect(spawns.map(&:last).uniq).to eq(["stdio-runner"])
      expect(spawns.first.first).to include("api_key=test-api-key")
      expect(controller.retries).to eq(1)
      expect(statuses).to eq([0])
      expect(controller).to have_received(:puts_indented).with(/fake_fifo_transport.rb does not support --stdio/).once
    end
  end

  it "shows the binary's own error, without FIFO advice, when it cannot run" do
    path = File.join(directory, "unloadable-transport")
    File.write(path, "#!/bin/sh\nprintf '\\377\\n' >&2\necho \"$0: version \\`GLIBC_2.34' not found\" >&2\nexit 1\n")
    File.chmod(0o755, path)
    with_env("SELECTIVE_TRANSPORT" => path) do
      allow(controller).to receive(:exit).with(1).and_raise(SystemExit.new(1))

      expect { controller.start }.to raise_error(SystemExit)
      expect(controller).to have_received(:puts_indented).with(/unloadable-transport could not be run:\n.*GLIBC_2\.34' not found/m)
      expect(controller).not_to have_received(:puts_indented).with(/FIFO/)
      expect(reports).to be_empty
    end
  end
end
