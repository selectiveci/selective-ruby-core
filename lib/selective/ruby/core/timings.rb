# frozen_string_literal: true

module Selective
  module Ruby
    module Core
      # Where a runner's time goes, from clock reads at points the controller
      # already passes. Startup marks go out with the manifest; batch totals
      # go out with report_at_finish. All in milliseconds; `*_at` marks are
      # Unix epoch, so the server can line them up with its own.
      class Timings
        attr_reader :marks

        def initialize(loaded_at_ms: LOADED_AT_MS)
          @marks = {"core_loaded_at" => loaded_at_ms}
          started = self.class.process_started_at_ms
          @marks["process_started_at"] = started if started
          @batches = 0
          @run_ms = 0
          @idle_ms = 0
          @write_ms = 0
          @example_ms = 0.0
          @examples = 0
        end

        def self.now_ms
          Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
        end

        def self.monotonic_ms
          Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
        end

        # Linux only: the process's start from /proc, so time spent before
        # this gem loaded (bundler, the app's own requires) is visible.
        def self.process_started_at_ms
          ticks = File.read("/proc/self/stat").split(") ").last.split(" ")[19].to_i
          uptime_s = File.read("/proc/uptime").split(" ").first.to_f
          hertz = 100.0
          now_ms - ((uptime_s - ticks / hertz) * 1000).round
        rescue SystemCallError, NoMethodError
          nil
        end

        def mark(name)
          @marks["#{name}_at"] ||= self.class.now_ms
        end

        def measure(name)
          started = self.class.monotonic_ms
          yield
        ensure
          @marks["#{name}_ms"] = self.class.monotonic_ms - started
        end

        # Time spent blocked on the next command, split at the first batch:
        # before it is startup, after it is waiting for work.
        def waited(ms)
          if @batches.zero?
            @marks["wait_before_first_batch_ms"] = (@marks["wait_before_first_batch_ms"] || 0) + ms
          else
            @idle_ms += ms
          end
        end

        def batch
          mark("first_batch")
          started = self.class.monotonic_ms
          yield
        ensure
          @batches += 1
          @run_ms += self.class.monotonic_ms - started
          mark_last_batch
        end

        def wrote(ms)
          @write_ms += ms
        end

        def example(run_time_s)
          @examples += 1
          @example_ms += run_time_s.to_f * 1000
        end

        def startup
          marks.dup
        end

        def finish
          {
            "batches" => @batches,
            "examples" => @examples,
            "run_ms" => @run_ms,
            "example_ms" => @example_ms.round,
            "outside_examples_ms" => [@run_ms - @example_ms.round, 0].max,
            "idle_between_batches_ms" => @idle_ms,
            "result_write_ms" => @write_ms
          }.merge(marks.slice("first_batch_at", "last_batch_at", "wait_before_first_batch_ms"))
        end

        private

        def mark_last_batch
          @marks["last_batch_at"] = self.class.now_ms
        end
      end
    end
  end
end
