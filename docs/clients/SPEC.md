# Selective client contract

Status: design, October 2026. This is the contract a new language client implements. It is taken from the Ruby client that ships today (`selective-ruby-core` 0.2.14, `selective-ruby-rspec`, `selective-ruby-minitest`), the Rust process in `selectiveci/transport`, and the Elixir server (`RunnerSocket`, `SocketCommand`, `SocketMessage`, `docs/test-selection.md`).

No new client opens its own WebSocket. The only WebSocket implementation is the Rust crate in `selectiveci/transport`. A client is a binding to that crate plus a thin test-framework adapter. See [Transport binding](#transport-binding).

## Parity bar

Every row in the matrix below is **required**. A repository that implements a subset is not a Selective client, and it does not ship. The server hands out test-case ids. The client runs exactly those ids, in a process that stays up (the application and the framework booted once), reports each result, and waits for the next batch. Retries of an id run again in that same process and replace the earlier local result. Group hooks the author wrote as once-per-group run again for every assigned test, including a later batch in the same process. The test-map fragment, when recording is on, covers setup, the body, and teardown of each id.

These are outside the contract. They are not a first version and they are not a fallback:

- A manifest whose id is a file path.
- A static split computed at launch: `jest --shard`, `vitest --shard`, `mix test --partitions`, pytest-split, ParaTest or `pest --parallel` as the scheduler, Knapsack Pro's `runCLI` per batch, `mvn -Dtest=` or Gradle `--tests` per batch.
- A mode that runs whole files when per-test execution is inconvenient.

The citations are the code that ships. `selective-ruby-core` is this repository. `selective-ruby-rspec` and `selective-ruby-minitest` are the adapters. Language notes map each id to a mechanism and a rating: proven, feasible with risk, or blocked.

| Id | Required behavior | Where Ruby does it |
|---|---|---|
| P1 | Stay in one process. Wait for `run_test_cases`, run those ids, report, wait for more. An id the process already ran is run again. | `Controller#run_main_loop`, `#handle_run_test_cases`. `Selective::Ruby::RSpec::RunnerWrapper#run_test_cases` (`rspec_runner.run_specs`). `Selective::Ruby::Minitest::RunnerWrapper#run_test_cases` (`run_one_method` or `Runnable.run`). |
| P2 | The id is stable across a line shift and is byte-for-byte the same on the manifest, the assignment, and the result. The server does not sanitize it. | RSpec `example.id` in `RunnerWrapper#format_example`. Minitest `file_path` plus `MD5(Class#method)` in `RunnerWrapper#configure`. |
| P3 | Discover every test the command would have run, without executing bodies. An empty suite prints why and exits 1. | RSpec `RunnerWrapper#manifest`: `selective exec rspec --format=json --dry-run`, `TestManifestError` when `examples` is empty. Minitest loads the files once and enumerates `runnable_methods`; empty `test_ids` raises `TestManifestError`. |
| P4 | The server asks one connected runner. Every shard must be able to answer, including after a reconnect, so collection is cached in the process. | `Controller#handle_test_manifest`. |
| P5 | Send `test_case_result` as each test finishes, during the batch. | `Controller#test_case_callback`. RSpec `Formatter` on `example_passed`, `example_failed`, `example_pending`, calling `report_example`. Minitest calls the callback inside `run_test_cases` after each method. |
| P6 | Status is `passed`, `failed`, or `pending`. `passed` and `pending` count as a pass. A skip of a test the server assigned is `pending`. Unassigned tests are not reported. | RSpec `execution_result.status`. Minitest `format_test_case`: `skipped?` becomes `pending`. |
| P7 | On failure, send `failure_message_lines` and `failure_formatted_backtrace`. The first frame is a repo-relative project frame, because the server's systemic-failure filter only strips Ruby library paths. Strip NUL bytes from descriptions and failure text. | RSpec `failure_formatter` (`ExceptionPresenter`). Minitest `format_test_case` (`failure.to_s`, `failure.failures.first.backtrace`). |
| P8 | A retry that lands on the same runner replaces the earlier attempt in local reporters, statistic counters, and the exit status. The server does not send `remove_failed_test_case_result` in that case; deleting the result would erase the attempt that just failed. | RSpec `Reporter#example_started` deletes the example from `@examples`, `@failed_examples`, and `@pending_examples` when `started_at` is already set. Minitest `discard_previous_results` and `forget_statistics` (JUnit XML and `count` / `assertions`). |
| P9 | `remove_failed_test_case_result` from a different runner drops that failure so a later exit can be 0. The match is the precise test. An unknown id is ignored. | `Controller#handle_remove_failed_test_case_result`. RSpec `remove_test_case_result` matches `example.id`. Minitest `same_test?` matches class and method name together, so two tests that share a method name do not clear each other. |
| P10 | Commands that arrive during a batch are applied. Ruby leaves them on the FIFO and handles them when the batch returns; a concurrent reader is equivalent. A lost connection while a result is being sent aborts the batch, forgets that result so it can be reassigned, and reconnects outside the exception handler. Coverage hooks that read `$!` otherwise fail the process. | RSpec `Formatter` rescues `ConnectionLostError`, sets `wants_to_quit` and `connection_lost`, and calls `remove_test_case_result`. `RunnerWrapper#run_test_cases` then raises. `Controller#start` retries in a loop around `connect_and_run`, not inside the rescue. |
| P11 | Reconnect with `reconnect=true`. Sleep `min(attempt, 4)` seconds. The 11th failure exits 1. Recording stays latched, and traces already collected stay in memory. | `Controller#prepare_retry!`, `#handle_reconnect`. `TestMap.configure` keeps `@recorder` for the life of the process. |
| P12 | On `SIGINT` or `SIGTERM`, send `terminating` with the signal, wait 250 ms, close the session, and exit with the status of tests this process has already finished. A runner that has not failed anything exits 0. | `Controller#report_termination`, `TERMINATION_REPORT_GRACE`, `#handle_termination_signals`, `runner.exit_status`. |
| P13 | `close` with an integer `exit_status` skips finish hooks and is the process status. `null` runs finish hooks and exits with the framework status. Then send `report_at_finish` with `connection_retries` at least. | `Controller#handle_close`. |
| P14 | Suite hooks run once per process. Finish hooks run once, and are skipped when `exit_status` is an integer. | RSpec `Configuration#with_suite_hooks` (`@before_suite_hooks_run`) and `#after_suite_hooks`; `RunnerWrapper#finish`. Minitest `selective_prerun` / `selective_postrun` (the two halves of `Minitest.run`) and `@@after_run` in `finish`. |
| P15 | A hook the author wrote as once-per-group runs for every assigned test, including a test from a later batch in the same process. | RSpec `Hooks` rewrites `:all` to `:each` for `before`, `prepend_before`, `after`, and `append_after` at definition time. `--require-each-hooks` raises if `:all` is used (`RequireEachHooks`). Minitest `setup` / `teardown` are already per method, and `run_one_method` invokes them. |
| P16 | Time spent inside those rewritten group hooks is included on `report_at_finish` as `seconds_in_{hook}_all_hooks`. The server logs the hash and does not branch on it. | RSpec `Hooks`, accumulated on `Controller.report_at_finish`. |
| P17 | A file that is already loaded is not loaded again. | RSpec `Configuration#get_files_to_run` rejects `loaded_spec_files`. Minitest `configure` requires each file once. |
| P18 | The framework's own paths, filters, and flags still bound discovery. The default path is the framework's default. A plain invocation that does not connect (`selective exec`) does not require the CI environment. | RSpec `parse_args`, `DEFAULT_SPEC_PATH` (`./spec`), default `--format=progress`. Minitest `parse_args`, `DEFAULT_TEST`, `INCLUDE_PATTERN`, `EXCLUDE_PATTERN`. `Controller#exec`; `#runner_id` is resolved on first connect, not in the constructor. |
| P19 | Per-test formatter output stays quiet until finish. A profiler that assumes one local run is turned off. Listener registration does not duplicate an output path. | `Controller.suppress_reporting!` / `restore_reporting!`. RSpec formatter monkeypatches (`MAP`) no-op `message`, `dump_pending`, `seed`, `close`, `start_dump`, `dump_profile`. `Reporter#finish` clears `profile_examples`. `Reporter#register_listener` skips a listener whose output path is already registered. Minitest calls `reporter.report` inside `selective_postrun`. |
| P20 | Exit status is 1 only when a remaining result is a hard failure. Skips do not fail the process. | RSpec `exit_status`: on 3.10+ `Runner#exit_code` with `failed_examples.none?`; otherwise `failed_examples.any?`. Minitest `exit_status` uses `failures.reject(&:skipped?)`. |
| P21 | If the framework has an in-process parallel executor, start it and shut it down the way its own runner does, and do not crash when the executor has no `start` (Minitest with `MT_CPU=1`). When the tracer cannot attribute concurrent tests to one id, run the assigned ids one at a time in the same warm process. The ids are still the ones the server sent. | Minitest `selective_prerun` / `selective_postrun` (`parallel_executor.start` / `shutdown` only if the method exists). RSpec runs the assigned example groups through `run_specs` in this process. |
| P22 | Two tests that would share an id are both still listed. Warn, and disambiguate the second id. A dropped id is a test the server never assigns. | Minitest `configure` warns on a duplicate `Class#method` digest and, today, keeps only the first. New clients keep both. RSpec `example.id` is unique per example. |
| P23 | When `configure_test_map` says `tree: true`, the manifest includes `test_map_tree` from the git snapshot algorithm. A non-checkout omits the tree and the run selects nothing. | `Controller#handle_test_manifest`, `TestMap::Tree.snapshot`. |
| P24 | `modified_test_files` is the diff against the target branch, limited to the suite root, and affects order only. A missing branch, a failed fetch, or a failed diff warns and omits the field. | `Controller#get_diff`, `#modified_test_files` (paths matching `runner.base_test_path`). |
| P25 | When a diff exists, send `correlated_files`: co-change counts of this suite's test files across recent commits on the target branch. A failed correlation warns and omits the key. Selection does not read the field. | `Controller#correlated_files`, `FileCorrelator#correlate`. `lib/bin/file_correlation_collector.sh` only matches `spec/*_spec.rb`, so a Minitest run records an empty hint. New clients point the same count at their own test glob. |
| P26 | `configure_test_map` may arrive twice. `record: true` latches for the process. If the server asks for a recording and the tracer is missing, warn once and keep running. Ignore the Ruby-only `allocations` key. | `Controller#handle_configure_test_map`. `TestMap.configure`. |
| P27 | Advertise `test_map` as `record`, `select`, or `0`. Forward `SELECTIVE_TEST_MAP_RECORD` unchanged. `SELECTIVE_TEST_MAP_DISABLE` of `1`, `true`, or `yes` forces `0`. | `TestMap.capability`, `TestMap.disabled?`, `Controller#base_transport_url_params`. |
| P28 | While recording, trace setup, the body, and teardown of each assigned id. A dependency seen on any attempt is kept (union). Honor `SELECTIVE_TEST_MAP_IGNORE`. Ignore installed dependencies and this client's own code. | `TestMap.around`. RSpec `Example#run` wraps the whole example. Minitest `with_test_map` wraps `run_test`, which includes `setup` / `teardown`. `Recorder#record`, `FORMAT_VERSION` 1. `Tracer` applies the ignore list. |
| P29 | After `close`, POST the gzip fragment to `/test_maps/fragments` from outside the test process, so HTTP stubs cannot swallow it. Header `authorization` is the raw key. Retry 3 times. Failure warns and does not change the test exit status. | `Controller#upload_test_map`. `TestMap::Uploader` `PATH`, `ATTEMPTS`, `SELECTIVE_TEST_MAP_UPLOAD_KEY`, `CLEAN_ENV` child. |
| P30 | Every connection sends the identity query parameters, including `language`, `core_version`, `framework`, `framework_version`, `framework_wrapper_version`, `runtime_version`, `test_map`, and `test_map_record`. | `Controller#base_transport_url_params`. RSpec `framework` / `framework_version` / `wrapper_version`. Minitest equivalents on `RunnerWrapper`. |
| P31 | An unknown command is ignored. Raise only under `--debug`. | `Controller#handle_command`. |
| P32 | Loading the suite must not autorun it or exit the process. The session loop owns the lifecycle. Plugins still initialize. | Minitest `autorun` is a no-op because Rails calls it from `active_support`. `selective_prerun` still `load_plugins` and `init_plugins` (skipped on Minitest 6+). RSpec is built with `Runner.new` and `setup`, and runs only when `run_test_cases` says so. |

`report_at_finish` may also carry adapter diagnostics beyond P16. The server logs them.

## What the Ruby client actually is

Two different native pieces get conflated. They stay separate in every new language.

| Piece | What it is | Role |
|---|---|---|
| `lib/bin/transport` | A Rust **sidecar binary** from `selectiveci/transport`. Not a Ruby extension. | The WebSocket. Ruby spawns it and talks newline-delimited JSON over two POSIX FIFOs. |
| `selective_tracer` | An optional **C extension** compiled when the gem installs. | Test-map recording only. Hooks Ruby line, call, and allocation events. If it fails to build, the gem still installs and the runner advertises `test_map=select`. |

The FIFOs are `/tmp/{runner_id}_1` (client writes, transport reads) and `/tmp/{runner_id}_2` (transport writes, client reads). The transport is started as `transport <websocket-url> <runner_id>`. A line whose contents are `exit` stops the process and is not forwarded. Each WebSocket text frame is one JSON object; the sidecar adds a trailing newline on the way to the client. The URL today carries the API key in the query string, so it is visible in the process list. New bindings must not put the key on `argv` (see [Sidecar IPC](#sidecar-ipc)).

Ruby keeps this FIFO mode until it is migrated. Every new client uses either an in-process binding or the stdio sidecar below. Nobody reimplements `tokio-tungstenite`.

## Transport binding

`selectiveci/transport` becomes a library crate with one session type, plus the existing CLI. The CLI and the in-process bindings are two faces of that type.

```text
Session.connect(url) -> Session
Session.recv()       -> one text frame (a JSON command)
Session.send(frame)  -> one text frame (a JSON message)
Session.close()
snapshot_tree(cwd)   -> test_map_tree JSON, or unavailable
upload_fragment(...) -> POST the gzip body, best-effort
```

`snapshot_tree` and `upload_fragment` live in Rust too. Git hashing and the upload HTTP call are not language-specific, and the upload must run outside a test process that stubs HTTP (WebMock, VCR, `responses`, `nock`, WireMock). The Ruby uploader already forks a clean child for that reason.

The crate keeps `rustls` with the OS certificate store (`rustls-tls-native-roots`). Do not switch it to OpenSSL. Musl builds must still read the system CA bundle at runtime (Alpine has `ca-certificates`).

### Which face a language uses

| Language | Binding | Why |
|---|---|---|
| Elixir | Erlang **Port** to the stdio sidecar | A long-lived Tokio runtime inside a NIF fights the BEAM scheduler. Rustler's async-NIF work is still an unstable API. A Port is supervised, crash-isolated, and is the same binary Ruby already runs. IPC cost is noise next to a test. |
| Python | **PyO3 / maturin** wheel, stdio sidecar if the wheel will not load | cibuildwheel is the normal way to ship a native module. In-process avoids a Windows FIFO problem. PyPy, Pyodide, and a missing musl wheel fall back to the sidecar. |
| JavaScript | **napi-rs** `.node` with per-target `optionalDependencies`, stdio sidecar if `dlopen` fails | The same pattern as swc and rolldown. Windows developers are common, and POSIX FIFOs do not exist there. |
| PHP | **stdio sidecar only** | `ext-php-rs` means one `.so` per PHP minor, per ZTS/NTS, per arch, and a compiler on the CI image. `ext-ffi` is often disabled (`ffi.enable=false`). PHPUnit already runs as a process that can spawn a helper. |
| Java | **stdio sidecar only** | A Rust panic across JNI aborts the JVM and drops results. The Panama FFM API is stable on JDK 22 and later; suites still run on 17 and 21. Maven Central native classifiers are a distribution project of their own. |

Per-language tradeoffs, package names, and CI matrices are in the language notes and in [PLAN.md](PLAN.md). A client that cannot load its chosen face exits 1 with the target triple and the download URL. It does not open a WebSocket of its own, and it does not silently run the suite outside Selective.

### Sidecar IPC

New mode, beside the legacy FIFO invocation:

```text
SELECTIVE_TRANSPORT_URL=wss://... transport --stdio
```

- The URL, including the API key, comes from the environment, never from `argv`.
- stdin carries client messages, one JSON object per line. The line `exit` shuts the process down and is not forwarded.
- stdout carries server commands, one JSON object per line. The transport writes no other stdout. Logs go to stderr.
- stderr is the transport's own diagnostics.
- The process exits 0 after `exit` or a WebSocket close, and exits 1 if it never connects.

`transport --snapshot` writes the `test_map_tree` object to stdout, or exits non-zero when the working directory is not a git checkout. `transport --upload-fragment` reads a gzip body on stdin and POSTs it. The API key for the upload is `SELECTIVE_TEST_MAP_UPLOAD_KEY` (the same split Ruby uses, so the key is not on the command line). Query parameters are `run_id`, `run_attempt`, and `runner_id`.

### Prebuilt binaries

The release workflow already publishes four glibc/macOS archives from an old glibc (ubuntu-20.04) so the binary runs on newer distros. Extend that matrix. Do not build only on the newest Ubuntu.

| Target | Who needs it |
|---|---|
| `x86_64-unknown-linux-gnu` | Everyone. Already shipped. |
| `aarch64-unknown-linux-gnu` | Everyone. Already shipped. |
| `x86_64-apple-darwin` | Local development. Already shipped. |
| `aarch64-apple-darwin` | Local development. Already shipped. |
| `x86_64-unknown-linux-musl` | Alpine and distroless images. Add before Python or Java ship. |
| `aarch64-unknown-linux-musl` | Graviton Alpine. Add with the musl target above. |
| `x86_64-pc-windows-msvc` | Node and Python local development. Add with those clients. |
| `aarch64-pc-windows-msvc` | Not a v1 target. |

Ruby consumers keep the four archives named `transport-{Linux,Darwin}-{x86_64,aarch64}.tar.gz`. New archives follow the same naming with `Linux-musl-*` and `Windows-x86_64`.

Checksum every download. Cache the binary under the language's usual store (`priv/` for Mix, the wheel or `optionalDependencies` for Python and Node, `~/.selective/transport/<version>/` for PHP and Java) and honor `SELECTIVE_TRANSPORT` as an explicit path.

### Load failure

1. In-process binding, when this language has one: load it.
2. On a missing module, an ABI mismatch, or a failure during connect setup, spawn `transport --stdio` for this triple.
3. If that binary is missing or exits before `connected`, print the triple and the release URL and exit 1.
4. Test-map recording is a separate capability. If the language tracer is unavailable, advertise `test_map=select`, warn once, and keep running. A failed fragment upload warns and does not fail the build. A missing test is always run.

## Wire protocol

Endpoint, default host `wss://app.selective.ci`:

```text
{host}/transport/websocket?{query}
```

`host` must start with `ws://` or `wss://`. The HTTP origin for uploads is the same host with `ws` replaced by `http`.

Query parameters:

| Parameter | Source |
|---|---|
| `api_key` | `SELECTIVE_API_KEY` |
| `run_id` | CI run id |
| `run_attempt` | CI attempt |
| `runner_id` | This shard's stable id |
| `reconnect` | `true` on a resumed connection. Omit otherwise. |
| `language` | `elixir`, `python`, `php`, `javascript`, `java`, … |
| `core_version` | Client core version |
| `framework` | `exunit`, `pytest`, `phpunit`, `pest`, `jest`, `vitest`, `junit`, … |
| `framework_version` | The test framework's version |
| `framework_wrapper_version` | This adapter's version |
| `runtime_version` | Language runtime version (`3.12.1`, `1.17.0`, `21.0.1`) |
| `test_map` | `record`, `select`, or `0` |
| `test_map_record` | The raw `SELECTIVE_TEST_MAP_RECORD` value, or empty |
| `metadata` | JSON object of the rest of the build environment (below) |

The server stores the identity parameters on the run by merging them into `metadata`. Maps are keyed by language, runtime, and framework (`ruby-3.3/rspec` is a different map from `ruby-3.4/rspec`). Send all three on every connection.

The first server frame is `{"command":"connected"}`. Wait up to 30 seconds. If some other command arrives first, queue it and keep waiting. Exit 1 if `connected` never arrives.

Frames are JSON objects, one per WebSocket text message. Field names are strings. Unknown commands are ignored (Ruby raises only under `--debug`). A client must keep reading while a test batch runs, because `remove_failed_test_case_result`, `print_message`, and `reconnect` arrive between results.

### Session lifecycle

```text
resolve env
  -> connect
  -> connected
  -> configure_test_map          (optional, may repeat)
  -> test_manifest               (server asks)
  -> test_manifest reply         (client sends the suite)
  -> run_test_cases              (zero or more batches)
       test_case_result          (one per finished test, as it finishes)
       remove_failed_test_case_result   (when a different runner reran a failure)
  -> close
  -> report_at_finish
  -> framework finish hooks, unless close.exit_status is an integer
  -> upload test-map fragment, if any tests were recorded
  -> close the session
  -> exit
```

Selection does not block the queue. The server enqueues every manifest test immediately, then drops the ones selection can skip if a runner has not taken them yet. A client just runs the ids it is given.

`reconnect`, or a dropped pipe, tears the session down and connects again with `reconnect=true`. Do this in a loop, not inside the exception handler of the dead session: coverage hooks that inspect the current exception will otherwise fail the process. Sleep `min(attempt, 4)` seconds between attempts. Give up after 10 failed reconnects (the 11th failure exits 1). A recording session stays in record mode across reconnects; do not discard traces already collected.

On `SIGINT` or `SIGTERM`:

1. Send `{"type":"terminating","data":{"signal":"TERM"}}` (or `INT`).
2. Wait 250 ms so the frame leaves the socket. CI sends `SIGKILL` a few seconds after `SIGTERM`.
3. Close the session.
4. Exit with the framework status of the tests this process has already finished: 1 if any of them are still failed, 0 if none have failed. Unfinished tests are reassigned. A runner that has not run anything exits 0.

### Server commands

`connected`

```json
{"command":"connected"}
```

`print_notice` and `print_message`

```json
{"command":"print_notice","message":"..."}
{"command":"print_message","message":"..."}
```

Print both to stdout. `print_notice` is informational (a banner is fine once). `print_message` is a warning. Auth and billing failures arrive as a notice plus `close`.

`configure_test_map`

```json
{"command":"configure_test_map","tree":true,"record":false}
```

`tree: true` means the next manifest must include `test_map_tree`. `record: true` means every test this process runs is traced, including setup and teardown. Recording latches on for the life of the process. The Ruby field `allocations` is a Ruby tracer hint; other clients ignore it. The server may send `tree` first and `record` later.

`test_manifest`

```json
{"command":"test_manifest"}
```

Reply with a client message (below). Discover the suite before answering. An empty suite is an error: print why and exit 1.

The server asks one connected runner (the first open socket it sees) and remembers that pid. Every shard must be able to answer, because any of them can register first. The other shards only receive `run_test_cases`. A reconnect can make a different runner the one who is asked, so keep the collection cached in the process rather than assuming a single manifest role.

`run_test_cases`

```json
{"command":"run_test_cases","test_case_ids":["id-a","id-b"]}
```

Run these ids, in order, in this process. Report each result as the test finishes, not at the end of the batch. An id may already have been run in this process (auto-retry or a manual rerun). Run it again. Drop the previous attempt from local reporters before the new attempt, so JUnit XML and exit status describe only the latest one.

The server fills a buffer. More batches arrive after results. Do not exit between batches.

`remove_failed_test_case_result`

```json
{"command":"remove_failed_test_case_result","test_case_id":"id-a"}
```

A different runner has rerun this failure. Remove it from this process's failure set so a later exit can be 0. The server does **not** send this when the rerun landed on the same runner; deleting the result there would erase the attempt that just failed. Ignore an id this process does not have.

`reconnect`

```json
{"command":"reconnect"}
```

Drop the socket and connect again with `reconnect=true`. Keep the in-memory manifest and any recorded traces.

`close`

```json
{"command":"close","exit_status":null,"error_code":"invalid_api_key","message":"..."}
```

`exit_status` is either an integer or null. An integer overrides the framework status and skips finish hooks (the process is being rejected before a real run). Null means run finish hooks and exit with the framework status. `error_code` and `message` are optional; print `message` when it is present. Known codes include `invalid_api_key`, `billing_issue`, and `run_unavailable`. The integer is what the process exits with.

Then send `report_at_finish`, upload a fragment if one exists, and exit. `report_at_finish` is diagnostic. The server logs it and does not branch on it. Include `connection_retries` at least.

### Client messages

`test_manifest`

```json
{
  "type": "test_manifest",
  "data": {
    "test_cases": [
      {
        "id": "tests/test_billing.py::test_tax",
        "file_path": "tests/test_billing.py",
        "line_number": 40,
        "description": "test_tax",
        "full_description": "test_tax",
        "run_time": 0.0
      }
    ],
    "test_map_tree": {},
    "modified_test_files": ["tests/test_billing.py"]
  }
}
```

`id` is the only field the server uses to match assignments, results, and stored rows. It must be identical across the manifest, `run_test_cases`, and `test_case_result`, including spelling: the server will not sanitize it, and a rewritten id never leaves the assigned set, so the run never finishes. Prefer a framework-native id that survives a line shift (pytest node id, `Class#method`, Jest's full name, a JUnit unique id, ExUnit's module and test name). A line-based id is safe but noisy: moving a test changes the file blob, so the test runs again and looks new.

`file_path` is relative to the working directory of the command, not the git root. `run_time` on the manifest may be 0.

`test_map_tree` is required when `configure_test_map` said `tree: true`, and omitted otherwise. Shape:

```json
{
  "sha": "HEAD sha",
  "prefix": "services/api/",
  "files": {"path/from/repo/root": "git blob sha"},
  "dirty": ["tracked paths with uncommitted edits"]
}
```

`prefix` is the working directory relative to the git root, with a trailing slash, or `""` at the root. The server uses it to line manifest paths up with tree paths. `files` is every tracked file: `git ls-tree -r -z --full-tree HEAD`, mode and type ignored, blob id kept. Then fold uncommitted edits to **tracked** files: `git status --porcelain=v1 -z --untracked-files=no --no-renames`. Deleted paths leave the map. Other dirty tracked paths are replaced with `git hash-object` of the working-tree bytes. Untracked files are left out on purpose (logs and coverage output would look like a change and run the whole suite). If this is not a git checkout, omit the tree and the run selects nothing (it runs everything). Do not reimplement this per language; call `snapshot_tree`.

`modified_test_files` is optional and only affects order. It is the paths from `git diff origin/{target_branch} --name-only` that sit under the suite's test root. A missing target branch, a failed fetch, or a shallow clone that cannot see the branch produces a warning and the field is omitted. Selection does not use it.

`correlated_files` is required when a diff exists (P25). It is an ordering hint: co-change counts of this suite's test files across recent commits on the target branch. The Ruby collector only matches `spec/*_spec.rb`, which is why Minitest currently sends an empty hint. New clients run the same count against their own test glob. A failed correlation warns and omits the key. Selection does not use the field.

`test_case_result`

```json
{
  "type": "test_case_result",
  "data": {
    "id": "tests/test_billing.py::test_tax",
    "description": "test_tax",
    "full_description": "billing tax is rounded",
    "status": "failed",
    "file_path": "tests/test_billing.py",
    "line_number": 40,
    "run_time": 0.084,
    "pending_message": null,
    "failure_message_lines": ["AssertionError: expected 2"],
    "failure_formatted_backtrace": ["tests/test_billing.py:42: in test_tax"]
  }
}
```

`status` is `passed`, `failed`, or `pending`. `passed` and `pending` count as a pass. Anything else counts as a failure and is eligible for server-side auto-retry. A framework skip of a test the server assigned is `pending`, not a missing result. Do not report tests the server did not assign.

`run_time` is seconds. `failure_message_lines` and `failure_formatted_backtrace` are present on failure. The server's systemic-failure grouping takes the **first** backtrace frame that does not look like a Ruby library path. That filter is Ruby-specific (`/gems/`, `/rubies/`, `/lib/ruby/`). Put a repo-relative project frame first so a shared setup failure still groups, and a passing assertion in a dependency does not become the signature for every test. Strip NUL bytes from descriptions and failure text before sending; one unstorable string drops the whole result batch on the server.

`terminating` and `report_at_finish`

```json
{"type":"terminating","data":{"signal":"TERM"}}
{"type":"report_at_finish","data":{"connection_retries":1}}
```

### Test-map fragment

Not a WebSocket message. After `close`, if any test was traced:

```text
POST {http-origin}/test_maps/fragments?run_id=&run_attempt=&runner_id=
authorization: {api key}
content-type: application/gzip
```

Body, gzip of:

```json
{
  "version": 1,
  "files": ["lib/billing.py", "tests/test_billing.py"],
  "tests": [{"id": "tests/test_billing.py::test_tax", "deps": [0, 1]}]
}
```

`deps` are indexes into `files`. Paths are repo-relative and match `git ls-tree` (the same paths as `test_map_tree.files`). A dependency seen on any attempt of an id is kept (union). Upload from the Rust helper so the test process's HTTP stubs cannot swallow it. Retry a few times. On failure, warn and exit with the test status anyway: a test missing from the map is run next time, which is the safe direction.

What counts as a dependency is language-specific (the adapter). The rules that are not: ignore installed dependencies and this client's own code; honor `SELECTIVE_TEST_MAP_IGNORE` (comma-separated directories); attribute every thread and every subprocess you can see, because a missed file is a missed failure, while an extra file only runs more tests.

### Capability flag

| `test_map` | Meaning |
|---|---|
| `record` | This runner can trace. The server may set `record: true`. |
| `select` | This runner can snapshot and run a subset, but cannot trace. |
| `0` | `SELECTIVE_TEST_MAP_DISABLE` is `1`, `true`, or `yes`. Never snapshot, never trace, run whatever is assigned (which will be the full suite). |

`SELECTIVE_TEST_MAP_RECORD=1` forces a recording run server-side. The client only forwards the variable and traces when told `record: true`.

## Environment

`SELECTIVE_*` always wins over CI detection. `setup-selective` (the GitHub Action `selectiveci/setup-selective@v1`) sets only:

| Variable | When |
|---|---|
| `SELECTIVE_API_KEY` | The `api-key` input, if given. |
| `SELECTIVE_RUNNER_ID` | The `runner-id` input, if given. The published example passes the matrix index. |
| `SELECTIVE_PR_TITLE` | Pull-request events, from the event payload. |

It does not set the host, the SHA, or the repo slug. Those come from CI. Default host is `wss://app.selective.ci`.

Required after resolution: `host`, `api_key`, `platform`, `run_id`, `run_attempt`, `branch`, `sha`, `git_repo_full_name`, `git_provider`. An empty value is missing. Exit 1 listing the missing `SELECTIVE_*` names.

Optional: `runner_id`, `target_branch`, `base_sha`, `pr_title`, `actor`, `commit_message`, `committer_name`, `committer_email`.

Generate `runner_id` as `selgen-` plus 8 hex characters when the CI did not provide one. Sanitize it for filenames (the legacy FIFO path).

Detected platforms, and the CI variables Ruby reads:

| Platform | Run id | Attempt | Runner id | Branch | SHA | Repo slug |
|---|---|---|---|---|---|---|
| `github_actions` (`GITHUB_ACTIONS`) | `GITHUB_RUN_ID` | `GITHUB_RUN_ATTEMPT` | `SELECTIVE_RUNNER_ID` | `GITHUB_HEAD_REF` or `GITHUB_REF_NAME` | `GITHUB_SHA` | `GITHUB_REPOSITORY` |
| `circleci` | not set by the script (must be passed) | `CIRCLE_BUILD_NUM` | `CIRCLE_NODE_INDEX` | `CIRCLE_BRANCH` | `CIRCLE_SHA1` | `CIRCLE_PROJECT_USERNAME/CIRCLE_PROJECT_REPONAME` when the URL is GitHub |
| `semaphore` | `SEMAPHORE_WORKFLOW_ID` | `1` | `SEMAPHORE_JOB_ID` | PR branch or `SEMAPHORE_GIT_BRANCH` | `SEMAPHORE_GIT_SHA` | `SEMAPHORE_GIT_REPO_SLUG` when provider is `github` |
| `buildkite` | `BUILDKITE_BUILD_ID` | `BUILDKITE_RETRY_COUNT` | `BUILDKITE_PARALLEL_JOB` | `BUILDKITE_BRANCH` | `BUILDKITE_COMMIT` | parsed from `BUILDKITE_REPO` when provider is `github` |
| `rwx` (`RWX` or legacy `MINT`) | `RWX_RUN_ID` | `RWX_TASK_ATTEMPT_NUMBER` | `RWX_PARALLEL_INDEX` | `RWX_GIT_REF_NAME` | `RWX_GIT_COMMIT_SHA` | `RWX_GIT_REPOSITORY_NAME` when the URL is GitHub. Commit message comes from `RWX_GIT_*`, not `git`, because the checkout may have no `.git`. |

GitHub Actions `base_sha` comes from `$GITHUB_EVENT_PATH` (`.pull_request.base.sha`, else `.before`). All-zero SHAs are dropped. Semaphore uses the left side of `SEMAPHORE_GIT_COMMIT_RANGE`. Target branch is `GITHUB_BASE_REF`, `BUILDKITE_PULL_REQUEST_BASE_BRANCH`, or the Semaphore base branch on PR builds.

When the slug is still empty, parse `git config --get remote.origin.url` for a GitHub `owner/repo`. `git_provider` is `github`, `gitlab`, or `bitbucket`, from the URL host or from the CI's own provider variable.

Explicit overrides: `SELECTIVE_API_KEY`, `SELECTIVE_HOST`, `SELECTIVE_PLATFORM`, `SELECTIVE_BRANCH`, `SELECTIVE_PR_TITLE`, `SELECTIVE_TARGET_BRANCH`, `SELECTIVE_ACTOR`, `SELECTIVE_SHA`, `SELECTIVE_BASE_SHA`, `SELECTIVE_RUN_ID`, `SELECTIVE_RUN_ATTEMPT`, `SELECTIVE_RUNNER_ID`, `SELECTIVE_COMMIT_MESSAGE`, `SELECTIVE_COMMITTER_NAME`, `SELECTIVE_COMMITTER_EMAIL`, `SELECTIVE_GIT_REPO`, `SELECTIVE_GIT_PROVIDER`.

Implement detection once, as `transport --build-env`, which prints the JSON object Ruby's `lib/bin/build_env.sh` prints today. Language clients call that instead of porting the shell script. Ruby keeps the script until it switches.

CI layout that matches the Ruby docs: a matrix of runners, `fail-fast: false` (a cancelled shard should still be able to send `terminating`), and `runner-id` set to the matrix index so the same shard keeps the same id across attempts.

## Adapter interface

The framework adapter is the only code that knows the test runner. The session loop above is language core. Together they implement every row of the [parity bar](#parity-bar). The adapter exposes:

| Method | Contract |
|---|---|
| Discover | Return every test the command would have run, with stable ids, without reporting results. |
| Run | Execute the given ids in this process, calling back with a result as each finishes. Re-running an id replaces the previous attempt. |
| Remove failure | Forget one id's failure so exit status can recover. |
| Around-test | When recording, trace setup, body, and teardown for that id. |
| Finish | Run the framework's end-of-suite hooks once. |
| Exit status | 0 when no remaining failure is a hard failure, 1 otherwise. |

A plain invocation that does not connect (`selective exec` in Ruby, used so RSpec can dry-run a manifest in a subprocess) must not require the CI environment.

## Conformance

`selectiveci/transport` ships a mock server and scenario files. A client is done with a slice when it passes them. Scenarios cover: happy path with two batches; a failure then `remove_failed_test_case_result`; the same id assigned twice; `reconnect`; a socket drop while a result is in flight; `close` with `error_code` and an integer status before any test; `SIGTERM` after a failure; `configure_test_map` with `tree` and `record`, including a fragment POST. The mock checks ids, the tree shape, the fragment schema, and that `exit` was not forwarded as a test result.

Language clients do not vendor a private copy of the scenarios. They run the transport repo's suite.
