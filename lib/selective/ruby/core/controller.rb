require "logger"
require "uri"
require "json"

module Selective
  module Ruby
    module Core
      class Controller
        @@selective_suppress_reporting = false

        def initialize(runner, debug = false)
          @debug = debug
          @runner = runner
          @retries = 0
          @runner_id = ENV.fetch("SELECTIVE_RUNNER_ID", generate_runner_id)
          @logger = Logger.new("log/#{runner_id}.log")
        end

        def start(reconnect: false)
          @pipe = NamedPipe.new("/tmp/#{runner_id}_2", "/tmp/#{runner_id}_1")
          @transport_pid = spawn_transport_process(reconnect ? transport_url + "&reconnect=true" : transport_url)

          handle_termination_signals(transport_pid)
          run_main_loop
        rescue NamedPipe::PipeClosedError
          retry!
        rescue => e
          with_error_handling { raise e }
        end

        def exec
          runner.exec
        rescue => e
          with_error_handling(include_header: false) { raise e }
        end

        def self.suppress_reporting!
          @@selective_suppress_reporting = true
        end

        def self.restore_reporting!
          @@selective_suppress_reporting = false
        end

        def self.suppress_reporting?
          @@selective_suppress_reporting
        end

        private

        attr_reader :runner, :pipe, :transport_pid, :retries, :logger, :runner_id

        BUILD_ENV_SCRIPT_PATH = "../../../bin/build_env.sh".freeze

        def run_main_loop
          loop do
            message = pipe.read
            next sleep(0.1) if message.nil? || message.empty?

            response = JSON.parse(message, symbolize_names: true)

            @logger.info("Received Command: #{response}")
            next if handle_command(response)

            break
          end
        end

        def retry!
          @retries += 1

          with_error_handling { raise "Too many retries" } if retries > 4

          puts("Retrying in #{retries} seconds...")
          sleep(retries)
          kill_transport

          pipe.reset!
          start(reconnect: true)
        end

        def write(data)
          pipe.write JSON.dump(data)
        end

        def generate_runner_id
          "selgen-#{SecureRandom.hex(4)}"
        end

        def transport_url
          @transport_url ||= begin
            api_key = ENV.fetch("SELECTIVE_API_KEY")
            run_id = ENV.fetch("SELECTIVE_RUN_ID")
            run_attempt = ENV.fetch("SELECTIVE_RUN_ATTEMPT", SecureRandom.uuid)
            host = ENV.fetch("SELECTIVE_HOST", "wss://app.selective.ci")

            # Validate that host is a valid websocket url(starts with ws:// or wss://)
            raise "Invalid host: #{host}" unless host.match?(/^wss?:\/\//)

            params = {
              "run_id" => run_id,
              "run_attempt" => run_attempt,
              "api_key" => api_key,
              "runner_id" => runner_id
            }.merge(metadata: build_env.to_json)

            query_string = URI.encode_www_form(params)

            "#{host}/transport/websocket?#{query_string}"
          end
        end

        def build_env
          result = `#{Pathname.new(__dir__) + BUILD_ENV_SCRIPT_PATH}`
          JSON.parse(result)
        end

        def spawn_transport_process(url)
          root_path = Gem.loaded_specs["selective-ruby-core"].full_gem_path
          transport_path = File.join(root_path, "lib", "bin", "transport")
          get_transport_path = File.join(root_path, "bin", "get_transport")

          # The get_transport script is not released with the gem, so this
          # code is intended for development/CI purposes.
          if !File.exist?(transport_path) && File.exist?(get_transport_path)
            require "open3"
            output, status = Open3.capture2e(get_transport_path)
            if !status.success?
              puts <<~TEXT
                Failed to download transport binary.

                #{output}
              TEXT
            end
          end

          Process.spawn(transport_path, url, runner_id).tap do |pid|
            Process.detach(pid)
          end
        end

        def handle_termination_signals(pid)
          ["INT", "TERM"].each do |signal|
            Signal.trap(signal) do
              # :nocov:
              kill_transport(signal: signal)
              exit
              # :nocov:
            end
          end
        end

        def kill_transport(signal: "TERM")
          begin
            pipe.write "exit"

            # Give up to 5 seconds for graceful exit
            # before killing it below
            1..5.times do
              Process.getpgid(transport_pid)

              sleep(1)
            end
          rescue NamedPipe::PipeClosedError
            # If the pipe is close, move straight to killing
            # it forcefully.
          end

          # :nocov:
          Process.kill(signal, transport_pid)
          # :nocov:
        rescue Errno::ESRCH
          # Process already gone noop
        end

        def handle_command(response)
          case response[:command]
          when "init"
            print_init(response[:runner_id])
          when "test_manifest"
            handle_test_manifest
          when "run_test_cases"
            handle_run_test_cases(response[:test_case_ids])
          when "remove_failed_test_case_result"
            handle_remove_failed_test_case_result(response[:test_case_id])
          when "reconnect"
            handle_reconnect
          when "print_message"
            handle_print_message(response[:message])
          when "close"
            handle_close(response[:exit_status])

            # This is here for the sake of test where we
            # cannot exit but we need to break the loop
            return false
          end

          true
        end

        def handle_reconnect
          kill_transport
          pipe.reset!
          start(reconnect: true)
        end

        def handle_test_manifest
          self.class.restore_reporting!
          @logger.info("Sending Response: test_manifest")
          write({type: "test_manifest", data: {
            test_cases: runner.manifest["examples"],
            modified_test_files: modified_test_files
          }})
        end

        def handle_run_test_cases(test_cases)
          runner.run_test_cases(test_cases, method(:test_case_callback))
        end

        def test_case_callback(test_case)
          @logger.info("Sending Response: test_case_result: #{test_case[:id]}")
          write({type: "test_case_result", data: test_case})
        end

        def handle_remove_failed_test_case_result(test_case_id)
          runner.remove_failed_test_case_result(test_case_id)
        end

        def modified_test_files
          # Todo: This should find files changed in the current branch
          `git diff --name-only`.split("\n").filter do |f|
            f.match?(/^#{runner.base_test_path}/)
          end
        end

        def handle_print_message(message)
          print_warning(message)
        end

        def handle_close(exit_status = nil)
          self.class.restore_reporting!
          runner.finish unless exit_status.is_a?(Integer)

          kill_transport
          pipe.delete_pipes
          exit(exit_status || runner.exit_status)
        end

        def debug?
          @debug
        end

        def with_error_handling(include_header: true)
          yield
        rescue => e
          raise e if debug?
          header = <<~TEXT
            An error occurred. Please rerun with --debug
            and contact support at https://selective.ci/support
          TEXT

          unless @banner_displayed
            header = <<~TEXT
              #{banner}

              #{header}
            TEXT
          end

          puts_indented <<~TEXT
            \e[31m
            #{header if include_header}
            #{e.message}
            \e[0m
          TEXT

          exit 1
        end

        def print_warning(message)
          puts_indented <<~TEXT
            \e[33m
            #{message}
            \e[0m
          TEXT
        end

        def print_init(runner_id)
          puts_indented <<~TEXT
            #{banner}
            Runner ID: #{runner_id.gsub("selgen-", "")}
          TEXT
        end

        def puts_indented(text)
          puts text.gsub(/^/, "  ")
        end

        def banner
          @banner_displayed = true
          <<~BANNER
             ____       _           _   _
            / ___|  ___| | ___  ___| |_(_)_   _____
            \\___ \\ / _ \\ |/ _ \\/ __| __| \\ \\ / / _ \\
             ___) |  __/ |  __/ (__| |_| |\\ V /  __/
            |____/ \\___|_|\\___|\\___|\\__|_| \\_/ \\___|
            ________________________________________
          BANNER
        end
      end
    end
  end
end
