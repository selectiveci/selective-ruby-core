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
          @shut_down = false
          @reader = Thread.new { read_stdout }
        end

        def write(message)
          io = @stdin
          raise ConnectionLostError if io.nil? || io.closed?

          io.write("#{message}\n")
        rescue Errno::EPIPE, Errno::ECONNRESET, Errno::EBADF, IOError
          raise ConnectionLostError
        end

        def read
          message = @queue.pop
          raise ConnectionLostError if message.nil?

          message
        rescue ClosedQueueError
          raise ConnectionLostError
        end

        def reset!
          shutdown
        end

        def delete_pipes
          shutdown
        end

        def alive?
          Process.getpgid(@pid)
          true
        rescue Errno::ESRCH
          false
        end

        def shutdown
          return if @shut_down

          @shut_down = true
          request_exit
          close_io(@stdin)
          reaped = @wait_thread.join(SHUTDOWN_GRACE)
          unless reaped
            terminate_child
            @wait_thread.join(SHUTDOWN_GRACE)
          end
          close_io(@stdout)
          @reader&.join(SHUTDOWN_GRACE)
          @queue.close
        end

        private

        def read_stdout
          while (line = @stdout.gets)
            @queue << line.chomp
          end
        rescue IOError, Errno::EBADF, ClosedQueueError
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

        def close_io(io)
          return if io.nil? || io.closed?

          io.close
        rescue IOError, Errno::EBADF
          nil
        end
      end
    end
  end
end
