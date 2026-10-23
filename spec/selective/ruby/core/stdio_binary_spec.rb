# frozen_string_literal: true

require "json"
require "timeout"

require_relative "../../../support/minimal_websocket_server"

RSpec.describe "transport --stdio binary" do
  let(:binary) { ENV["SELECTIVE_TRANSPORT"] || File.expand_path("../../../../lib/bin/transport", __dir__) }
  let(:build_env_base) do
    {
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

  before do
    next if usable_binary?

    message = "transport binary with --stdio is not available (looked at #{binary.inspect}). Set SELECTIVE_TRANSPORT."
    raise message if ENV["CI"]

    skip message
  end

  def usable_binary?
    File.executable?(binary) && `#{binary} --help 2>&1`.include?("--stdio")
  end

  def command_line(pid)
    path = "/proc/#{pid}/cmdline"
    return unless File.exist?(path)

    File.read(path).split("\0")
  end

  it "connects with the url only in the environment and exits 1 when the port refuses" do
    session = Selective::Ruby::Core::StdioTransport.open(
      binary,
      "ws://127.0.0.1:1/transport/websocket?api_key=test-api-key"
    )
    cmdline = command_line(session.pid)

    expect(cmdline).to eq([binary, "--stdio"]) if cmdline
    Timeout.timeout(3) do
      expect { session.read }.to raise_error(Selective::Ruby::Core::ConnectionLostError)
    end
    expect(session.wait_thread.value.exitstatus).to eq(1)
    session.delete_pipes
  end

  it "round-trips a batch, a mid-batch top-up, and close without fifos" do
    server = MinimalWebSocketServer.new
    frames = Queue.new
    driver = Thread.new do
      client = server.accept_and_handshake
      server.send_text(client, JSON.dump({command: "connected"}))
      server.send_text(client, JSON.dump({command: "run_test_cases", test_case_ids: ["a", "b"]}))
      results = 0
      topped_up = false
      loop do
        message = server.read_json(client)
        break if message.nil?

        frames << message
        if message["type"] == "test_case_result"
          results += 1
          if !topped_up && message.dig("data", "id") == "a"
            server.send_text(client, JSON.dump({command: "run_test_cases", test_case_ids: ["c"]}))
            topped_up = true
          end
          if results == 3
            server.send_text(client, JSON.dump({command: "close", exit_status: nil}))
          end
        end
        break if message["type"] == "report_at_finish"
      end
    rescue => error
      frames << {"driver_error" => "#{error.class}: #{error.message}"}
    end

    runner = double(
      "runner",
      finish: nil,
      exit_status: 0,
      framework: "rspec",
      framework_version: "3.13.0",
      wrapper_version: "0.1.6",
      base_test_path: "spec",
      manifest: {"examples" => []}
    )
    ran = []
    captured = {}
    runner_class = class_double("runner_class", new: runner)
    controller = dirty_dirty_unprivate_class(Selective::Ruby::Core::Controller).new(runner_class, nil)
    allow(runner).to receive(:run_test_cases) do |ids|
      captured[:cmdline] ||= command_line(controller.transport_pid)
      expect(File.exist?("/tmp/stdio-runner_1")).to be(false)
      expect(File.exist?("/tmp/stdio-runner_2")).to be(false)
      ran << ids.dup
      ids.each do |id|
        controller.test_case_callback({id: id, status: "passed"})
        sleep 0.2 if id == "a"
      end
    end
    allow(controller).to receive(:build_env).and_return(build_env_base.merge("host" => "ws://127.0.0.1:#{server.port}"))
    allow(controller).to receive(:sleep)
    statuses = []
    allow(controller).to receive(:exit) { |code| statuses << code }

    with_env("SELECTIVE_TRANSPORT" => binary, "SELECTIVE_TRANSPORT_FIFO" => nil) do
      Timeout.timeout(8) { controller.start }
    end
    driver.join(2)

    received = []
    received << frames.pop(true) until frames.empty?
    ids = received.filter_map { |message| message.dig("data", "id") if message["type"] == "test_case_result" }

    expect(ran).to eq([["a", "b"], ["c"]])
    expect(ids).to eq(%w[a b c])
    expect(received.map { |message| message["type"] }).to include("report_at_finish")
    expect(statuses).to eq([0])
    expect(captured[:cmdline]).to eq([binary, "--stdio"]) if captured[:cmdline]
    pid = controller.transport_pid
    expect { Process.getpgid(pid) }.to raise_error(Errno::ESRCH)
  ensure
    server&.close
    driver&.kill
  end
end
