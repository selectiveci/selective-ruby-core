# Agent rules

These rules come from the 2026-10-22 simplicity review of PR 80 at `c2ff5fd`. The check is `bash bin/simplicity-check`. CI runs that same command in the `simplicity` job of `.github/workflows/main.yml`.

| Rule | Enforced by | Command | Review finding |
| --- | --- | --- | --- |
| Do not implement a timer by polling `Process.clock_gettime` or `Process::CLOCK_MONOTONIC` inside a loop that also sleeps. Sleep the full duration with `Kernel.sleep(seconds)` on a thread and cancel that thread with `Thread#kill`. | RuboCop `Selective/SleepPollTimer` | `bash bin/simplicity-check` | Finding 3. `lib/selective/ruby/core/controller.rb` `arm_connectivity_watchdog` (generation counter plus a 0.2s poll). The reviewed source is in `simplicity/red/`. |
| Specs change environment variables only through `with_env` in `spec/helper_methods.rb`. Direct `ENV[]=`, `ENV.store`, `ENV.update`, `ENV.delete`, `ENV.clear`, and `ENV.replace` under `spec/` are rejected outside that method. | `with_env`, plus RuboCop `Selective/DirectEnvAssign` | `bash bin/simplicity-check` | Finding 1. Hand-rolled ENV save/restore in `controller_spec.rb`, `stdio_transport_spec.rb`, `stdio_controller_spec.rb`, and `stdio_binary_spec.rb`. |
| A generation counter that is not a sleep-poll, a connectivity flag read by a detached thread instead of `Thread#kill`, hand-rolled `return @x if @x` memoization, trailing-comma destructure, a fake `cmdline` built from `ARGV`, and `sleep((retries > 4) ? 4 : retries)` | not enforced | | Findings 3, 5, 8, and 15. These are judgment calls. A cop cannot separate them from legitimate code, and Ruby has no type that forbids them. |

`bash bin/simplicity-check` fails on `simplicity/red/` (the reviewed files) and passes on `simplicity/green/` (the review's replacement) and on the rest of the tree. A short `sleep` that waits for a pipe or a process, with no monotonic clock in the loop, is not this timer. `next sleep(0.1) if message.nil?` and `100.times { Kernel.sleep(0.05) }` stay legal.
