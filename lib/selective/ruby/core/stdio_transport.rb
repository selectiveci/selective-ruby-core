# frozen_string_literal: true

require "open3"

module Selective
  module Ruby
    module Core
      class StdioTransport
        SHUTDOWN_GRACE = 1

        attr_reader :pid, :wait_thread

        def self.open(binary, url)
          stdin, stdout, wait_thread = Open3.popen2(
            {"SELECTIVE_TRANSPORT_URL" => url},
            binary,
            "--stdio",
            pgroup: true
          )
          new(stdin, stdout, wait_thread)
        end

        def initialize(stdin, stdout, wait_thread)
          @stdin = stdin
          @stdout = stdout
          @wait_thread = wait_thread
          @pid = wait_thread.pid
          @queue = Queue.new
          @reader = Thread.new { read_stdout }
        end

        def write(message)
          @stdin.write("#{message}\n")
        rescue Errno::EPIPE, IOError
          raise ConnectionLostError
        end

        def read
          @queue.pop || raise(ConnectionLostError)
        end

        def shutdown
          request_exit
          @stdin.close
          reaped = @wait_thread.join(SHUTDOWN_GRACE)
          unless reaped
            terminate_child
            @wait_thread.join(SHUTDOWN_GRACE)
          end
          @stdout.close
          @reader.join(SHUTDOWN_GRACE)
          @queue.close
        end

        alias_method :reset!, :shutdown
        alias_method :delete_pipes, :shutdown

        private

        def read_stdout
          while (line = @stdout.gets)
            @queue << line.chomp
          end
        rescue IOError, ClosedQueueError
          nil
        ensure
          @queue.close
        end

        def request_exit
          write("exit")
        rescue ConnectionLostError
          nil
        end

        def terminate_child
          Process.kill("TERM", @pid)
        rescue Errno::ESRCH
          nil
        end
      end
    end
  end
end
