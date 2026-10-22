# frozen_string_literal: true

require "json"
require "timeout"

require_relative "../../../support/minimal_websocket_server"

RSpec.describe "transport --stdio binary" do
  let(:binary) { ENV.fetch("SELECTIVE_TRANSPORT_BIN", "/tmp/transport/target/release/transport") }
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
    skip "transport binary with --stdio is not built at #{binary}" unless usable_binary?
  end

  def usable_binary?
    File.executable?(binary) && `#{binary} --help 2>&1`.include?("--stdio")
  end

  def fifos
    Dir["/tmp/*"].select { |path|
      File.ftype(path) == "fifo"
    }
  rescue Errno::ENOENT
    []
  end

  it "connects with the url only in the environment and exits 1 when the port refuses" do
    session = Selective::Ruby::Core::StdioTransport.open(
      binary,
      "ws://127.0.0.1:1/transport/websocket?api_key=test-api-key"
    )
    cmdline = File.read("/proc/#{session.pid}/cmdline").split("\0")

    expect(cmdline).to eq([binary, "--stdio"])
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

    before_fifos = fifos
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
      captured[:cmdline] ||= File.read("/proc/#{controller.transport_pid}/cmdline").split("\0")
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
    previous_transport = ENV["SELECTIVE_TRANSPORT"]
    previous_fifo = ENV["SELECTIVE_TRANSPORT_FIFO"]
    ENV["SELECTIVE_TRANSPORT"] = binary
    ENV.delete("SELECTIVE_TRANSPORT_FIFO")

    Timeout.timeout(8) { controller.start }
    driver.join(2)

    received = []
    received << frames.pop(true) until frames.empty?
    ids = received.filter_map { |message| message.dig("data", "id") if message["type"] == "test_case_result" }

    expect(ran).to eq([["a", "b"], ["c"]])
    expect(ids).to eq(%w[a b c])
    expect(received.map { |message| message["type"] }).to include("report_at_finish")
    expect(statuses).to eq([0])
    expect(fifos - before_fifos).to eq([])
    expect(captured[:cmdline]).to eq([binary, "--stdio"])
    expect(File.exist?("/tmp/stdio-runner_1")).to be(false)
    expect(File.exist?("/tmp/stdio-runner_2")).to be(false)
    pid = controller.transport_pid
    expect { Process.getpgid(pid) }.to raise_error(Errno::ESRCH)
  ensure
    ENV["SELECTIVE_TRANSPORT"] = previous_transport if defined?(previous_transport) && previous_transport
    ENV.delete("SELECTIVE_TRANSPORT") if defined?(previous_transport) && previous_transport.nil?
    if defined?(previous_fifo) && previous_fifo
      ENV["SELECTIVE_TRANSPORT_FIFO"] = previous_fifo
    elsif defined?(previous_fifo)
      ENV.delete("SELECTIVE_TRANSPORT_FIFO")
    end
    server&.close
    driver&.kill
  end
end
