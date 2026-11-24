# frozen_string_literal: true

RSpec.describe Selective::Ruby::Core::Timings do
  subject(:timings) { described_class.new(loaded_at_ms: 1_000) }

  it "keeps the first time a mark is reached" do
    timings.mark("connected")
    first = timings.marks["connected_at"]
    sleep 0.002
    timings.mark("connected")
    expect(timings.marks["connected_at"]).to eq(first)
  end

  it "returns the measured block's value" do
    expect(timings.measure("manifest_list") { :listed }).to eq(:listed)
    expect(timings.marks["manifest_list_ms"]).to be >= 0
  end

  it "counts waiting before the first batch as startup and after it as idle" do
    timings.waited(30)
    timings.batch {}
    timings.waited(5)
    timings.waited(7)

    expect(timings.finish).to include("wait_before_first_batch_ms" => 30, "idle_between_batches_ms" => 12, "batches" => 1)
  end

  it "separates time inside examples from the rest of a batch" do
    allow(described_class).to receive(:monotonic_ms).and_return(0, 1_000)
    timings.batch { timings.example(0.4) }

    expect(timings.finish).to include("run_ms" => 1_000, "example_ms" => 400, "outside_examples_ms" => 600)
  end

  it "finds when the process started on Linux" do
    skip "needs /proc" unless File.exist?("/proc/self/stat")

    expect(described_class.process_started_at_ms).to be_within(120_000).of(described_class.now_ms)
  end
end
