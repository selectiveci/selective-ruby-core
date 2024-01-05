module Selective
  module Ruby
    module Core
      class FileCorrelator
        include Helper

        class FileCorrelatorError < StandardError; end

        FILE_CORRELATION_COLLECTOR_PATH = File.join(ROOT_GEM_PATH, "lib", "bin", "file_correlation_collector.sh")

        def initialize(data, diff, target_branch)
          @num_commits = data[:num_commits] || 1000
          @diff = diff
          @target_branch = target_branch
        end

        def correlate
          fetch_target_branch
          JSON.parse(get_correlated_files, symbolize_names: true)
        rescue FileCorrelatorError, JSON::ParserError
          print_warning "Selective was unable to correlate the diff to test files. This may result in a sub-optimal test order. If the issue persists, please contact support."
        end

        private

        attr_reader :num_commits, :target_branch, :diff

        def fetch_target_branch
          Open3.capture2e("git fetch origin #{target_branch} --depth=#{num_commits}").tap do |_, status|
            raise FileCorrelatorError unless status.success?
          end
        end

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
