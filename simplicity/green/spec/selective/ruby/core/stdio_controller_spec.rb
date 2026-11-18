# frozen_string_literal: true

around do |example|
  with_env(
    "SELECTIVE_TRANSPORT" => fake_transport,
    "SELECTIVE_TRANSPORT_FIFO" => nil,
    "SELECTIVE_FAKE_MODE" => ENV["SELECTIVE_FAKE_MODE"],
    "SELECTIVE_FAKE_DIR" => directory
  ) { example.run }
end
