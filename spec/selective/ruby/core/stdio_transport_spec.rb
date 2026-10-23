# frozen_string_literal: true

require "fileutils"
require "json"
require "timeout"
require "tmpdir"

RSpec.describe Selective::Ruby::Core::StdioTransport do
  let(:fake_transport) { File.expand_path("../../../support/fake_stdio_transport.rb", __dir__) }
  let(:directory) { Dir.mktmpdir("selective-stdio") }

  before do
    File.chmod(0o755, fake_transport)
  end

  around do |example|
    with_env("SELECTIVE_FAKE_MODE" => nil, "SELECTIVE_FAKE_DIR" => directory) { example.run }
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  def reports
    Dir[File.join(directory, "*.json")].map { |path| JSON.parse(File.read(path)) }
  end

  describe "framing" do
    it "reads server lines, writes client lines, and reaps the child on exit" do
      ENV["SELECTIVE_FAKE_MODE"] = "close"
      session = described_class.open(fake_transport, "ws://example.test/transport/websocket?api_key=sekret")

      expect(JSON.parse(session.read)).to eq("command" => "connected")
      report = reports.first
      expect(report["argv"]).to eq(["--stdio"])
      expect(report["url"]).to include("api_key=sekret")

      session.write(JSON.dump({type: "test_case_result", data: {id: "a"}}))
      expect(JSON.parse(session.read)).to include("command" => "close")
      Timeout.timeout(3) { session.delete_pipes }

      expect(session.wait_thread.value.exitstatus).to eq(0)
      expect(reports.first["stdin"]).to include(JSON.dump({type: "test_case_result", data: {id: "a"}}))
    end

    it "keeps the transport log out of the command stream and on the parent's stderr" do
      ENV["SELECTIVE_FAKE_MODE"] = "stderr"
      session = described_class.open(fake_transport, "ws://example.test/socket?api_key=sekret")

      command = JSON.parse(session.read)
      expect(command["command"]).to eq("connected")
      expect(command.to_s).not_to include("not-json")
      if File.exist?("/proc/self/fd/2")
        expect(File.readlink("/proc/#{session.pid}/fd/2")).to eq(File.readlink("/proc/self/fd/2"))
      end
      Timeout.timeout(3) { session.delete_pipes }
    end

    it "does not deadlock when the child fills stdout before reading stdin" do
      ENV["SELECTIVE_FAKE_MODE"] = "flood"
      result = JSON.dump({type: "test_case_result", data: {id: "a"}})
      session = described_class.open(fake_transport, "ws://example.test/socket?api_key=sekret")

      Timeout.timeout(5) do
        expect(JSON.parse(session.read)["command"]).to eq("print_notice")
        session.write(result)
        session.delete_pipes
      end

      expect(session.wait_thread.value.exitstatus).to eq(0)
      expect(reports.first["stdin"]).to include(result)
    end

    it "raises when the child exits and does not leave a zombie" do
      ENV["SELECTIVE_FAKE_MODE"] = "die_after_connected"
      session = described_class.open(fake_transport, "ws://example.test/socket?api_key=sekret")
      pid = session.pid

      expect(JSON.parse(session.read)["command"]).to eq("connected")
      Timeout.timeout(2) do
        expect { session.read }.to raise_error(Selective::Ruby::Core::ConnectionLostError)
      end
      Timeout.timeout(2) { session.delete_pipes }

      expect { Process.getpgid(pid) }.to raise_error(Errno::ESRCH)
    end

    it "terminates a child that ignores exit instead of hanging" do
      ENV["SELECTIVE_FAKE_MODE"] = "ignore_exit"
      session = described_class.open(fake_transport, "ws://example.test/socket?api_key=sekret")

      Timeout.timeout(3) { session.delete_pipes }

      expect(session.wait_thread).not_to be_alive
    end

    it "returns from shutdown when the child never reads a full stdin" do
      script = File.join(directory, "deaf")
      File.write(script, "#!/usr/bin/env ruby\nsleep 30\n")
      File.chmod(0o755, script)
      session = described_class.open(script, "ws://example.test/socket")
      pid = session.pid
      io = session.instance_variable_get(:@stdin)
      chunk = "x" * 65_536
      8.times do
        break if io.write_nonblock(chunk, exception: false) == :wait_writable
      end

      Timeout.timeout(3) { session.shutdown }
    ensure
      begin
        Process.kill("KILL", pid) if pid
      rescue Errno::ESRCH
        nil
      end
    end

    it "sends a frame written from a signal handler after the write it interrupted" do
      ENV["SELECTIVE_FAKE_MODE"] = "slow_reader"
      session = described_class.open(fake_transport, "ws://example.test/socket")
      big = JSON.dump({type: "test_case_result", data: {pad: "x" * 1_000_000}})
      terminating = JSON.dump({type: "terminating", data: {signal: "USR1"}})
      previous = Signal.trap("USR1") { session.write(terminating) }
      Thread.new do
        sleep 0.1
        Process.kill("USR1", Process.pid)
      end

      session.write(big)
      sleep 0.5
      Timeout.timeout(5) { session.delete_pipes }

      expect(reports.first["stdin"]).to eq([big, terminating])
    ensure
      Signal.trap("USR1", previous || "DEFAULT")
    end

    it "raises ConnectionLostError when writing after the child is gone" do
      ENV["SELECTIVE_FAKE_MODE"] = "die_after_connected"
      session = described_class.open(fake_transport, "ws://example.test/socket?api_key=sekret")
      session.read
      session.wait_thread.join

      expect { session.write("{}") }.to raise_error(Selective::Ruby::Core::ConnectionLostError)
      session.delete_pipes
    end
  end
end
