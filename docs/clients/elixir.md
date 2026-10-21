# Elixir (ExUnit)

Marketing order: first. The backend is Elixir, so this client is the one we can dogfood. ExUnit is the only framework that matters. `mix test --stale` and `mix test --partitions` are local and static; they are not a hosted queue.

Read [SPEC.md](SPEC.md) for the wire contract. This note is the adapter and the binding.

## Binding

**Use an Erlang Port to `transport --stdio`.** Do not use a Rustler NIF for the socket.

Rustler is the right tool when Rust must run on the BEAM scheduler and return quickly. This workload is a Tokio WebSocket that stays open for the whole suite. A NIF that `block_on`s stalls a scheduler. The usual workaround (a Tokio runtime created in `load`, with results sent back via `enif_send`) works, and Rustler has an open, still-unstable async-NIF API, but a panic or a stuck runtime takes the BEAM down with it. A Port dies alone and a supervisor restarts it. The JSON frames are tiny next to a test, so the copy cost does not matter.

The Port is the binding. Elixir does not link `selective-transport` and does not speak WebSocket. `Port.open` with `{spawn_executable, priv/transport}` and `args: ["--stdio"]`, URL in the environment. Line framing matches the sidecar IPC in the spec. The same `transport --snapshot` and `transport --upload-fragment` commands cover the git tree and the fragment POST.

Hex package layout: the Mix project downloads the release archive into `priv/` at compile time, verifies a checksum, and honors `SELECTIVE_TRANSPORT`. Publish to Hex as `selective_exunit`. The binary is not committed. Targets for v1 match Ruby: Linux gnu x86_64 and aarch64, macOS x86_64 and aarch64. Musl when we add it to the transport matrix. Windows is not an ExUnit CI platform we need on day one; the stdio binary still works there once it is built, because Ports do not need FIFOs.

If the binary is missing or the Port exits before `connected`, exit 1. There is no second implementation to fall back to.

## Discovery and running a subset

ExUnit registers tests when the test modules load (`use ExUnit.Case` expands `test` into a function and a registration). The public CLI (`mix test path:line`, `--only`, `--exclude`, `--failed`, `--stale`, `--partitions`) decides the set **before** `ExUnit.run/0`, and `ExUnit.Server` then hands each module to the runner once. A second `ExUnit.run/0` does not rerun tests that were already taken. Filters cannot express "give me the next batch the server just assigned."

The adapter therefore:

1. Starts the application the way `mix test` does (`Mix.Tasks.Test` load path, `test_helper.exs`, compile `test_paths`) with `ExUnit.start(autorun: false)`.
2. Snapshots the registered tests. The stable id is the module plus the test name. A line number changes when someone inserts a comment, which splits flake history for what is still the same test. The name does not. Selection stays safe either way, because that edit changes the file blob and the test runs.
3. Sends the manifest.
4. For each batch, runs those tests through ExUnit's runner with their `setup` and `setup_all` callbacks, then reports results.

Step 4 uses `ExUnit.Runner`, which is not a public API. Pin the Elixir versions under test (the versions this repo's own CI already runs, plus the current OTP) and re-check the runner when Elixir bumps. Calling the test function directly skips callbacks and `on_exit`, which is wrong for Phoenix tests that checkout a sandbox in `setup`.

`mix test --partitions` is the wrong model to copy: it splits files statically at launch. The Selective server assigns ids over time, including retries of a single test.

Keep one VM for the whole shard. Phoenix boot is the expensive part; a fresh `mix test file:line` per batch pays it every time. Compile is already incremental, so the thing to preserve is the started application, the Repo, and loaded modules.

Retries of an id in the same VM must run the test function again and replace the earlier `ExUnit.Test` result. `setup_all` has already run for the module; do not re-run it unless the module was reloaded.

Async tests (`async: true`) run concurrently inside a batch. That matches ExUnit and is safe for attribution only because recording wraps one test at a time. For v1, run Selective batches with async disabled so a trace and a failure belong to one test. Revisit once recording is solid.

## Coverage (test map)

Advertise `record` when `:cover` is available, which it is in every OTP we support. On `record: true`:

- Compile the project with `:cover` before the first test (`:cover.compile_beam` / the directories Mix already compiled). Skip `deps/` and `_build`.
- Around each test, `:cover.reset()` then run, then collect modules with non-zero calls.
- Map a module to a repo-relative path with `module_info(:compile)[:source]`.
- Honor `SELECTIVE_TEST_MAP_IGNORE`.

`:cover` does not see NIFs, and a module that is only pattern-matched may be under-attributed. Extra files are safe; missing files are the risk. Shadow mode on a real Phoenix app is how we find out. Do not combine this with `mix test --cover` in the same VM (one cover server). If the user already started `:cover`, read their data instead of resetting the world.

This replaces the Ruby C tracer. Do not write an Elixir NIF tracer.

`:cover` output is file-level, which is all the fragment format stores. Line coverage is not uploaded.

## Packaging and CI

- Hex: `{:selective_exunit, "~> 0.1"}`.
- CLI: `mix selective.test`, or a `mix archive` later. The command replaces `mix test` on CI and forwards the usual `mix test` arguments (`--include`, paths, `--seed`) so discovery matches what CI ran before.
- The GitHub Action does not change. `runner-id` is the matrix index.
- `fail-fast: false`.

## Risks

- `ExUnit.Runner` is private. An Elixir release can move test state and break the batch loop. Pin versions and run the conformance suite on each.
- `setup_all` plus a retry of one test in a module that mutates global state. Document that a retry reruns the test function and `setup`, not `setup_all`.
- `:cover` and macros. A test that only expands a macro in another module may not mark that module. The server's untraced-file rule then full-runs, which is safe and loud.
- Full-run patterns on the server are Ruby paths (`spec_helper`, `db/schema.rb`, `config/**`). Elixir needs its own list (`mix.exs`, `config/`, `priv/repo/migrations/`) before `select` mode is quiet. Until that ships, an untraced lockfile or config change full-runs, which is the safe default.

## Effort

Smallest language client, once `transport --stdio` exists. Three slices: Port plus session loop plus ExUnit discovery/run until conformance is green; `:cover` recording and fragment upload; Hex package with a checksummed binary download. The private runner API is the slice that can grow. No separate core repository until a second Elixir framework exists.

## Prior art

- `mix test --stale` selects files whose source changed, on one machine, with no map.
- `mix test --partitions` / `--partition` splits the files statically.
- `excoveralls` and `mix test --cover` are the coverage tools. Use `:cover` directly so we own the per-test reset.
