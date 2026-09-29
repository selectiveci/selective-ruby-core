# frozen_string_literal: true

require "socket"
require "zlib"
require "json"

RSpec.describe Selective::Ruby::Core::TestMap::Uploader do
  # A tiny HTTP server: records the last request, answers each with `status`.
  def serve(status, requests: 1)
    server = TCPServer.new("127.0.0.1", 0)
    received = {}
    thread = Thread.new do
      requests.times do
        client = server.accept
        request_line = client.gets
        headers = {}
        while (line = client.gets) && line != "\r\n"
          key, value = line.split(":", 2)
          headers[key.downcase] = value.strip
        end
        body = client.read(headers["content-length"].to_i)
        received.merge!(request_line: request_line, headers: headers, body: body)
        client.write("HTTP/1.1 #{status} X\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        client.close
      end
    end
    [server.addr[1], received, thread, server]
  end

  let(:fragment) { {"version" => 1, "files" => ["app/a.rb"], "tests" => [{"id" => "t1", "deps" => [0]}]} }

  def uploader(port)
    described_class.new(host: "ws://127.0.0.1:#{port}", api_key: "key-123", run_id: "r1", run_attempt: "1",
      runner_id: "0")
  end

  it "posts the gzipped fragment with the api key" do
    port, received, thread, server = serve(200)
    expect(uploader(port).upload(fragment)).to be(true)
    thread.join(5)

    expect(received[:request_line]).to start_with("POST /test_maps/fragments?run_id=r1&run_attempt=1&runner_id=0")
    expect(received[:headers]["authorization"]).to eq("key-123")
    expect(JSON.parse(Zlib.gunzip(received[:body]))).to eq(fragment)
  ensure
    server&.close
  end

  it "succeeds even when the test process blocks Net::HTTP (as WebMock and VCR do)" do
    port, _received, thread, server = serve(200)
    blocker = Module.new do
      def request(*)
        raise "Real HTTP connections are disabled"
      end
    end
    Net::HTTP.prepend(blocker)

    expect(uploader(port).upload(fragment)).to be(true)
    thread.join(5)
  ensure
    blocker&.instance_methods&.each { |m| blocker.send(:remove_method, m) }
    server&.close
  end

  it "reports a rejected upload without raising" do
    port, _received, _thread, server = serve(422, requests: described_class::ATTEMPTS)
    up = uploader(port)
    allow(up).to receive(:sleep)

    expect(up.upload(fragment)).to be(false)
    expect(up.last_error.message).to include("HTTP 422")
  ensure
    server&.close
  end
end
