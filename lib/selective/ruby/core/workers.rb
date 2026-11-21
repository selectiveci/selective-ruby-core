# frozen_string_literal: true

require "etc"
require "rbconfig"

module Selective
  module Ruby
    module Core
      # Runs a node as several worker processes. Each worker is a fresh
      # `selective` process that boots the app itself, with TEST_ENV_NUMBER set
      # as parallel_tests sets it, and connects as a runner of its own
      # (`<runner id>-w<index>`). The process the command started is worker 0:
      # once its suite has loaded it starts the others, and when it is done it
      # waits for them and exits with the worst status.
      class Workers
        HOOKS = %i[before_launch on_start on_exit].freeze
        FORWARDED_SIGNALS = %w[INT TERM].freeze
        PARENT_CHECK_INTERVAL = 1
        INDEX_ENV = "SELECTIVE_WORKER_INDEX"
        COUNT_ENV = "SELECTIVE_WORKER_COUNT"
        PARENT_ENV = "SELECTIVE_WORKER_PARENT"

        class InvalidCount < StandardError; end

        Plan = Struct.new(:count, :source)

        class << self
          # Runs once, in worker 0, before the other workers start.
          def before_launch(&block)
            hooks[:before_launch] << block
          end

          # Runs in each worker with its index (0-based) after the suite has
          # loaded and before the worker connects.
          def on_start(&block)
            hooks[:on_start] << block
          end

          # Runs in each worker with its index once its tests are done, before
          # the framework reports.
          def on_exit(&block)
            hooks[:on_exit] << block
          end

          # The current worker's index, nil outside a worker.
          def index
            value = ENV[INDEX_ENV].to_s
            Integer(value, 10) unless value.empty?
          rescue ArgumentError
            nil
          end

          def worker?
            !index.nil?
          end

          # Worker 0, which starts the others.
          def lead?
            @lead == true
          end

          def sibling?
            worker? && !lead?
          end

          def count
            Integer(ENV.fetch(COUNT_ENV, "1"), 10)
          rescue ArgumentError
            1
          end

          # Records how this process was started, before the app can change
          # its environment, so the other workers start the same way.
          def capture(args)
            @command = [RbConfig.ruby, File.expand_path($PROGRAM_NAME), *args]
            @dir = Dir.pwd
            @env = ENV.to_h
          end

          # When the count is known before the suite loads, worker 0 boots with
          # the environment the others get.
          def prepare(requested)
            return if worker? || outer_tool

            count = begin
              explicit_count(requested)
            rescue InvalidCount
              nil
            end
            return if count.nil? || count < 2

            @lead = true
            ENV.update(worker_env(0, count))
            ENV["SIMPLECOV_RUN_ID"] ||= "selective-#{Process.pid}"
          end

          # `requested` (`--workers`, else SELECTIVE_WORKERS) wins; otherwise
          # the framework adapter's own parallelism setting, if any. A process
          # an outer tool started as one of several runs workers only when
          # asked to.
          def plan(requested, runner)
            plan = if (count = explicit_count(requested))
              Plan.new(count, "SELECTIVE_WORKERS")
            elsif outer_tool.nil? && runner.respond_to?(:default_workers) && (default = runner.default_workers)
              Plan.new(*default)
            else
              Plan.new(1, nil)
            end

            plan.count = 1 if plan.count < 1
            plan
          end

          def parse_count(value)
            value = value.to_s.strip
            return Etc.nprocessors if value.casecmp?("auto")

            Integer(value, 10)
          rescue ArgumentError
            raise InvalidCount, "Invalid worker count #{value.inspect}: use a number or \"auto\"."
          end

          # Makes this process worker 0 and starts the others.
          def launch(count, runner_id:)
            @lead = true
            ENV.update(worker_env(0, count))
            run_hooks(:before_launch)
            env = @env.merge("SIMPLECOV_RUN_ID" => coverage_run_id)
            @launcher = new(count, runner_id: runner_id, command: @command, dir: @dir, env: env)
            @launcher.start
          end

          # SimpleCov counts the workers of one run by this id; worker 0's own
          # is fixed once SimpleCov has started.
          def coverage_run_id
            return ::SimpleCov.run_id.to_s if defined?(::SimpleCov) && ::SimpleCov.respond_to?(:run_id)

            ENV["SIMPLECOV_RUN_ID"] || "selective-#{Process.pid}"
          end

          def signal_siblings(signal)
            @launcher&.signal(signal)
          end

          # Worker 0 waits for the others before its own exit hooks and
          # framework report, so coverage merging and other after-run work see
          # every worker's results, as the parent does under Rails parallelize.
          def wait_for_siblings
            @launcher&.wait
          end

          # Runs the on_start hooks, once.
          def start_worker
            return if !worker? || @started

            @started = true
            at_exit { finish_worker }
            run_hooks(:on_start, index)
          end

          # Runs the on_exit hooks, once, if the worker started.
          def finish_worker
            return if !@started || @finished

            @finished = true
            run_hooks(:on_exit, index)
          end

          # A worker whose lead was killed has no one to report its exit
          # status to, so it stops the way a cancelled runner does.
          def watch_parent
            parent = Integer(ENV[PARENT_ENV].to_s, 10)
            Thread.new do
              sleep(PARENT_CHECK_INTERVAL) while Process.ppid == parent
              Process.kill("TERM", Process.pid)
            end
          rescue ArgumentError
            nil
          end

          # TEST_ENV_NUMBER and PARALLEL_TEST_GROUPS follow parallel_tests, so
          # code and gems that already key databases, ports, directories or
          # coverage on them keep working.
          def worker_env(index, count)
            first_is_one = ENV["PARALLEL_TEST_FIRST_IS_1"].to_s.match?(/\A(1|true)\z/i)
            {
              INDEX_ENV => index.to_s,
              COUNT_ENV => count.to_s,
              "TEST_ENV_NUMBER" => (index.zero? && !first_is_one) ? "" : (index + 1).to_s,
              "PARALLEL_TEST_GROUPS" => count.to_s
            }
          end

          # Unsets what makes a process look like a worker, for subprocesses
          # that only list the suite.
          def non_worker_env
            (worker_env(0, 1).keys + [PARENT_ENV, "SIMPLECOV_RUN_ID"]).to_h { |key| [key, nil] }
          end

          # The tool that started this process as one of several, or nil.
          def outer_tool
            return if worker?
            return "parallel_tests" if ENV.key?("PARALLEL_TEST_GROUPS")

            "turbo_tests" if ENV.key?("RSPEC_FORMATTER_OUTPUT_ID")
          end

          # Distinguishes the processes of an outer tool, which share one
          # runner id: "1" for the first, as parallel_tests numbers them.
          def outer_process_number
            number = ENV["TEST_ENV_NUMBER"].to_s
            number.empty? ? "1" : number
          end

          def run_hooks(name, *args)
            hooks.fetch(name).each { |hook| hook.call(*args) }
          end

          def hooks
            @hooks ||= HOOKS.to_h { |name| [name, []] }
          end

          def reset!
            @hooks = nil
            @lead = nil
            @launcher = nil
            @started = nil
            @finished = nil
            @command = nil
            @dir = nil
            @env = nil
          end

          private

          def explicit_count(requested)
            value = requested.nil? ? ENV["SELECTIVE_WORKERS"] : requested
            parse_count(value) unless value.nil? || value.to_s.strip.empty?
          end
        end

        def initialize(count, runner_id:, command:, dir:, env:)
          @count = count
          @runner_id = runner_id
          @command = command
          @dir = dir
          @env = env
          @pids = {}
        end

        def start
          (1...@count).each { |index| @pids[spawn_worker(index)] = index }
          forward_signals
          at_exit { finish }
        end

        def signal(signal)
          @pids.each_key do |pid|
            Process.kill(signal, pid)
          rescue Errno::ESRCH
            nil
          end
        end

        def wait
          @statuses ||= @pids.to_h do |pid, index|
            [index, Process.wait2(pid).last]
          rescue Errno::ECHILD
            [index, nil]
          end
        end

        private

        def spawn_worker(index)
          env = @env.merge(self.class.worker_env(index, @count)).merge(
            PARENT_ENV => Process.pid.to_s,
            "SELECTIVE_RUNNER_ID" => @runner_id
          )
          Process.spawn(env, *@command, chdir: @dir, unsetenv_others: true)
        end

        # Until the runner installs its own handlers, which also forward.
        def forward_signals
          FORWARDED_SIGNALS.each do |name|
            Signal.trap(name) do
              signal(name)
              exit(1)
            end
          end
        end

        def finish
          own = case $!
          when nil then 0
          when SystemExit then $!.status
          else 1
          end
          code = report(own, wait)
          exit(code) unless code == own
        end

        def report(own, statuses)
          failed = []
          failed << [0, own, "exited #{own}"] unless own.zero?
          @pids.values.sort.each do |index|
            status = statuses[index]
            code = (status&.exited? && status.exitstatus) || 1
            failed << [index, code, describe(status)] unless code.zero?
          end

          if failed.any?
            details = failed.map { |index, _code, why| "worker #{index} #{why}" }.join(", ")
            puts "Selective: #{@count} workers finished; #{details}."
          end
          failed.map { |_index, code, _why| code }.max || 0
        end

        def describe(status)
          return "was lost" if status.nil?
          return "exited #{status.exitstatus}" if status.exited?

          signal = Signal.signame(status.termsig) if status.signaled?
          "was killed#{" by SIG#{signal}" if signal}"
        end
      end
    end
  end
end
