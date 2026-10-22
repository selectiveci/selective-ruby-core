# frozen_string_literal: true

require "open3"

module Selective
  module Ruby
    module Core
      class StdioTransport
        SHUTDOWN_GRACE = 1
        CLOSED = Object.new

        attr_reader :pid, :wait_thread, :stderr_lines

        def self.open(binary, url)
          stdin, stdout, stderr, wait_thread = Open3.popen3(
            {"SELECTIVE_TRANSPORT_URL" => url},
            binary,
            "--stdio"
          )
          new(stdin, stdout, stderr, wait_thread)
        end

        def initialize(stdin, stdout, stderr, wait_thread)
          @stdin = stdin
          @stdout = stdout
          @stderr = stderr
          @wait_thread = wait_thread
          @pid = wait_thread.pid
          @queue = Queue.new
          @close_mutex = Mutex.new
          @stderr_mutex = Mutex.new
          @stderr_lines = []
          @closed_signaled = false
          @shut_down = false
          @stdin.sync = true
          @reader = Thread.new { read_stdout }
          @stderr_reader = Thread.new { drain_stderr }
        end

        def write(message)
          io = @stdin
          raise ConnectionLostError if io.nil? || io.closed?

          io.write(message)
          io.write("\n")
          io.flush
        rescue Errno::EPIPE, Errno::ECONNRESET, Errno::EBADF, IOError
          raise ConnectionLostError
        end

        def read
          message = @queue.pop
          raise ConnectionLostError if message.equal?(CLOSED)

          message
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
          close_io(@stderr)
          signal_closed
          @reader&.join(SHUTDOWN_GRACE)
          @stderr_reader&.join(SHUTDOWN_GRACE)
        end

        private

        def read_stdout
          until @stdout.closed?
            line = @stdout.gets
            break if line.nil?

            @queue << line.chomp
          end
        rescue IOError, Errno::EBADF
          nil
        ensure
          signal_closed
        end

        def drain_stderr
          until @stderr.closed?
            line = @stderr.gets
            break if line.nil?

            @stderr_mutex.synchronize do
              @stderr_lines << line
              @stderr_lines.shift while @stderr_lines.size > 50
            end
          end
        rescue IOError, Errno::EBADF
          nil
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

        def signal_closed
          should_signal = false
          @close_mutex.synchronize do
            unless @closed_signaled
              @closed_signaled = true
              should_signal = true
            end
          end
          @queue << CLOSED if should_signal
        end
      end
    end
  end
end
