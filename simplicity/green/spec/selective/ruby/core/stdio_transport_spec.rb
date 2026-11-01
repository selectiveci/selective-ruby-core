# frozen_string_literal: true

around { |example| with_env("SELECTIVE_FAKE_MODE" => nil, "SELECTIVE_FAKE_DIR" => directory) { example.run } }
