# frozen_string_literal: true

# Outbound messages are serialised with JSON.dump. A test whose failure message
# contains bytes that are not valid UTF-8 — a binary fixture, a protocol frame,
# a truncated multibyte sequence — makes that raise, and the exception unwinds
# through run_main_loop and kills the entire runner process.
#
# Reproduced against the dev stack: one test asserting on binary data took down
# a 31-case run with zero results recorded and no completion at all.
RSpec.describe Selective::Ruby::Core::Controller do
  let(:runner_class) { class_double("runner_class", new: runner) }
  let(:runner) do
    double("runner", finish: nil, exit_status: 1, framework: "rspec",
                     framework_version: "1.0", wrapper_version: "1.0")
  end
  let(:controller) { dirty_dirty_unprivate_class(described_class).new(runner_class, nil) }

  let(:written) { [] }

  # The controller resolves its build env (and aborts the process if required
  # variables are missing) while deriving a runner id, so provide them here
  # rather than depending on whatever the surrounding shell exports.
  REQUIRED_ENV = {
    "SELECTIVE_RUN_ID" => "spec-run",
    "SELECTIVE_RUN_ATTEMPT" => "1",
    "SELECTIVE_SHA" => "0" * 40,
    "SELECTIVE_HOST" => "ws://localhost:4000",
    "SELECTIVE_API_KEY" => "spec-key"
  }.freeze

  around do |example|
    previous = REQUIRED_ENV.keys.to_h { |k| [k, ENV[k]] }
    REQUIRED_ENV.each { |k, v| ENV[k] = v }
    example.run
    previous.each { |k, v| ENV[k] = v }
  end

  before do
    allow(controller).to receive(:exit)
    allow(controller).to receive(:pipe).and_return(double("pipe", write: nil).tap do |p|
      allow(p).to receive(:write) { |payload| written << payload }
    end)
  end

  def round_trip(data)
    controller.write(data)
    JSON.parse(written.last)
  end

  describe "#write" do
    it "serialises an ordinary payload unchanged" do
      parsed = round_trip({type: "test_case_result", data: {"id" => "a", "status" => "passed"}})

      expect(parsed["data"]["status"]).to eq("passed")
    end

    it "does not raise on invalid UTF-8 in a failure message" do
      blob = [0xFF, 0xFE, 0x80, 0x41].pack("C*")

      expect {
        controller.write({type: "test_case_result",
                          data: {"failure_message_lines" => [blob]}})
      }.not_to raise_error
    end

    it "does not raise on binary-encoded strings" do
      expect {
        controller.write({type: "test_case_result",
                          data: {"description" => "bytes: \x80\x81".b}})
      }.not_to raise_error
    end

    it "produces output that parses back as JSON" do
      blob = [0xFF, 0xFE, 0x80, 0x41].pack("C*")
      parsed = round_trip({type: "test_case_result", data: {"m" => [blob]}})

      expect(parsed["data"]["m"].first).to be_a(String)
      expect(parsed["data"]["m"].first).to be_valid_encoding
    end

    it "scrubs invalid bytes at any depth" do
      parsed = round_trip({
        type: "test_case_result",
        data: {"nested" => {"deep" => ["ok", "bad \xC3".b]}}
      })

      expect(parsed["data"]["nested"]["deep"].last).to be_valid_encoding
    end

    it "preserves valid multibyte characters exactly" do
      parsed = round_trip({type: "x", data: {"d" => "héllo → 🔥"}})

      expect(parsed["data"]["d"]).to eq("héllo → 🔥")
    end

    it "keeps newlines and tabs, which carry meaning in failure output" do
      parsed = round_trip({type: "x", data: {"d" => "expected:\n\tfoo"}})

      expect(parsed["data"]["d"]).to eq("expected:\n\tfoo")
    end

    it "neutralises NUL bytes rather than emitting them" do
      # Postgres rejects a NUL anywhere in a jsonb value (22P05), so it must
      # not reach the server as a raw byte.
      parsed = round_trip({type: "x", data: {"d" => "bad\u0000data"}})

      expect(parsed["data"]["d"]).not_to include("\u0000")
      expect(parsed["data"]["d"]).to include("bad")
      expect(parsed["data"]["d"]).to include("data")
    end
  end
end
