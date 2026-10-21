# Build plan

Design only. No new client repository is created by this document.

Build order is feasibility of the [parity bar](SPEC.md#parity-bar): a warm process, server-assigned test ids, hook re-entry, retries, and the test-map fragment. The marketing note (Elixir, Python, PHP, JavaScript, Java) still decides when a language is announced. It does not decide which client is writable first. Elixir remains the suite we can dogfood, and it is last in this list. A second `ExUnit.run/1` did re-enter `setup_all` on Elixir 1.19.5. What remains is the `MapSet` footgun (a list runs zero tests and exits 0) and suite hooks: `after_suite` fires on every `ExUnit.run/1`, so the adapter runs them once.

The contract is [SPEC.md](SPEC.md). Language notes: [python.md](python.md), [java.md](java.md), [php.md](php.md), [javascript.md](javascript.md), [elixir.md](elixir.md).

## Order

| Rank | Language | First framework | Later framework, same split | Verdict |
|---|---|---|---|---|
| 1 | Python | pytest | Django's runner only if a partner needs it | Proven run loop. Record mode forces coverage.py ctrace. P15, junitxml removal, and `FixtureDef.finish` touch private objects. |
| 2 | Java | JUnit Platform launcher inside a Surefire provider | Gradle test worker, same launcher | `execute` by unique id is proven. The Surefire provider SPI can change in a minor, so the host is feasible with risk. Dynamic and parameterized ids need a collect pass. JaCoCo path mapping is the recording risk. |
| 3 | PHP | PHPUnit 10+ `TestSuite::run()` plus an Extension subscriber | Pest, a bootstrap on the PHPUnit client | Feasible with risk. 10+ has no `TestResult`. The client keeps its own per-id store and forces `stopOnFailure` and `stopOnDefect` off. |
| 4 | JavaScript | Vitest `>= 4.1.1 < 5` | Jest 29, then 30, via a custom `runner` and `runInBand` | Feasible with risk. One `runTestSpecifications` call for the batch is the warm-worker candidate. Jest does not deep-import `watch.ts`. |
| 5 | Elixir | ExUnit | none | Feasible with risk. `only_test_ids` is a `MapSet`. `ExUnit.run/1` re-entered `setup_all` on 1.19.5. The adapter runs `after_suite` once. |

No language is blocked. None of these need a framework fork or an upstream feature. A file-level or statically sharded mode is not a slice in any repository.

What "first framework" means: the adapter that implements every parity row. Vitest before Jest, because `runTestSpecifications` plus `testIds` is a public API and Jest's warm loop is a custom `runner` (the public config key), not a deep import of `@jest/core`'s watch entry. PHPUnit before Pest, because Pest emits PHPUnit cases. Surefire before Gradle, because `SurefireProvider.invoke()` is the JVM `mvn test` already forked; a classpath-only main is the harness for that same loop, not a client that ships ahead of Surefire. The provider SPI can change in a minor. Gradle has no public `Test.executer`.

## What every client is

```text
selectiveci/transport          Rust crate. WebSocket, git snapshot, fragment upload, conformance mock.
        |
        +-- in-process binding   Python (PyO3), JavaScript (napi-rs)
        +-- stdio sidecar        Elixir (Port), PHP, Java, and the fallback for Python and Node
        |
        +-- language core        session loop, env, exit codes, signals. No WebSocket code.
        |
        +-- framework adapter    discover, run ids, report, trace one test
```

Ruby stays a FIFO sidecar until someone migrates it. New clients do not copy the FIFOs (they are not on Windows) and do not open sockets.

Rows are build order, the same order as the rank table. Marketing order is not this table.

| Language | Binding to ship | Fallback if the native face fails |
|---|---|---|
| Python | PyO3 wheel | `transport --stdio`. Pyodide cannot spawn a process, so it exits 1. It is not a v1 target. |
| Java | `transport --stdio` | Exit 1. No JNI and no Panama. |
| PHP | `transport --stdio` | Exit 1. No PHP extension and no FFI. |
| JavaScript | napi-rs `.node` | `transport --stdio` |
| Elixir | Erlang Port, `transport --stdio` | Exit 1. A Rustler NIF is not the fallback. |

Recording uses the language's own coverage tool (`:cover`, coverage.py, PCOV, V8, JaCoCo). The Ruby C tracer is not ported. If that tool is missing, the client advertises `test_map=select` and still orchestrates.

## Shared prerequisite (transport)

In `selectiveci/transport`, before any language repository:

0. Restore the release job. `main` (`9eb6689`) and draft PR #10 (`e557d04`) still set `os: ubuntu-20.04` for Linux gnu, and #10's musl rows use that label too. GitHub retired that hosted image on 2025-04-15, so the job produces no Linux archive. The last release is v0.1.1 (2024-02-28). Move the job to an `ubuntu-22.04` runner with `container: ubuntu:20.04` or a manylinux2014 image, or cargo-zigbuild `x86_64-unknown-linux-gnu.2.17` and the aarch64 twin. Glibc floor 2.17. PR #10 adds musl, Windows x86_64, and checksums. It does not restore the host. This document does not edit the transport repository.
1. Extract the session type from `src/main.rs`. The CLI's FIFO mode stays, so Ruby does not change. `Session` sends a WebSocket ping about every 60 seconds. The server socket times out at 300_000 ms, and today's `main.rs` only logs a received Ping.
2. Add `--stdio`, with `SELECTIVE_TRANSPORT_URL` in the environment rather than the API key on `argv`.
3. Add `--build-env`, `--snapshot`, and `--upload-fragment`. `--build-env` emits RFC 8259 strings (the shell `escape()` does not). Clients do not reimplement CI detection, `git ls-tree`, or the gzip POST.
4. Add the conformance mock and the scenarios listed in the spec, including a test that runs past the 300 second idle timeout and a `--build-env` fixture with a backslash and a tab in the commit subject. Scenarios live here and are versioned with the protocol. The mock does not exist at transport@9eb6689. PR #10 proposes it and is not merged.
5. After step 0, extend the release matrix with musl (x86_64 and aarch64) and Windows x86_64, built at the glibc 2.17 floor. Publish checksums. Keep the existing archive names.

Rustls stays. Do not link OpenSSL.

This slice is the critical path. It is similar in size to one language session loop, and it removes that loop's hardest bugs (framing, certificates, Windows pipes) from every later agent.

## Repositories

One repository per framework, mirroring `selective-ruby-core` plus `selective-ruby-rspec` and `selective-ruby-minitest`. Do not create empty core repositories ahead of the first adapter. A second framework in a language is what justifies a core split. JavaScript has two frameworks, so the core package is created with Vitest.

Rows after `transport` are build order.

| Repository | Contains | Depends on |
|---|---|---|
| `selectiveci/transport` | Crate, CLI, conformance | — |
| `selectiveci/selective-python-pytest` | PyO3 binding, pytest adapter | transport crate and binary |
| `selectiveci/selective-java-junit` | Sidecar session, Surefire provider hosting the launcher | transport binary |
| `selectiveci/selective-php-phpunit` | Sidecar session, PHPUnit adapter | transport binary |
| `selectiveci/selective-php-pest` | Pest bootstrap on the PHPUnit client | selective-php-phpunit |
| `selectiveci/selective-js-core` | napi binding, sidecar fallback, session | transport crate and binary |
| `selectiveci/selective-js-vitest` | Vitest adapter | selective-js-core |
| `selectiveci/selective-js-jest` | Jest adapter | selective-js-core |
| `selectiveci/selective-elixir-exunit` | Port, session, ExUnit adapter | transport binary |

Each client runs the transport repo's conformance scenarios in CI. A green local mock is not a private copy of the scenarios.

Server follow-ups, not client repositories: per-language full-run patterns (`mix.exs`, `conftest.py`, `phpunit.xml`, `vitest.config.ts`, `pom.xml`, lockfiles, migrations). Until those exist, an untraced change full-runs, which is safe when no test traces the file. Gate `remove_failed_test_case_result` on a client capability rather than `framework == "rspec"` and wrapper `>= 0.1.6`, and deliver owed removes on reconnect. Until that ships, minitest and every new client get `[assign]` only after a reconnect, and a green rerun elsewhere can leave the shard at exit 1. That false red is the safe direction. Widening `test_case_extid` past varchar 255 is optional; clients shorten ids until it exists. The systemic-failure backtrace filter is Ruby-specific; clients put a repo-relative frame first so the current filter still groups.

`setup-selective` stays as it is. It is already language-agnostic.

## Slices per language

Each slice is a PR an agent can finish and conformance-test. The first PR of a language is a client only when every parity row that PR claims is actually running: per-test ids, a warm process, a retry that replaces the earlier result, `remove_failed_test_case_result`, and the group-hook counter (P15). Advertising `select` until the tracer is trustworthy is fine. Advertising a file id is not.

### Python (pytest)

1. **First PR.** Package with the sidecar face, pytest collection, replaced `pytest_runtestloop`, module-fixture counter green, snapshot on the manifest, conformance green, a Django skeleton in CI. Advertise `select`.
2. coverage.py contexts on ctrace (`dict(cov.sys_info())["core"] == "CTracer"`, otherwise advertise `select`), a two-tests-share-a-helper fixture, tests that spawn a process left out of the fragment, and upload.
3. maturin wheels (manylinux, musllinux, macOS, Windows) and the import-then-sidecar fallback.

The wheel slice is last so the adapter is not waiting on cibuildwheel.

### Java (JUnit Platform, Surefire host)

1. **First PR.** Surefire provider whose `invoke()` discovers static tests, collects dynamic and parameterized child ids with an `InvocationInterceptor` that skips bodies, opens the session, and `execute`s unique ids one at a time. Results stay in the client's store until `close`, because the provider `RunResult` is what the build sees. `@BeforeAll` counter green, and a suite extension that ran once. Conformance on JDK 17 and 21, in a forked Surefire JVM. The classpath-fed main is in this PR as the mock-server harness. The provider SPI is feasible with risk.
2. Gradle host, same launcher. There is no public `Test.executer`. An init script or a `Test` task calls the launcher on the worker classpath.
3. JaCoCo dump-and-reset and class-to-source mapping. Advertise `select` until a fragment path is a snapshot key.

### PHP (PHPUnit, then Pest)

1. **First PR.** Composer package, sidecar session, one-method `TestSuite::run()` in the booted process, an Extension subscriber feeding the client's own per-id store, `stopOnFailure` and `stopOnDefect` forced off, `BeforeClass` counter green, conformance on PHPUnit 10, 11, 12, and 13, plus a Laravel skeleton.
2. PCOV per-test coverage and upload.
3. `selective/pest` repository: Pest bootstrap, same session, its own conformance file of Pest-style names.

### JavaScript (Vitest, then Jest)

1. **First PR, core plus Vitest.** `selective-js-core` on the sidecar. Pin Vitest `>= 4.1.1 < 5`. `createVitest`, `standalone`, `experimental_parseSpecifications` on 4.1, `collectTests` for dynamic cases, and one `runTestSpecifications` call whose specs are the batch. One id per call forks a new worker and is not the warm path. Re-run the `beforeAll` counter under the one-call shape. `fileParallelism: false`, `maxWorkers: 1`, `isolate: false` (Vitest 4 removed `poolOptions.forks.singleFork`). Conformance green. napi packages can land in this PR or the next; the sidecar works first.
2. napi `optionalDependencies` and the `dlopen` fallback. v8 coverage, with transformed URLs resolved to git paths before we advertise `record`.
3. **Jest PR.** Jest 29 custom `runner` with `runInBand` in `selective-js-jest`. Do not import `packages/jest-core/src/watch.ts` (`ERR_PACKAGE_PATH_NOT_EXPORTED` on 29 and 30). The custom environment renames a duplicate registration and matches an anchored, escaped `^…$`. Circus collection, `beforeAll` counter green, duplicate-name fixture green. Per-test coverage starts `v8.startPreciseCoverage` in the runner; Jest has no `takePreciseCoverage` hook. Jest 30 is a follow-up on that pin. A red counter stays on the custom runner. It does not change the manifest to file paths, and it does not become `runCLI` per batch.

### Elixir (ExUnit)

1. **First PR.** Mix project, stdio binary, Port, session loop, `only_test_ids: MapSet.new([{Module, :name}])` plus `ExUnit.run/1` one id at a time. A list is a silent zero-test exit 0. `setup_all` counter green across at least two batches with at least two of the group's tests in one batch. The adapter runs `after_suite` once. `transport --snapshot` on the manifest, conformance green. Advertise `select`. Replace `mix test` on one internal app.
2. `:cover` around each test, fragment upload, advertise `record`.
3. Hex publish path: checksummed `priv/transport`, README, GitHub Action example.

The private `ExUnit.Runner` module is not on this path. Pin the Elixir versions CI already runs.

## Conformance before publish

A client slice is mergeable when:

- The transport scenarios pass, including reconnect, a repeated id, `remove_failed_test_case_result` from a simulated other runner, `close` with an integer status, and `SIGTERM` after a failure.
- A sample project (Django, a Surefire suite, Laravel, a Vitest package, Phoenix) runs a subset and exits with the framework status.
- The group-hook counter for that framework equals the number of tests assigned from that group, across at least two batches with at least two tests of that group in one batch (`setup_all`, `@BeforeAll`, `BeforeClass`, `beforeAll`, or a module-scoped fixture), and the suite hook ran once.
- A repeated id replaces the earlier JUnit or reporter entry.
- Recording slices additionally upload a fragment whose paths are keys in the snapshot.
- Install does not require a compiler, except the PyO3 and napi release workflows themselves.

Do not publish to Hex, PyPI, Packagist, npm, or Maven Central from the first PR. Publishing is the last slice of each language, after a design partner has run it.

## What we are not doing

- A WebSocket client in Elixir, Python, PHP, Node, or Java.
- Rustler NIFs, `ext-php-rs`, JNI, or Panama as the transport.
- Porting `selective_tracer`.
- Playwright, TestNG, Django's runner, or a second JS test runner besides Jest and Vitest, until a partner asks.
- A hosted selector inside Nx, Turborepo, or Develocity.
- A client whose manifest id is a file, or whose split is a static shard, including as a temporary mode.
