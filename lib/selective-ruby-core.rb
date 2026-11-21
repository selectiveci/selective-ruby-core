# frozen_string_literal: true

require "zeitwerk"
require "json"
require "open3"
require "#{__dir__}/selective/ruby/core/version"

loader = Zeitwerk::Loader.for_gem(warn_on_extra_files: false)
loader.ignore("#{__dir__}/selective-ruby-core.rb")
loader.ignore("#{__dir__}/selective/ruby/core/version.rb")
loader.setup

module Selective
  module Ruby
    module Core
      class Error < StandardError; end
      class ConnectionLostError < StandardError; end

      ROOT_GEM_PATH = Gem.loaded_specs["selective-ruby-core"].full_gem_path

      @@available_runners = {}

      def self.register_runner(name, runner_class)
        @@available_runners[name] = runner_class
      end

      def self.runner_for(name)
        @@available_runners[name] || raise("Unknown runner #{name}")
      end

      class Init
        def initialize(args)
          Workers.capture(args.dup)
          @debug = !args.delete("--debug").nil?
          @log = !args.delete("--log").nil?
          @workers = extract_workers(args)
          @runner_name, @args, @command = parse_args(args)
          require_runner
        end

        def self.run(args)
          new(args).send(:run)
        end

        private

        attr_reader :debug, :log, :workers, :runner_name, :args, :command

        def run
          if command == :start
            Workers.watch_parent if Workers.sibling?
            Workers.prepare(workers)
          end
          Selective::Ruby::Core::Controller.new(runner_class, args, debug: debug, log: log, workers: workers).send(command)
        end

        # `--workers N` or `--workers=N`; nil when absent.
        def extract_workers(args)
          index = args.index { |arg| arg == "--workers" || arg.start_with?("--workers=") }
          return if index.nil?

          flag = args.delete_at(index)
          flag.include?("=") ? flag.split("=", 2).last : args.delete_at(index)
        end

        def parse_args(args)
          # Returns runner_name, args, command
          if args[0] == "exec" # e.g. selective exec rspec
            [args[1], args[2..], :exec]
          else # e.g. selective rspec
            [args[0], args[1..], :start]
          end
        end

        def runner_class
          Selective::Ruby::Core.runner_for(runner_name)
        end

        def require_runner
          require "selective-ruby-#{runner_name}"
        rescue LoadError
          nil
        end
      end
    end
  end
end
