# Elixir (ExUnit)

Marketing order: first, because we can dogfood it. Feasibility of full parity: last. ExUnit is the only framework that matters. `mix test --stale` and `mix test --partitions` are local and static; they are outside the parity bar.

Read [SPEC.md](SPEC.md) for the wire contract and the parity bar. This note is the adapter and the binding.

**Verdict: feasible with risk. Nothing is blocked, and ExUnit does not need a fork.** The split uses public functions. The risk is that a second `ExUnit.run/1` in one VM is not the path Mix ships, so `setup_all`, `on_exit`, formatters, and captured logs have to be proven in CI before the client counts.

Marketing order still lists Elixir first, because we can dogfood it. [PLAN.md](PLAN.md) ranks it after the languages whose runners already re-enter a warm process in production.

## Parity

Rows P4, P10–P14, P16, P19, P23–P27, and P29–P31 are the session loop in this repo, on an Erlang Port to `transport --stdio`. That is a port of `Controller`. Rating: proven.

| Id | Mechanism | Rating |
|---|---|---|
| P1 | `ExUnit.start(autorun: false)`, load `test_helper.exs` and the test modules the way `Mix.Tasks.Test` does, then for each assigned id `ExUnit.configure(only_test_ids: [{Module, :test_name}])` and `ExUnit.run([Module])`. `only_test_ids` is a documented option ("typically used by Mix to filter which tests should run"). `ExUnit.run/1` (since 1.14) "is often used to rerun modules already loaded in memory." One VM for the shard. The application, the Repo, and loaded modules stay up. | feasible with risk |
| P2 | Id is `Module` plus the test name atom (`ExUnit` `test_id()` is `{module, atom}`). Line numbers move when a comment is inserted; the name does not. | proven |
| P3 | After load, read each module's registered tests (`__ex_unit__`). Bodies have not run. Empty registration exits 1. | proven |
| P5–P7, P20 | A formatter (or the `suite_result` plus each `ExUnit.Test` state) maps `nil` to `passed`, `{:failed, _}` to `failed`, `{:skipped, _}` and `{:excluded, _}` of an assigned test to `pending`. Put the test file first in the stack. Exit 1 only when a remaining test is failed or invalid. | proven |
| P8, P9 | The next `ExUnit.run/1` of that id replaces the stored `ExUnit.Test`. Drop the earlier failure from whatever reporter holds it before the rerun. `remove_failed` deletes by the same `{module, name}` pair. | feasible with risk |
| P15, P16 | One id per `ExUnit.run/1` re-enters `setup_all` for that module, which is the RSpec `:all` → `:each` rule. A batch of two tests in one `ExUnit.run/1` runs `setup_all` once and is short of parity. Time each `setup_all` / `on_exit` and add it to `seconds_in_*_all_hooks`. `before(:suite)` equivalent is the application boot, which stays once (P14). | feasible with risk |
| P17 | Modules stay loaded. Do not recompile a test module between batches. | proven |
| P18 | Forward `mix test` arguments (`--include`, `--exclude`, paths, `--seed`) into `ExUnit.configure` before discovery. `mix selective.test` with no socket is a plain `mix test` and does not need CI env. | proven |
| P21 | `async: true` runs modules concurrently, and `:cover` cannot split that. v1 sets `max_cases: 1` and runs modules without `async` so one trace belongs to one id. The ids are still the server's. | proven |
| P22 | Two tests in one module cannot share a name; the compiler rejects it. Warn if a generated name would collide, and suffix the id. | proven |
| P28 | `:cover.reset` around the test, then modules with non-zero calls. Map `module_info(:compile)[:source]` to a repo-relative path. Skip `deps/` and `_build`. One cover server; do not combine with `mix test --cover`. | feasible with risk |
| P32 | `autorun: false`. The process exits when the session loop exits. | proven |

`ExUnit.Runner` and `ExUnit.Server` are undocumented. They are not the mechanism. Elixir 1.17's `--repeat-until-failure` reruns inside one VM by calling `ExUnit.Server.restore_modules` from `ExUnit`'s private `maybe_repeated_run` (`lib/ex_unit/lib/ex_unit.ex`). That is evidence a second run in one VM is a supported product behavior, and it is also evidence the bookkeeping lives on the private server. Our call stays `ExUnit.run/1`. The CI counter decides whether `setup_all` re-enters. A counter that stays at 1 gets fixed on that public call, or the client stops. It does not become a file split.

