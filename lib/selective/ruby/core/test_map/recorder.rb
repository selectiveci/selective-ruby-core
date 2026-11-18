# frozen_string_literal: true

require "set"

module Selective
  module Ruby
    module Core
      module TestMap
        # Accumulates "test id => files" for every test this runner executes and
        # serialises it as a fragment. Paths are interned into a table so a
        # fragment carries each path once, not once per test that touched it.
        class Recorder
          FORMAT_VERSION = 1

          attr_reader :tracer

          def initialize(tracer:)
            @tracer = tracer
            @paths = []
            @path_index = {}
            @tests = {}
          end

          # Retries and reruns can run a test twice in one process. Keep the
          # union: a dependency seen on any attempt is a real dependency.
          def record(test_id)
            result, files = tracer.trace { yield }
            indexes = (@tests[test_id] ||= Set.new)
            files.each { |path| indexes << intern(path) }
            result
          end

          def test_count
            @tests.size
          end

          def empty?
            @tests.empty?
          end

          def to_h
            {
              version: FORMAT_VERSION,
              files: @paths,
              tests: @tests.map { |id, indexes| {id: id, deps: indexes.to_a.sort} }
            }
          end

          private

          def intern(path)
            @path_index[path] ||= begin
              @paths << path
              @paths.size - 1
            end
          end
        end
      end
    end
  end
end
