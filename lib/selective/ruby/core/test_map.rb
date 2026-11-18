# frozen_string_literal: true

module Selective
  module Ruby
    module Core
      # Test maps let Selective skip tests a change can't affect.
      #
      # A *recording* run traces every test with the native tracer and uploads
      # "test id => repo files it executed" when the runner finishes. A later
      # run sends a snapshot of the repository's file hashes with its manifest,
      # and the server skips a test only when every file it depends on is
      # byte-for-byte what it was when the map was recorded.
      #
      # Everything here is inert unless the server asks for it
      # (`configure_test_map`), and recording additionally needs the optional
      # native extension. Without either, the suite runs exactly as before.
      module TestMap
        class << self
          # True when the native tracer compiled and loads on this Ruby.
          def available?
            return @available if defined?(@available)

            @available = if disabled?
              false
            else
              begin
                require "selective_tracer"
                true
              rescue LoadError
                false
              end
            end
          end

          # SELECTIVE_TEST_MAP_DISABLE=1 is the escape hatch: the runner then
          # never records and never takes part in selection.
          def disabled?
            ENV["SELECTIVE_TEST_MAP_DISABLE"].to_s.match?(/\A(1|true|yes)\z/i)
          end

          # What this runner can do, as advertised to the server. Selection
          # needs only a git snapshot, so a runner without the native tracer
          # (unsupported Ruby, failed compile) still runs selected subsets
          # from maps recorded elsewhere; it just can't record one.
          def capability
            return "0" if disabled?

            available? ? "record" : "select"
          end

          # Recording is one-way for the life of the process: a reconnect can
          # make the server re-send its configuration, and dropping a recorder
          # would throw away every test traced so far.
          def configure(record: false, tree: false, allocations: true)
            @tree_requested = tree
            if record && available?
              @recorder ||= Recorder.new(tracer: Tracer.new(allocations: allocations))
            end
            @recorder
          end

          def recording?
            !@recorder.nil?
          end

          def tree_requested?
            @tree_requested == true
          end

          # Wraps one test. Adapters call this around the framework's own
          # "run this test" so setup, the test body and teardown are all traced.
          def around(test_id)
            recorder = @recorder
            return yield if recorder.nil?

            recorder.record(test_id) { yield }
          end

          attr_reader :recorder

          def reset!
            @recorder = nil
            @tree_requested = false
          end
        end
      end
    end
  end
end