## Binding

**Use an Erlang Port to `transport --stdio`.** Do not use a Rustler NIF for the socket.

Rustler is the right tool when Rust must run on the BEAM scheduler and return quickly. This workload is a Tokio WebSocket that stays open for the whole suite. A NIF that `block_on`s stalls a scheduler. The usual workaround (a Tokio runtime created in `load`, with results sent back via `enif_send`) works, and Rustler has an open, still-unstable async-NIF API, but a panic or a stuck runtime takes the BEAM down with it. A Port dies alone and a supervisor restarts it. The JSON frames are tiny next to a test, so the copy cost does not matter.

The Port is the binding. Elixir does not link `selective-transport` and does not speak WebSocket. `Port.open` with `{spawn_executable, priv/transport}` and `args: ["--stdio"]`, URL in the environment. Line framing matches the sidecar IPC in the spec. The same `transport --snapshot` and `transport --upload-fragment` commands cover the git tree and the fragment POST.

Hex package layout: the Mix project downloads the release archive into `priv/` at compile time, verifies a checksum, and honors `SELECTIVE_TRANSPORT`. Publish to Hex as `selective_exunit`. The binary is not committed. Targets for v1 match Ruby: Linux gnu x86_64 and aarch64, macOS x86_64 and aarch64. Musl when we add it to the transport matrix. Windows is not an ExUnit CI platform we need on day one; the stdio binary still works there once it is built, because Ports do not need FIFOs.

If the binary is missing or the Port exits before `connected`, exit 1. There is no second implementation to fall back to.

## Discovery and running a subset

ExUnit registers tests when the test modules load. `mix test path:line` is Mix setting `only_test_ids` to `{module, test_name}` tuples before a single `ExUnit.run/0`. That option is public, and `ExUnit.run/1` accepts modules that are already loaded so they run again. The adapter uses those two functions, one id at a time, and leaves `ExUnit.Runner` alone.

`mix test --partitions` splits files at launch. It is outside the parity bar. So is shelling `mix test path:line` per batch: that pays Phoenix boot every time. The VM stays up.

Calling the test function directly skips `setup`, `setup_all`, and `on_exit`. Phoenix sandbox checkout lives in `setup`, so the call goes through `ExUnit.run/1`.

Pin the Elixir versions this repo's CI already runs, plus current OTP (1.17 or newer so `--repeat-until-failure` exists as a reference), and count `setup_all` and `on_exit` across two batches of the same module. That fixture is the P15 proof. `ExUnit.run/1` re-adds the module through the public entry; if `setup_all` still does not re-enter, read `restore_modules` to see what the private repeat path resets, and reproduce that reset from the public side. Do not take a dependency on `ExUnit.Server`.

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

- A second `ExUnit.run/1` in one VM is not Mix's production path. `setup_all`, `on_exit`, formatters, and `capture_log` (the docs note that `on_exit` and `setup_all` can log outside the test process) have to be counted in CI. This is the row that can slip, and it is still public API.
- `:cover` and macros. A test that only expands a macro in another module may not mark that module. The server's untraced-file rule then full-runs, which is safe and loud.
- Full-run patterns on the server are Ruby paths (`spec_helper`, `db/schema.rb`, `config/**`). Elixir needs its own list (`mix.exs`, `config/`, `priv/repo/migrations/`) before `select` mode is quiet. Until that ships, an untraced lockfile or config change full-runs, which is the safe default. That is a server follow-up, not a client blocker.

## Effort

Three slices, once `transport --stdio` exists: Port plus session loop plus `only_test_ids` / `ExUnit.run/1` until conformance is green, including the `setup_all` counter; `:cover` recording and fragment upload; Hex package with a checksummed binary download. No separate core repository until a second Elixir framework exists. There is no private-runner slice.

## Prior art

- `mix test --stale` selects files whose source changed, on one machine, with no map.
- `mix test --partitions` / `--partition` splits the files statically.
- `excoveralls` and `mix test --cover` are the coverage tools. Use `:cover` directly so we own the per-test reset.
