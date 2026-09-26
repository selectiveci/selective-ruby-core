# frozen_string_literal: true

require "json"
require "net/http"
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
              response = post(body)
              return true if response.is_a?(Net::HTTPSuccess)

              raise "HTTP #{response.code}: #{response.body.to_s[0, 200]}"
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

          def post(body)
            http = Net::HTTP.new(@uri.host, @uri.port)
            http.use_ssl = @uri.scheme == "https"
            http.open_timeout = 10
            http.read_timeout = 120
            request = Net::HTTP::Post.new(@uri.request_uri)
            request["authorization"] = @api_key
            request["content-type"] = "application/gzip"
            request.body = body
            http.request(request)
          end

          # The runner is configured with the WebSocket host (ws:// or wss://);
          # the upload goes to the same server over HTTP(S).
          def build_uri(host, **params)
            base = host.sub(/\Aws(s?):\/\//) { "http#{$1}://" }.chomp("/")
            URI("#{base}#{PATH}?#{URI.encode_www_form(params)}")
          end
        end
      end
    end
  end
end
