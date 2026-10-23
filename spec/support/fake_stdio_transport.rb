#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"

$stdout.sync = true
$stderr.sync = true

if ARGV.include?("--help")
  puts "transport --stdio"
  exit 0
end

mode = ENV.fetch("SELECTIVE_FAKE_MODE", "close")
directory = ENV.fetch("SELECTIVE_FAKE_DIR")
FileUtils.mkdir_p(directory)

def next_count(path)
  File.open(path, File::RDWR | File::CREAT, 0o644) do |file|
    file.flock(File::LOCK_EX)
    value = file.read.to_i + 1
    file.rewind
    file.write(value.to_s)
    file.truncate(file.pos)
    value
  end
end

count = next_count(File.join(directory, "count"))
stdin_lines = []
state = {
  "pid" => Process.pid,
  "count" => count,
  "argv" => ARGV,
  "cmdline" => (
    if File.exist?("/proc/self/cmdline")
      File.read("/proc/self/cmdline").split("\0")
    else
      [RbConfig.ruby, $PROGRAM_NAME, *ARGV]
    end
  ),
  "url" => ENV["SELECTIVE_TRANSPORT_URL"],
  "stdin" => stdin_lines
}
report_path = File.join(directory, "#{Process.pid}.json")

def emit(command)
  $stdout.puts JSON.generate(command)
end

def persist(path, state)
  File.write(path, JSON.generate(state))
end

persist(report_path, state)

def record(path, state, stdin_lines, line)
  stdin_lines << line
  state["stdin"] = stdin_lines
  persist(path, state)
end

def read_until_exit(path, state, stdin_lines)
  while (line = $stdin.gets)
    text = line.chomp
    record(path, state, stdin_lines, text)
    return if text == "exit"

    begin
      yield JSON.parse(text)
    rescue JSON::ParserError
      next
    end
  end
end

case mode
when "refuse"
  exit 1
when "ignore_exit"
  trap("TERM") { exit! 0 }
  sleep 30
when "flood"
  4000.times { emit({command: "print_notice", message: "x"}) }
  read_until_exit(report_path, state, stdin_lines) { |_message| }
when "stderr"
  warn "transport log {not-json}"
  emit({command: "connected"})
  emit({command: "close", exit_status: nil})
  read_until_exit(report_path, state, stdin_lines) { |_message| }
when "die_after_connected"
  emit({command: "connected"})
  if count == 1
    exit 0
  else
    emit({command: "close", exit_status: nil})
    read_until_exit(report_path, state, stdin_lines) { |_message| }
  end
when "reconnect"
  emit({command: "connected"})
  if count == 1
    emit({command: "reconnect"})
  else
    emit({command: "close", exit_status: nil})
  end
  read_until_exit(report_path, state, stdin_lines) { |_message| }
when "before_connected"
  emit({command: "test_manifest"})
  if IO.select([$stdin], nil, nil, 0.2)
    record(report_path, state, stdin_lines, $stdin.gets.to_s.chomp)
    state["early_write"] = true
    persist(report_path, state)
    exit 2
  end
  emit({command: "connected"})
  unless IO.select([$stdin], nil, nil, 2)
    state["manifest_missing"] = true
    persist(report_path, state)
    exit 2
  end
  read_until_exit(report_path, state, stdin_lines) do |message|
    if message["type"] == "test_manifest"
      emit({command: "close", exit_status: nil})
    end
  end
when "topup"
  emit({command: "connected"})
  emit({command: "run_test_cases", test_case_ids: ["a", "b"]})
  topped_up = false
  closed = false
  read_until_exit(report_path, state, stdin_lines) do |message|
    next unless message["type"] == "test_case_result"

    id = message.dig("data", "id")
    if id == "a" && !topped_up
      emit({command: "run_test_cases", test_case_ids: ["c"]})
      topped_up = true
    elsif id == "c" && !closed
      emit({command: "close", exit_status: nil})
      closed = true
    end
  end
when "remove_during"
  emit({command: "connected"})
  emit({command: "run_test_cases", test_case_ids: ["bad"]})
  removed = false
  closed = false
  read_until_exit(report_path, state, stdin_lines) do |message|
    next unless message["type"] == "test_case_result"
    next unless message.dig("data", "id") == "bad"

    if !removed
      emit({command: "remove_failed_test_case_result", test_case_id: "bad"})
      emit({command: "run_test_cases", test_case_ids: ["bad"]})
      removed = true
    elsif !closed
      emit({command: "close", exit_status: nil})
      closed = true
    end
  end
else
  emit({command: "connected"})
  emit({command: "close", exit_status: nil})
  read_until_exit(report_path, state, stdin_lines) { |_message| }
end
