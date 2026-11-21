require "tmpdir"
require "rbconfig"

RSpec.describe Selective::Ruby::Core::Workers do
  worker_vars = %w[
    SELECTIVE_WORKERS SELECTIVE_WORKER_INDEX SELECTIVE_WORKER_COUNT SELECTIVE_WORKER_PARENT
    TEST_ENV_NUMBER PARALLEL_TEST_GROUPS PARALLEL_TEST_FIRST_IS_1 RSPEC_FORMATTER_OUTPUT_ID SIMPLECOV_RUN_ID
  ].freeze

  around do |example|
    with_env(worker_vars.to_h { |k| [k, nil] }) do
      described_class.reset!
      Dir.mktmpdir { |dir| @dir = dir and example.run }
    ensure
      described_class.reset!
    end
  end

  # Runs the block in a child so signal traps, at_exit handlers and spawned
  # workers never touch the spec process; returns the child's exit status.
  def isolated(&block)
    pid = fork do
      $stdout.reopen(File.join(@dir, "stdout"), "a")
      block.call
      $stdout.flush
      exit(0)
    end
    Process.wait2(pid).last.exitstatus
  end

  def events
    path = File.join(@dir, "events")
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  def stdout
    File.read(File.join(@dir, "stdout"))
  end

  # A stand-in for `selective`: logs its worker environment, then runs `body`.
  def worker_script(body = "")
    path = File.join(@dir, "worker.rb")
    File.write(path, <<~RUBY)
      def log(line)
        File.open(#{File.join(@dir, "events").inspect}, "a") { |f| f.puts(line) }
      end
      index = ENV["SELECTIVE_WORKER_INDEX"]
      log(["env", index, ENV["TEST_ENV_NUMBER"].inspect, ENV["SELECTIVE_WORKER_COUNT"], ENV["PARALLEL_TEST_GROUPS"],
        ENV["SELECTIVE_RUNNER_ID"], ENV["SELECTIVE_WORKER_PARENT"] == Process.ppid.to_s, ENV["LEAD_ONLY"].inspect].join(" "))
      #{body}
    RUBY
    path
  end

  def launch(count, script)
    described_class.capture([])
    described_class.instance_variable_set(:@command, [RbConfig.ruby, script])
    described_class.launch(count, runner_id: "node-3")
  end

  describe ".plan" do
    let(:runner) { double("runner") }

    it "runs one worker by default" do
      expect(described_class.plan(nil, runner).to_a).to eq([1, nil])
    end

    it "takes the runner's own parallelism" do
      allow(runner).to receive(:default_workers).and_return([3, "Rails parallelize"])
      expect(described_class.plan(nil, runner).to_a).to eq([3, "Rails parallelize"])
    end

    it "prefers SELECTIVE_WORKERS over the runner's" do
      allow(runner).to receive(:default_workers).and_return([3, "Rails parallelize"])
      with_env("SELECTIVE_WORKERS" => "2") do
        expect(described_class.plan(nil, runner).to_a).to eq([2, "SELECTIVE_WORKERS"])
      end
    end

    it "prefers --workers over SELECTIVE_WORKERS" do
      with_env("SELECTIVE_WORKERS" => "2") { expect(described_class.plan("5", runner).count).to eq(5) }
    end

    it "lets SELECTIVE_WORKERS=1 turn the runner's parallelism off" do
      allow(runner).to receive(:default_workers).and_return([3, "Rails parallelize"])
      with_env("SELECTIVE_WORKERS" => "1") { expect(described_class.plan(nil, runner).count).to eq(1) }
    end

    it "ignores the runner's parallelism under an outer tool" do
      allow(runner).to receive(:default_workers).and_return([3, "Rails parallelize"])
      with_env("PARALLEL_TEST_GROUPS" => "4") { expect(described_class.plan(nil, runner).count).to eq(1) }
    end

    it "reads auto as the processor count" do
      expect(described_class.plan("auto", runner).count).to eq(Etc.nprocessors)
    end

    it "treats zero as one" do
      expect(described_class.plan("0", runner).count).to eq(1)
    end

    it "rejects anything else" do
      expect { described_class.plan("lots", runner) }.to raise_error(described_class::InvalidCount, /"lots"/)
    end
  end

  describe ".worker_env" do
    it "numbers workers the way parallel_tests does" do
      expect((0..2).map { |i| described_class.worker_env(i, 3)["TEST_ENV_NUMBER"] }).to eq(["", "2", "3"])
      expect(described_class.worker_env(1, 3)).to include("SELECTIVE_WORKER_INDEX" => "1", "SELECTIVE_WORKER_COUNT" => "3", "PARALLEL_TEST_GROUPS" => "3")
    end

    it "starts at 1 with PARALLEL_TEST_FIRST_IS_1" do
      with_env("PARALLEL_TEST_FIRST_IS_1" => "true") do
        expect((0..1).map { |i| described_class.worker_env(i, 2)["TEST_ENV_NUMBER"] }).to eq(["1", "2"])
      end
    end
  end

  describe ".prepare" do
    it "makes this process worker 0 before the suite loads when the count is given" do
      described_class.prepare("3")

      expect(described_class).to be_lead
      expect(ENV.to_h).to include("SELECTIVE_WORKER_INDEX" => "0", "TEST_ENV_NUMBER" => "", "PARALLEL_TEST_GROUPS" => "3")
    end

    it "leaves a single process, an invalid count and an outer tool's process alone" do
      described_class.prepare(nil)
      described_class.prepare("1")
      described_class.prepare("lots")
      with_env("PARALLEL_TEST_GROUPS" => "2") { described_class.prepare("3") }

      expect(described_class).not_to be_lead
      expect(ENV["SELECTIVE_WORKER_INDEX"]).to be_nil
    end
  end

  describe ".launch" do
    it "starts the other workers as fresh processes and becomes worker 0" do
      status = isolated do
        with_env("LEAD_ONLY" => "captured") do
          described_class.instance_variable_set(:@env, nil)
          described_class.capture([])
          with_env("LEAD_ONLY" => "changed while booting") do
            described_class.instance_variable_set(:@command, [RbConfig.ruby, worker_script])
            described_class.launch(3, runner_id: "node-3")
            File.open(File.join(@dir, "events"), "a") { |f| f.puts("lead #{ENV["SELECTIVE_WORKER_INDEX"]} #{described_class.lead?}") }
          end
        end
      end

      expect(status).to eq(0)
      expect(events).to include("lead 0 true")
      expect(events.grep(/\Aenv/).sort).to eq([
        'env 1 "2" 3 3 node-3 true "captured"',
        'env 2 "3" 3 3 node-3 true "captured"'
      ])
    end

    it "runs before_launch once, in worker 0" do
      isolated do
        described_class.before_launch { File.open(File.join(@dir, "events"), "a") { |f| f.puts("before_launch #{Process.pid}") } }
        launch(2, worker_script)
      end

      expect(events.grep(/\Abefore_launch/).size).to eq(1)
    end

    it "exits with the worst status and names the workers that failed" do
      status = isolated do
        launch(3, worker_script("exit(Integer(index))"))
        exit(1)
      end

      expect(status).to eq(2)
      expect(stdout).to include("Selective: 3 workers finished; worker 0 exited 1, worker 1 exited 1, worker 2 exited 2.")
    end

    it "keeps worker 0's status when the others pass" do
      status = isolated do
        launch(2, worker_script)
        exit(3)
      end

      expect(status).to eq(3)
    end

    it "fails the node when a worker is killed" do
      status = isolated { launch(2, worker_script('Process.kill("KILL", Process.pid)')) }

      expect(status).to eq(1)
      expect(stdout).to include("worker 1 was killed by SIGKILL")
    end

    it "forwards INT and TERM to the other workers and waits for them" do
      %w[TERM INT].each do |signal|
        File.write(File.join(@dir, "events"), "")
        script = worker_script(<<~RUBY)
          Signal.trap(#{signal.inspect}) { log("#{signal} \#{index}"); exit(3) }
          log("ready \#{index}")
          sleep
        RUBY
        pid = fork do
          $stdout.reopen(File::NULL)
          launch(3, script)
          sleep
        end

        deadline = Time.now + 10
        sleep(0.02) until events.count { |e| e.start_with?("ready") } == 2 || Time.now > deadline
        Process.kill(signal, pid)
        status = Process.wait2(pid).last

        expect(status.exitstatus).to eq(3)
        expect(events.grep(/\A#{signal}/).sort).to eq(["#{signal} 1", "#{signal} 2"])
      end
    end
  end

  describe ".watch_parent" do
    it "stops a worker whose lead was killed" do
      core = File.expand_path("../../../../lib", __dir__)
      script = worker_script(<<~RUBY)
        $LOAD_PATH.unshift(#{core.inspect})
        require "selective-ruby-core"
        Signal.trap("TERM") { log("TERM \#{index}"); exit(1) }
        Selective::Ruby::Core::Workers.watch_parent
        log("ready \#{index} \#{Process.pid}")
        sleep
      RUBY
      pid = fork do
        $stdout.reopen(File::NULL)
        launch(3, script)
        sleep
      end

      deadline = Time.now + 15
      sleep(0.05) until events.count { |e| e.start_with?("ready") } == 2 || Time.now > deadline
      Process.kill("KILL", pid)
      Process.wait(pid)
      worker_pids = events.grep(/\Aready/).map { |e| e.split.last.to_i }

      deadline = Time.now + 5
      sleep(0.1) until events.grep(/\ATERM/).size == 2 || Time.now > deadline
      expect(events.grep(/\ATERM/).sort).to eq(["TERM 1", "TERM 2"])
      alive = worker_pids.select do |p|
        Process.kill(0, p)
      rescue Errno::ESRCH
        false
      end
      expect(alive).to be_empty
    end
  end

  describe ".start_worker and .finish_worker" do
    it "run the hooks once each, in a worker" do
      calls = []
      described_class.on_start { |i| calls << [:start, i] }
      described_class.on_exit { |i| calls << [:exit, i] }

      described_class.start_worker
      described_class.finish_worker
      expect(calls).to be_empty

      with_env("SELECTIVE_WORKER_INDEX" => "2") do
        2.times { described_class.start_worker }
        2.times { described_class.finish_worker }
      end
      expect(calls).to eq([[:start, 2], [:exit, 2]])
    end
  end
end
