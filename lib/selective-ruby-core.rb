# frozen_string_literal: true

require "zeitwerk"

loader = Zeitwerk::Loader.for_gem(warn_on_extra_files: false)
loader.ignore("#{__dir__}/selective-ruby-core.rb")
loader.setup

module Selective
  module Ruby
    module Core
      class Error < StandardError; end

      @@available_runners = {}

      def self.register_runner(name, runner_class)
        @@available_runners[name] = runner_class
      end

      def self.runner_for(name)
        @@available_runners[name] || raise("Unknown runner #{name}")
      end

      class Init
        def initialize(args)
          @debug = !args.delete("--debug").nil?
          @runner_name, @args, @command = parse_args(args)
          require_runner
        end

        def self.run(args)
          new(args).send(:run)
        end

        private

        attr_reader :debug, :runner_name, :args, :command

        def run
          Selective::Ruby::Core::Controller.new(runner, debug).send(command)
        end

        def parse_args(args)
          # Returns runner_name, args, command
          if args[0] == "exec" # e.g. selective exec rspec
            [args[1], args[2..], :exec]
          else # e.g. selective rspec
            [args[0], args[1..], :start]
          end
        end

        def runner
          Selective::Ruby::Core.runner_for(runner_name).new(args)
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
