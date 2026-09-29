# frozen_string_literal: true

require "tmpdir"
require "erb"
require "fileutils"

RSpec.describe Selective::Ruby::Core::TestMap::Tracer do
  before(:all) do
    skip "native tracer not compiled (run `rake compile`)" unless Selective::Ruby::Core::TestMap.available?

    @root = File.realpath(Dir.mktmpdir("selective-tracer"))
    files = {
      "app/helper.rb" => "module TracerSpecApp; def self.helper = :helped; end",
      "app/caller.rb" => "module TracerSpecApp; def self.call_helper = helper; end",
      "app/untouched.rb" => "module TracerSpecApp; def self.untouched = :no; end",
      # A class body with no methods: its lines run once, at load. Only
      # allocation tracking can tie a test to this file.
      "app/models/codeless.rb" => "class TracerSpecCodeless < Struct.new(:a); end",
      "app/models/base.rb" => "class TracerSpecBase; def base = 1; end",
      "app/models/child.rb" => "class TracerSpecChild < TracerSpecBase; end",
      "app/threaded.rb" => "module TracerSpecApp; def self.in_thread = :threaded; end",
      "vendor/bundle/gem.rb" => "module TracerSpecGem; def self.work = TracerSpecApp.helper; end",
      "app/views/page.html.erb" => "<%= 1 + 1 %>\n"
    }
    files.each do |path, source|
      full = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, source)
      require full unless path.end_with?(".erb")
    end
  end

  after(:all) { FileUtils.rm_rf(@root) if @root }

  def tracer(allocations: true)
    described_class.new(allocations: allocations, repo_root: @root, pwd: @root).tap do |t|
      # vendor/bundle stands in for gems installed inside the project.
      t.instance_variable_get(:@ignored) << File.join(@root, "vendor/bundle")
      t.instance_variable_set(:@native, Selective::Ruby::Core::TestMap::NativeTracer.new(
        roots: [@root], ignored: [File.join(@root, "vendor/bundle")], allocations: allocations
      ))
    end
  end

  it "records every project file a block executes, repo-relative" do
    _, files = tracer.trace { TracerSpecApp.call_helper }
    expect(files).to include("app/caller.rb", "app/helper.rb")
    expect(files).not_to include("app/untouched.rb")
  end

  it "returns the block's result" do
    result, _ = tracer.trace { TracerSpecApp.helper }
    expect(result).to eq(:helped)
  end

  it "attributes work done on other threads to the running test" do
    _, files = tracer.trace { Thread.new { TracerSpecApp.in_thread }.join }
    expect(files).to include("app/threaded.rb")
  end

  it "ties a test to a code-less class it instantiates, and to its project ancestors" do
    _, files = tracer.trace do
      TracerSpecCodeless.new(1)
      TracerSpecChild.new
    end
    expect(files).to include("app/models/codeless.rb", "app/models/child.rb", "app/models/base.rb")
  end

  it "misses code-less classes when allocation tracking is off" do
    _, files = tracer(allocations: false).trace { TracerSpecCodeless.new(1) }
    expect(files).not_to include("app/models/codeless.rb")
  end

  it "ignores files under ignored prefixes but still sees project code they call" do
    _, files = tracer.trace { TracerSpecGem.work }
    expect(files).to include("app/helper.rb")
    expect(files.grep(/vendor/)).to be_empty
  end

  it "records templates compiled with a filename (how ActionView compiles ERB)" do
    path = File.join(@root, "app/views/page.html.erb")
    _, files = tracer.trace do
      erb = ERB.new(File.read(path))
      erb.filename = path
      erb.result(binding)
    end
    expect(files).to include("app/views/page.html.erb")
  end

  it "starts each test with a clean slate" do
    t = tracer
    t.trace { TracerSpecApp.call_helper }
    _, files = t.trace { TracerSpecApp.untouched }
    expect(files).to include("app/untouched.rb")
    expect(files).not_to include("app/caller.rb")
  end

  it "stops tracing even when the test raises" do
    t = tracer
    expect { t.trace { raise "boom" } }.to raise_error("boom")
    native = t.instance_variable_get(:@native)
    expect(native.running?).to be(false)
  end

  it "survives GC compaction and heavy allocation while tracing" do
    t = tracer
    _, files = t.trace do
      GC.compact if GC.respond_to?(:compact)
      20_000.times { TracerSpecCodeless.new(1) }
      GC.start
      TracerSpecApp.call_helper
    end
    expect(files).to include("app/helper.rb", "app/models/codeless.rb")
  end
end
