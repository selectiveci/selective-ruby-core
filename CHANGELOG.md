## [Unreleased]
- Run a node as several worker processes. `--workers N` or `SELECTIVE_WORKERS=N` (`auto` for one per CPU) sets the count; otherwise the framework adapter's own setting applies, and `SELECTIVE_WORKERS=1` turns it off. The command's own process is worker 0: once its suite has loaded it starts the others as fresh `selective` processes, each booting the app itself and connecting as its own runner (`<runner id>-w<index>`). Each worker gets parallel_tests' `TEST_ENV_NUMBER` (`""`, `"2"`, …) and `PARALLEL_TEST_GROUPS` before it boots, plus `SELECTIVE_WORKER_INDEX` and `SELECTIVE_WORKER_COUNT`, so config that reads them while booting works as it does under parallel_tests.
- In a Rails app each worker gets its own test database. A `database.yml` that names databases by `TEST_ENV_NUMBER` is used as is, with worker 0 creating the others' before they boot; otherwise each worker gets `<name>_<index>`. Either way the database is loaded from the schema, as Rails does for `parallelize`, and the app's `parallelize_setup`/`parallelize_teardown` blocks run in each worker, for RSpec suites too.
- Worker 0 waits for the others before its own teardown and report, so coverage merging sees every worker; all workers share one `SIMPLECOV_RUN_ID`. The node exits with the worst worker status and names the workers that failed, were killed or never started. INT and TERM reach every worker, which report the cancellation as a single runner does, and a worker whose worker 0 dies stops itself.
- A process that parallel_tests or turbo_tests started as one of several connects as `<runner id>-p<TEST_ENV_NUMBER>` instead of sharing one runner id. When that tool handed the process a slice of the suite, the runner exits 1 and says to use `--workers` instead, rather than offer Selective a partial manifest.

## [0.3.4] - 2026-11-19
- Support GitLab. On GitLab CI the runner sends `platform=gitlab_ci`, `git_provider=gitlab` and the project path (nested groups included), branch and target branch, the merge request's head commit as `head_sha`, its diff base as `base_sha` (the push's starting commit on branch pipelines), commit title and author, the pipeline id as the run id and `CI_NODE_INDEX` as the runner id. GitLab has no attempt counter, so `run_attempt` is `1`.
- gitlab.com remotes on other CI platforms (RWX/Mint, Buildkite, CircleCI, Semaphore, a local `origin`) now produce the GitLab project path. Self-managed GitLab can't be recognized from a URL outside GitLab CI; set `SELECTIVE_GIT_PROVIDER` and `SELECTIVE_GIT_REPO`.

## [0.3.3] - 2026-11-19
- Bundle transport 0.3.0. When the server offers it, the transport now sends the test manifest over HTTP, as gzip in chunks, instead of as one WebSocket message. Against a server that does not offer it, the transport sends the manifest over the WebSocket as before.

## [0.3.2] - 2026-11-18
- Allow zeitwerk 2.7 and 2.8. The `~> 2.6.12` pin made Rails apps on current zeitwerk downgrade their autoloader to install Selective.
- A test that asserts on binary data no longer kills the runner. Outbound payloads replace invalid UTF-8 with U+FFFD and write NUL as its printable escape; before, one such result stopped the runner and the run recorded nothing.

## [0.3.1] - 2026-11-14
- Send `head_sha`, the commit the branch points at. On GitHub Actions pull requests `sha` is GitHub's merge commit, which exists only in CI; `head_sha` is the pull request's head, so `sel tail` finds the build from a developer's checkout. Elsewhere it equals `sha`. `SELECTIVE_HEAD_SHA` overrides it.

