module Selective
  module Ruby
    module Core
      class FileCorrelator
        include Helper

        class FileCorrelatorError < StandardError; end

        FILE_CORRELATION_COLLECTOR_PATH = File.join(ROOT_GEM_PATH, "lib", "bin", "file_correlation_collector.sh")

        def initialize(diff, num_commits, target_branch)
          @diff = diff
          @num_commits = num_commits
          @target_branch = target_branch
        end

        def correlate
          JSON.parse(get_correlated_files, symbolize_names: true)
        rescue FileCorrelatorError, JSON::ParserError
          print_warning "Selective was unable to correlate the diff to test files. This may result in a sub-optimal test order. If the issue persists, please contact support."
        end

        private

        attr_reader :diff, :num_commits, :target_branch

        def get_correlated_files
          Open3.capture2e("#{FILE_CORRELATION_COLLECTOR_PATH} #{target_branch} #{num_commits} #{diff.join(" ")}").then do |output, status|

            raise FileCorrelatorError unless status.success?

            output
          end
        end
      end
    end
  end
end
