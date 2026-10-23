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
          @outbox = Queue.new
          @reader = Thread.new { read_stdout }
          @writer = Thread.new { write_stdin }
        end

        def write(message)
          raise ConnectionLostError if @lost || !@wait_thread.alive?

          @outbox << "#{message}\n"
        rescue ClosedQueueError
          raise ConnectionLostError
        end

        def read
          @queue.pop || raise(ConnectionLostError)
        end

        def shutdown
          @outbox.close
          @writer.join(SHUTDOWN_GRACE)
          @stdin.close
          %w[TERM KILL].each do |signal|
            break if @wait_thread.join(SHUTDOWN_GRACE)

            signal_child(signal)
          end
          @wait_thread.join
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

        def write_stdin
          while (frame = @outbox.pop)
            @stdin.write(frame)
          end
        rescue Errno::EPIPE, IOError
          @lost = true
        end

        def signal_child(signal)
          Process.kill(signal, @pid)
        rescue Errno::ESRCH
          nil
        end
      end
    end
  end
end