## [0.3.0] - 2026-11-01
- Bundle transport 0.2.0, the first release with `--stdio`. `bin/get_transport` downloads the release tag and checks each archive against a SHA-256 pinned in the script before extracting it. A mismatch prints the asset with the expected and actual hash, deletes the archive, leaves `lib/bin` untouched and exits 1. Building the transport from a commit is gone.
- Platforms: the gem ships a transport binary for `x86_64-linux`, `aarch64-linux`, `x86_64-darwin` and `arm64-darwin`, one platform gem each. The Linux binaries are static musl, so they run on any distribution regardless of its glibc, including Alpine. The plain `ruby` platform gem, which RubyGems installs on any other platform, has no binary: set `SELECTIVE_TRANSPORT` to the path of a transport 0.2.0 or newer, or the runner exits 1 with "Selective transport binary not found".
- Talk to the transport over stdio by default. The runner spawns `transport --stdio` and passes the websocket URL, including the API key, in `SELECTIVE_TRANSPORT_URL` instead of on the process arguments. Server commands and client messages stay one JSON object per line, and a line containing `exit` still shuts the transport down. The transport's stderr is inherited, so its own errors are visible. A binary that cannot run at all exits 1 and shows its own error.
- Breaking: the FIFO transport is gone. Transport 0.2.0 or newer, which supports `--stdio`, is required. A binary without `--stdio` makes the runner exit 1 straight away, and `SELECTIVE_TRANSPORT_FIFO` is no longer read.
- Honor `SELECTIVE_TRANSPORT` as an explicit path to the transport binary.
- Exit promptly on SIGTERM or SIGINT during a stalled test-map upload. The upload's child process is killed instead of waited on for up to its 120 second read timeout.
- Kill a stdio transport that ignores TERM when shutting it down.
- Keep the stdio protocol notes (now `docs/ruby-stdio-protocol-notes.md`) out of the packaged gem.
- Send `terminating` when SIGTERM or SIGINT arrives in the middle of a write. One writer thread sends every frame to the transport's stdin in order. Writes, the signal handler's included, only queue frames, so `terminating` goes out right after the frame the signal interrupted instead of failing to take the pipe.
- Queue server commands that arrive before `connected` and apply them, in order, once `connected` arrives. A command that arrives while a batch is running is still applied only after that batch returns.

## [0.2.15] - 2026-10-23
- Bundle transport 0.1.2:
  - Large test manifests no longer stall on the way to the server. Delivery used to slow down quadratically with message size; an 8 MB manifest now arrives in milliseconds.
  - Linux binaries are static, so they run on any distribution regardless of its glibc, including Alpine and distributions older than glibc 2.28.
  - Messages written just before the runner stops reach the server first, and the connection closes cleanly. Pings from the server no longer reach the runner as unreadable lines.
  - The transport can move its own connection when the server asks, so a runner busy in a long test keeps its run when a server node is replaced. This takes effect once the server supports it; until then nothing changes.

## [0.2.14] - 2026-10-09
- Tell the server when a runner is stopped by SIGTERM or SIGINT. Before exiting, the runner sends a `terminating` message naming the signal, so a run whose runners all leave this way is recorded as cancelled rather than as runners lost, and is shown and counted that way. Servers that predate the message ignore it. The runner waits 0.25s after sending so the transport can deliver it before exiting.

## [0.2.13] - 2026-10-08
- **Breaking:** drop Ruby 2.6 support. `required_ruby_version` is now `>= 2.7.0`, and CI tests every Ruby from 2.7 through 4.0.7 on pull requests.

## [0.2.12] - 2026-10-06
- Fix a runner that ran failing tests exiting 0 when it was sent SIGTERM or SIGINT. The signal handler exited with a bare `exit`; it now exits with the framework's result for the tests this runner has run (non-zero if any failed, 0 otherwise), the same `exit_status` a normal close uses. Tests it had not finished are reassigned to other runners by the server.

## [0.2.11] - 2026-09-29
- Fix a runner that lost its connection once exiting 1 although every test passed. The reconnected session ran inside the rescue of the lost connection, so `$!` was still set when the framework's `after_run` hooks ran, and SimpleCov's treated that as a crashed run. Retries now loop, with `$!` cleared.

