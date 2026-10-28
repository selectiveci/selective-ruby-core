#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

if ARGV == ["--help"]
  puts "Usage: #{$PROGRAM_NAME} <url> <runner_id>"
  exit 1
end

_url, runner_id = ARGV
directory = ENV.fetch("SELECTIVE_FAKE_DIR")
spawns = Dir[File.join(directory, "fifo-*.json")].size + 1
File.write(File.join(directory, "fifo-#{spawns}.json"), JSON.generate("argv" => ARGV))

commands = File.open("/tmp/#{runner_id}_2", "w")
messages = File.open("/tmp/#{runner_id}_1", "r")
commands.sync = true
commands.puts JSON.generate(command: "connected")
exit 0 if spawns == 1

commands.puts JSON.generate(command: "close", exit_status: nil)
while (line = messages.gets)
  break if line.chomp == "exit"
end
