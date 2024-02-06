module Selective
  module Ruby
    module Core
      class NamedPipe
        attr_reader :read_pipe_path, :write_pipe_path

        def initialize(read_pipe_path, write_pipe_path, skip_reset: false)
          @read_pipe_path = read_pipe_path
          @write_pipe_path = write_pipe_path

          delete_pipes unless skip_reset
          initialize_pipes
        end

        def initialize_pipes
          create_pipes

          # Open the read and write pipes in separate threads
          Thread.new do
            @read_pipe = File.open(read_pipe_path, "r")
          end
          Thread.new do
            @write_pipe = File.open(write_pipe_path, "w")
          end
        end

        def write(message)
          return unless write_pipe

          chunk_size = 1024  # 1KB chunks
          offset = 0
          begin
            while offset < message.bytesize
              chunk = message.byteslice(offset, chunk_size)

              write_pipe.write(chunk)
              write_pipe.flush

              offset += chunk_size
            end

            write_pipe.write("\n")
            write_pipe.flush
          rescue Errno::EPIPE
            raise ConnectionLostError
          end
        end

        def read
          return unless read_pipe
          begin
            message = read_pipe.gets.chomp
          rescue NoMethodError => e
            if e.name == :chomp
              raise ConnectionLostError
            else
              raise e
            end
          end
          message
        end

        def reset!
          delete_pipes
          initialize_pipes
        end

        def delete_pipes
          # Close the pipes before deleting them
          read_pipe&.close
          write_pipe&.close

          # Allow threads to close before deleting pipes
          sleep(0.1)

          delete_pipe(read_pipe_path)
          delete_pipe(write_pipe_path)
        rescue Errno::EPIPE
          # Noop
        end

        private

        attr_reader :read_pipe, :write_pipe

        def create_pipes
          create_pipe(read_pipe_path)
          create_pipe(write_pipe_path)
        end

        def create_pipe(path)
          system("mkfifo #{path}") unless File.exist?(path)
        end

        def delete_pipe(path)
          File.delete(path) if File.exist?(path)
        end
      end
    end
  end
end