## [0.2.10] - 2026-09-29
- Add test maps for test selection. When a suite enables selection, the server asks runners for a content-hash snapshot of the repository (`git ls-tree`, plus hashes of uncommitted edits to tracked files) with the manifest, and on recording runs each test is traced and a fragment uploaded to `/test_maps/fragments` after the run closes. Runners advertise `test_map=record|select|0`.
- Add the optional `selective_tracer` native extension: global line/call/block and allocation hooks that record the project files each test executes, on every thread. Without it (no compiler, unsupported Ruby) the runner can still run selected subsets but can't record.
- Add `SELECTIVE_TEST_MAP_RECORD=1` (force this run to record a map) and `SELECTIVE_TEST_MAP_DISABLE=1` (take no part in selection), plus `SELECTIVE_TEST_MAP_IGNORE` (extra comma-separated directories the tracer ignores).
- Test map fragments are uploaded from a child Ruby process without Bundler's environment, so WebMock, VCR and other HTTP stubs loaded by the suite can't block the upload.
- Installing the gem now needs `make`, since it carries a native extension. The tracer is compiled once while configuring, and any failure there (no C compiler, unsupported Ruby, compile error) installs without it rather than failing the install.
- `selective exec` no longer requires the CI environment variables: the runner id and logger are resolved when a run starts, not in the constructor.
- Fix the Gemfile's sibling-repo check to resolve relative to the Gemfile instead of the current directory.

## [0.2.9] - 2026-05-03
- Add `git_repo_full_name`, `git_provider`, and `base_sha` to run metadata (GitHub Actions, CircleCI, Semaphore, Buildkite, RWX/Mint). Supports explicit `SELECTIVE_GIT_REPO` / `SELECTIVE_GIT_PROVIDER` / `SELECTIVE_BASE_SHA` overrides and a git-remote fallback for the slug. `base_sha` is extracted from GitHub Actions event payload (both PR and push events) and from Semaphore's `SEMAPHORE_GIT_COMMIT_RANGE`. Fields are emitted as empty strings when unresolvable; the server side is responsible for enforcing presence when billing requires it.
- Add Buildkite as a recognized CI platform.

## [0.2.8] - 2025-06-03
- Update metadata to align with Mint's rename to RWX

## [0.2.7] - 2025-06-03
- Add ruby release without compiled transport included

## [0.2.6] - 2025-04-29
- Support manifest with test cases

## [0.2.5] - 2024-05-25
- Add first-class support for [Mint](https://www.rwx.com/mint)!

## [0.2.4] - 2024-02-28
- Bugfix quotes in env configuration (such as PR titles)
- Ship transport v0.1.1: https://github.com/selectiveci/transport/releases/tag/v0.1.1

## [0.2.3] - 2024-02-06

- Fix a bug in the file correlator where test files were being correlated to test files
- Fix a bug where the reconnect parameter would never be set upon reconnect
- Increase max number of reconnect/retries from 4 -> 10
- Implement "report at finish" for debug purposes

## [0.2.2] - 2024-01-26

- Pass test case callback to runner

## [0.2.1] - 2024-01-19

- Add Semaphore support

## [0.2.0] - 2024-01-12

- Add committer information to build_env

## [0.1.9] - 2024-01-12

- Bugfix for issue that could cause runner to hang
- Implement basic configuration validation

## [0.1.8] - 2024-01-05

- Fix a minor bug causing the "unable to correlate" warning

## [0.1.7] - 2024-01-05

- PR diff / test-file correlation for smarter test ordering

## [0.1.6] - 2024-01-03

- Upgrade to Ruby 3.3
- Add explicit support for CircleCI
- Refactor controller
- Send version information in connection parameters

## [0.1.5] - 2023-12-08

- Bugfix for zeitwerk when eager loading is enabled
- Increase the time before failure when connection is not made

## [0.1.4] - 2023-12-05

- Always prefer selective env-vars (allow overriding CI provider vars)
- Fix bug where some runner_id's could cause an error

## [0.1.3] - 2023-11-20

- Get run_id and run_attempt from build env if possible
- Misc housekeeping/test/release script updates

## [0.1.2] - 2023-11-10

- Fix modified_test_files
- Implement generic "print_notice" message
- Disable logging by default & add --log flag

## [0.1.1] - 2023-11-03

- Implemented release scripts
- Updated Readme

## [0.1.0] - 2023-10-26

- Initial release
