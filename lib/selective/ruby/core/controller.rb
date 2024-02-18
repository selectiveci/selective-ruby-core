require "logger"
require "uri"
require "fileutils"

module Selective
  module Ruby
    module Core
      class Controller
        include Helper
        @@selective_suppress_reporting = false
        @@report_at_finish = {}

        REQUIRED_CONFIGURATION = {
          "host" => "SELECTIVE_HOST",
          "api_key" => "SELECTIVE_API_KEY",
          "platform" => "SELECTIVE_PLATFORM",
          "run_id" => "SELECTIVE_RUN_ID",
          "run_attempt" => "SELECTIVE_RUN_ATTEMPT",
          "branch" => "SELECTIVE_BRANCH"
        }.freeze

        def initialize(runner_class, runner_args, debug: false, log: false)
          @debug = debug
          @runner = runner_class.new(runner_args, method(:test_case_callback))
          @retries = 0
          @runner_id = safe_filename(get_runner_id)
          @logger = init_logger(log)
          @time_waiting = 0
        end

        def start(reconnect: false)
          @pipe = NamedPipe.new("/tmp/#{runner_id}_2", "/tmp/#{runner_id}_1")
          @transport_pid = spawn_transport_process(reconnect: reconnect)

          handle_termination_signals(transport_pid)
          wait_for_connectivity
          run_main_loop
        rescue ConnectionLostError
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

        def self.report_at_finish
          @@report_at_finish
        end

        private

        attr_reader :runner, :pipe, :transport_pid, :retries, :logger, :runner_id, :diff

        def get_runner_id
          runner_id = build_env["runner_id"]
          return generate_runner_id if runner_id.nil? || runner_id.empty?

          runner_id
        end

        def init_logger(enabled)
          if enabled
            FileUtils.mkdir_p("log")
            Logger.new("log/#{runner_id}.log")
          else
            Logger.new("/dev/null")
          end
        end

        def run_main_loop
          time = Time.now
          loop do
            message = pipe.read
            @time_waiting += (Time.now - time)
            response = JSON.parse(message, symbolize_names: true)

            @logger.info("Received Command: #{response}")
            break if handle_command(response) == :break
            time = Time.now
          end
        end

        def retry!
          @retries += 1

          with_error_handling { raise "Too many retries" } if retries > 10

          puts("Retrying in #{retries} seconds...") if debug?
          sleep(retries > 4 ? 4 : retries)
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

        def transport_url(reconnect: false)
          base_transport_url_params[:reconnect] = true if reconnect
          query_string = URI.encode_www_form(base_transport_url_params)
          "#{build_env["host"]}/transport/websocket?#{query_string}"
        end

        def base_transport_url_params
          @base_transport_url_params ||= begin
            api_key = build_env["api_key"]
            run_id = build_env["run_id"]
            run_attempt = build_env["run_attempt"]

            metadata = build_env.reject { |k,v| %w(host runner_id api_key run_id run_attempt).include?(k) }

            {
              "api_key" => api_key,
              "run_id" => run_id,
              "run_attempt" => run_attempt,
              "runner_id" => runner_id,
              "language" => "ruby",
              "core_version" => Selective::Ruby::Core::VERSION,
              "framework" => runner.framework,
              "framework_version" => runner.framework_version,
              "framework_wrapper_version" => runner.wrapper_version,
            }.merge(metadata: metadata.to_json)
          end
        end

        def build_env
          @build_env ||= begin
            result = `#{File.join(ROOT_GEM_PATH, "lib", "bin", "build_env.sh")}`
            JSON.parse(result).tap do |env|
              validate_build_env(env)
            end
          end
        end

        def validate_build_env(env)
          missing = REQUIRED_CONFIGURATION.each_with_object([]) do |(key, env_var), arry|
            arry << env_var if env[key].nil? || env[key].empty?
          end
          
          with_error_handling do
            raise "Missing required environment variables: #{missing.join(", ")}" unless missing.empty?
            raise "Invalid host: #{env['host']}" unless env['host'].match?(/^wss?:\/\//)
          end
        end

        def spawn_transport_process(reconnect: false)
          transport_path = File.join(ROOT_GEM_PATH, "lib", "bin", "transport")
          get_transport_path = File.join(ROOT_GEM_PATH, "bin", "get_transport")

          # The get_transport script is not released with the gem, so this
          # code is intended for development/CI purposes.
          if !File.exist?(transport_path) && File.exist?(get_transport_path)
            output, status = Open3.capture2e(get_transport_path)
            if !status.success?
              puts <<~TEXT
                Failed to download transport binary.

                #{output}
              TEXT
            end
          end

          Process.spawn(transport_path, transport_url(reconnect: reconnect), runner_id).tap do |pid|
            Process.detach(pid)
          end
        end

        def wait_for_connectivity
          @connectivity = false

          Thread.new do
            sleep(30)
            unless @connectivity
              puts "Transport process failed to start. Exiting..."
              kill_transport
              exit(1)
            end
          end

          loop do
            message = pipe.read

            # The message is nil until the transport opens the pipe
            # for writing. So, we must handle that here.
            next sleep(0.1) if message.nil?

            response = JSON.parse(message, symbolize_names: true)
            @connectivity = true if response[:command] == "connected"
            break
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
          rescue ConnectionLostError, IOError
            # If the pipe is close, move straight to killing
            # it forcefully.
          end

          # :nocov:
          Process.kill(signal, transport_pid)
          # :nocov:
        rescue Errno::ESRCH
          # Process already gone noop
        end

        def handle_command(data)
          if respond_to? "handle_#{data[:command]}", true
            send("handle_#{data[:command]}", data)
          else
            raise "Unknown command received: #{data[:command]}" if debug?
          end
        end

        def handle_print_notice(data)
          print_notice(data[:message])
        end

        def handle_reconnect(_data)
          kill_transport
          pipe.reset!
          start(reconnect: true)
        end

        def handle_test_manifest(_data)
          self.class.restore_reporting!
          @logger.info("Sending Response: test_manifest")
          data = {test_cases: runner.manifest["examples"]}
          num_commits = build_env["num_commits"] || 1000
          if (diff = get_diff(num_commits))
            data[:modified_test_files] = modified_test_files(diff)
            data[:correlated_files] = correlated_files(diff, num_commits)
          end
          write({type: "test_manifest", data: data})
        end

        def handle_run_test_cases(data)
          runner.run_test_cases(data[:test_case_ids])
        end

        # Todo: Rename this command to match the method name
        # on the runner wrapper. We should do something similar
        # to normalize handle_print_notice and handle_print_message
        def handle_remove_failed_test_case_result(data)
          runner.remove_test_case_result(data[:test_case_id])
        end

        def handle_print_message(data)
          print_warning(data[:message])
        end

        def handle_close(data)
          exit_status = data[:exit_status]
          self.class.restore_reporting!

          with_error_handling do
            puts "Total Time waiting for transport: #{@time_waiting} seconds" if debug?
            Selective::Ruby::Core::Controller.report_at_finish[:connection_retries] = @retries
            write({type: "report_at_finish", data: Selective::Ruby::Core::Controller.report_at_finish})

            runner.finish unless exit_status.is_a?(Integer)
          end

          kill_transport
          pipe.delete_pipes
          exit(exit_status || runner.exit_status)
          # This :break is here for the sake of test where
          # we cannot exit but we need to break the loop
          :break
        end

        def correlated_files(diff, num_commits)
          Selective::Ruby::Core::FileCorrelator.new(diff, num_commits, build_env["target_branch"]).correlate
        end

        def test_case_callback(test_case)
          @logger.info("Sending Response: test_case_result: #{test_case[:id]}")
          write({type: "test_case_result", data: test_case})
        end

        def modified_test_files(diff)
          @modified_test_files ||= begin
            diff.filter do |f|
              f.match?(/^#{runner.base_test_path}/)
            end
          end
        end

        def get_diff(num_commits)
          target_branch = build_env["target_branch"]
          return if target_branch.nil? || target_branch.empty?

          Open3.capture2e("git fetch origin #{target_branch} --depth=#{num_commits}").then do |output, status|
            unless status.success?
              print_warning "Selective was unable to fetch the target branch. This may result in a sub-optimal test order. If the issue persists, please contact support. The output was:\n\n#{output}"
              return
            end
          end

          Open3.capture2e("git diff origin/#{target_branch} --name-only").then do |output, status|
            if status.success?
              output.split("\n")
            else
              print_warning "Selective was unable to diff with the target branch. This may result in a sub-optimal test order. If the issue persists, please contact support. The output was:\n\n#{output}"
              nil
            end
          end
        end

        def debug?
          @debug
        end
      end
    end
  end
end
