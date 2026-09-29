# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "rbconfig"
require "tempfile"
require "uri"
require "zlib"

module Selective
  module Ruby
    module Core
      module TestMap
        # Sends this runner's recorded fragment to the server over HTTPS.
        #
        # A map is far larger than anything else a runner sends (tests × files),
        # so it doesn't go over the WebSocket. Upload failure never fails the
        # build: the worst outcome is a map missing this runner's tests, and a
        # test missing from the map is always run.
        #
        # The POST runs in a child Ruby process. The upload happens inside the
        # test process, where suites commonly load WebMock or VCR, and those
        # intercept every Net::HTTP request, this one included. A child started
        # without Bundler's environment loads neither.
        class Uploader
          PATH = "/test_maps/fragments"
          ATTEMPTS = 3

          def initialize(host:, api_key:, run_id:, run_attempt:, runner_id:, logger: nil)
            @uri = build_uri(host, run_id: run_id, run_attempt: run_attempt, runner_id: runner_id)
            @api_key = api_key
            @logger = logger
          end

          # Returns true on success.
          def upload(fragment)
            body = Zlib.gzip(JSON.generate(fragment))
            attempt = 0
            begin
              attempt += 1
              true if post(body)
            rescue => e
              @logger&.warn("Test map upload attempt #{attempt} failed: #{e.message}")
              if attempt < ATTEMPTS
                sleep(attempt)
                retry
              end
              @last_error = e
              false
            end
          end

          attr_reader :last_error, :uri

          private

          # The request, as a standalone script for the child process. The API key
          # arrives in the environment, never on the command line.
          CHILD_SCRIPT = <<~RUBY
            require "net/http"
            require "uri"
            uri = URI(ARGV.fetch(0))
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = uri.scheme == "https"
            http.open_timeout = 10
            http.read_timeout = 120
            request = Net::HTTP::Post.new(uri.request_uri)
            request["authorization"] = ENV.fetch("SELECTIVE_TEST_MAP_UPLOAD_KEY")
            request["content-type"] = "application/gzip"
            request.body = File.binread(ARGV.fetch(1))
            response = http.request(request)
            puts response.code
            warn response.body.to_s[0, 200] unless response.is_a?(Net::HTTPSuccess)
            exit(response.is_a?(Net::HTTPSuccess) ? 0 : 1)
          RUBY

          # Keeps Bundler (and whatever it would require) out of the child.
          CLEAN_ENV = %w[RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_SETUP BUNDLER_VERSION GEM_HOME
            GEM_PATH].to_h do |k|
            [k, nil]
          end

          # Raises unless the server accepted the upload.
          def post(body)
            Tempfile.create(["selective-test-map", ".json.gz"], binmode: true) do |file|
              file.write(body)
              file.flush

              env = CLEAN_ENV.merge("SELECTIVE_TEST_MAP_UPLOAD_KEY" => @api_key.to_s)
              out, err, status = Open3.capture3(env, RbConfig.ruby, "-e", CHILD_SCRIPT, @uri.to_s, file.path)
              raise "HTTP #{out.strip}: #{err.strip}" unless status.success?

              true
            end
          end

          # The runner is configured with the WebSocket host (ws:// or wss://);
          # the upload goes to the same server over HTTP(S).
          def build_uri(host, **params)
            base = host.sub(%r{\Aws(s?)://}) { "http#{::Regexp.last_match(1)}://" }.chomp("/")
            URI("#{base}#{PATH}?#{URI.encode_www_form(params)}")
          end
        end
      end
    end
  end
end
