# Build plan

Design only. No new client repository is created by this document.

Build order is feasibility of the [parity bar](SPEC.md#parity-bar): a warm process, server-assigned test ids, hook re-entry, retries, and the test-map fragment. The marketing note (Elixir, Python, PHP, JavaScript, Java) still decides when a language is announced. It does not decide which client is writable first. Elixir remains the suite we can dogfood, and it is last in this list. A second `ExUnit.run/1` did re-enter `setup_all` on Elixir 1.19.5. What remains is the `MapSet` footgun (a list logs a `FunctionClauseError` and returns 0 tests) and suite hooks: `after_suite` fires on every `ExUnit.run/1`, so the adapter runs them once.

The contract is [SPEC.md](SPEC.md). Language notes: [python.md](python.md), [java.md](java.md), [php.md](php.md), [javascript.md](javascript.md), [elixir.md](elixir.md).

## Order

| Rank | Language | First framework | Later framework, same split | Verdict |
|---|---|---|---|---|
| 1 | Python | pytest | Django's runner only if a partner needs it | Proven run loop. `selective pytest` sets `COVERAGE_CORE=ctrace` before pytest starts. P15 tears down through `SetupState` to the session node. junitxml removal is private. A failed `CollectReport` exits before the manifest. |
| 2 | Java | JUnit Platform launcher inside a Surefire provider | Gradle test worker, same launcher | `execute` by unique id is the mechanism. The Surefire provider SPI can change in a minor, so the host is feasible with risk. The collect pass selects factory, template, and class-template ids and skips class and method hooks. A container that fails during collect is a manifest entry. `RunResult` is discarded; the build counts `RunListener` events sent from the client store at `close`. |
| 3 | PHP | PHPUnit 10+ `TestSuite::fromClassReflector` plus an Extension subscriber | Pest, a bootstrap on the PHPUnit client | Feasible with risk. 10+ has no `TestResult`. The client keeps its own per-id store and forces all nine stop flags off. `addTest` does not re-enter `BeforeClass`. |
| 4 | JavaScript | Vitest `>= 4.1.1 < 5` | Jest 29, then 30, via a custom `runner` and `runInBand` | Feasible with risk. One id per `runTestSpecifications` call re-enters `beforeAll` and boots a new worker. The main process and the Vite server stay up. Jest does not import `@jest/core/build/watch`. |
| 5 | Elixir | ExUnit | none | Feasible with risk. `only_test_ids` is a `MapSet`. A list logs a `FunctionClauseError` and returns 0 tests. `ExUnit.run/1` re-entered `setup_all` on 1.19.5. The adapter runs `after_suite` once. |

No language is blocked. None of these need a framework fork or an upstream feature. A file-level or statically sharded mode is not a slice in any repository.

What "first framework" means: the adapter that implements every parity row. Vitest before Jest, because `runTestSpecifications` plus `testIds` is a public API and Jest's warm loop is a custom `runner` (the public config key, with `supportsEventEmitters` and a per-batch `testNamePattern`), not an import of `@jest/core/build/watch`. PHPUnit before Pest, because Pest emits PHPUnit cases. Surefire before Gradle, because `SurefireProvider.invoke()` is the JVM `mvn test` already forked; a classpath-only main is the harness for that same loop, not a client that ships ahead of Surefire. The provider SPI can change in a minor. Gradle has no public `Test.executer`. `setTestExecuter` is package-private. Neither is API.

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

0. Restore a Linux gnu archive from `main` at `9eb6689`. The last release is v0.1.1 (2024-02-28), and that binary needs `GLIBC_2.28`. The acceptance check is the glibc floor: build the gnu targets in a manylinux2014 container, or with cargo-zigbuild `x86_64-unknown-linux-gnu.2.17` and the aarch64 twin, and the highest `GLIBC_` version in `objdump -T` is at most 2.17. An `ubuntu:20.04` container is glibc 2.31 and cannot produce that floor. The floor applies to gnu targets only. This document does not describe another pull request's runners, and it does not edit the transport repository. Whether that other work changes the gnu floor is decided there.
1. Extract the session type from `src/main.rs`. The CLI's FIFO mode stays, so Ruby does not change. FIFO mode exits on server Close and on connect failure as promptly as `9eb6689` (under a second), whatever the peer's FIFO state. `tests/cli.rs` covers both. Every `Session` call, including `close()` and drop, returns or errors within a fixed deadline. The server socket times out at 300_000 ms with no data from the client. Inbound client data, including a ping, resets that timer. Frames the server sends do not. The ping interval is configurable. Today's `main.rs` only logs a received Ping.
2. Add `--stdio`, with `SELECTIVE_TRANSPORT_URL` in the environment rather than the API key on `argv`.
3. Add `--build-env`, `--snapshot`, and `--upload-fragment`. `--build-env` emits RFC 8259 strings (the shell `escape()` does not). `--snapshot` must not deadlock for any number of dirty paths, including at least 10,000 modified tracked files. `--upload-fragment` sends the `run_id`, `run_attempt`, and `runner_id` the session connected with, not a fresh `--build-env` detection. Clients do not reimplement CI detection, `git ls-tree`, or the gzip POST.
4. Add the conformance mock and the scenarios listed in the spec. There is no mock and no scenario file at `9eb6689`. The idle-close scenario uses a small N, not a 300 second wait. The `--build-env` fixture includes a backslash, a tab, and a newline in the commit subject. Scenarios live here and are versioned with the protocol. An exit expectation passes only for a normal exit with that code.
5. After step 0, extend the release matrix with musl (x86_64 and aarch64) and Windows x86_64. The glibc floor is the gnu rows only. Publish checksums. Keep the existing archive names.

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

Server follow-ups, not client repositories. Full-run patterns that already exist are the common list in [SPEC.md](SPEC.md) (tool versions, Dockerfiles, CI config), the Python list (`requirements*.txt`, `poetry.lock`, `pyproject.toml`, `setup.cfg`, `conftest.py`, `tox.ini`), and the JavaScript list (`package.json`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `tsconfig.json`). Still to add: Elixir (`mix.exs`, `config/`, `priv/repo/migrations/`), PHP (`composer.lock`, `phpunit.xml`, `pest.php`, `tests/Pest.php`, `tests/TestCase.php`, Laravel migrations), Java (`pom.xml`, Gradle files, application config, Flyway and Liquibase), JavaScript config the list does not yet name (`vitest.config.*`, `jest.config.*`, `vite.config.*`), and the Python gaps `pytest.ini`, `uv.lock`, Django `settings.py`, and migration packages. A changed path full-runs when no test traces it, when the path is new, or when it matches a pattern. A file some other test already traced is not a full-run.

Gate the failure holder and the reconnect carry on a client capability, and send owed removes at re-registration. Conformance lists the cross-runner remove (no assign after it) and the manual rerun (`assign` then `assign` for minitest and rspec `<= 0.1.5`). A faithful client still replaces its local reporter entry and does not depend on a remove. Widening `test_case_extid` past varchar 255 is optional; clients shorten ids until it exists. Validating the WebSocket manifest the way the HTTP controller does (`run_time` and `file_path`) is a server ticket this document does not open. The systemic-failure backtrace filter is Ruby-specific; clients put a repo-relative frame first so the current filter still groups.

`setup-selective` stays as it is. It is already language-agnostic.

## Slices per language

Each slice is a PR an agent can finish and conformance-test. The first PR of a language is a client only when every parity row that PR claims is actually running: per-test ids, a warm process, a retry that replaces the earlier result, `remove_failed_test_case_result`, and the group-hook counter (P15). Advertising `select` until the tracer is trustworthy is fine. Advertising a file id is not.

### Python (pytest)

1. **First PR.** Package with the sidecar face, pytest collection, replaced `pytest_runtestloop`, a failed `CollectReport` exiting before the manifest, teardown to the session node through `SetupState`, module-fixture counter green, snapshot on the manifest, conformance green, a Django skeleton in CI. Advertise `select`.
2. coverage.py contexts. The console script sets `COVERAGE_CORE=ctrace` before pytest starts. `set_option` is only for an instance the client builds, before `start()`. Never restart pytest-cov's instance. Read the core after `start()` and require `CTracer`, otherwise advertise `select`. A two-tests-share-a-helper fixture. `sys.addaudithook` excludes a test whose fixture closure spawns. Upload.
3. maturin wheels (manylinux, musllinux, macOS, Windows) and the import-then-sidecar fallback.

The wheel slice is last so the adapter is not waiting on cibuildwheel.

### Java (JUnit Platform, Surefire host)

1. **First PR.** Surefire provider whose `invoke()` discovers static tests and collects dynamic, parameterized, and (on 5.13+) class-template ids. The collect pass skips `interceptDynamicTest`, `interceptTestTemplateMethod`, `interceptTestMethod`, `interceptBeforeEachMethod`, `interceptAfterEachMethod`, `interceptBeforeAllMethod`, and `interceptAfterAllMethod`, and it attaches no reporting listener. A container that finishes `FAILED` during that pass is a manifest entry and reports `failed` when executed. The session `execute`s one unique id at a time and holds that id's result until `execute` returns. Under a forked Surefire JVM, `invoke()`'s `RunResult` is discarded. At `close`, send `RunListener` events from the client store, one per id. `@BeforeAll` counter equals the number of assigned tests (the collect pass does not add a count). Assert "once" only for a session-scoped fixture the adapter registers. Root-store suite extensions may run again. Conformance fixtures include a throwing `@BeforeAll`, a throwing `@AfterAll`, an assumption in `@BeforeAll`, a `@Disabled` class, and a factory that throws during collect. JDK 17 and 21, in a forked Surefire JVM. The classpath-fed main is in this PR as the mock-server harness. The provider SPI is feasible with risk. Gradle's host is an init script or a `Test` task. `createTestExecuter()` is internal and `setTestExecuter` is package-private.
2. Gradle host, same launcher. There is no public `Test.executer`. An init script or a `Test` task calls the launcher on the worker classpath.
3. JaCoCo dump-and-reset and class-to-source mapping. Advertise `select` until a fragment path is a snapshot key.

### PHP (PHPUnit, then Pest)

1. **First PR.** Composer package, sidecar session, one method per `TestSuite::fromClassReflector` narrowed with `setTests()`, an Extension subscriber feeding the client's own per-id store. A copy of `phpunit.xml` forces all nine stop flags off before `Registry::init`, and `--stop-on-*` is stripped. On 13, do not install SIGINT or time-limit handlers. An assigned id with no outcome after `run()` is `failed`. `BeforeClass` counter green. Conformance on PHPUnit 10, 11, 12, and 13: each stop flag set, batch 1 trips it, batch 2 runs. Read `--list-tests-xml` with the 10.5 names on 10 and the 11+ names after that. Never call `setData` with provider keys. Plus a Laravel skeleton.
2. PCOV per-test coverage and upload.
3. `selective/pest` repository: Pest bootstrap, same session, its own conformance file of Pest-style names.

### JavaScript (Vitest, then Jest)

1. **First PR, core plus Vitest.** `selective-js-core` on the sidecar. Pin Vitest `>= 4.1.1 < 5`. `createVitest`, `standalone`, `experimental_parseSpecifications` for files with no dynamic tests, and `collectTests` for every id in a file that has any `dynamic: true` entry. One `createSpecification(moduleId, { testIds: [id] })` and one `runTestSpecifications` call per assigned id, so `beforeAll` re-enters. Each call boots a new worker. The main process and the Vite server stay up. Forward results only for assigned ids, and a later skip must not overwrite a pass. `fileParallelism: false`. `maxWorkers: 1` with `isolate: false` is one worker within a call. Vitest 4 removed `poolOptions`. `singleFork` is ignored, with a deprecation warning. Conformance green. napi packages can land in this PR or the next; the sidecar works first.
2. napi `optionalDependencies` and the `dlopen` fallback. v8 coverage, with transformed URLs resolved to git paths before we advertise `record`.
3. **Jest PR.** Jest 29 custom `runner` with `supportsEventEmitters` and `runInBand` in `selective-js-jest`. Do not import `@jest/core/build/watch` (not exported; 29.7.0 and 30.5.2 export only `.` and `./package.json`). The manifest id is the repo-relative path plus the full name. The custom environment renames a duplicate registration on the case-folded name. That write touches circus state the README calls unsupported, so the duplicate fixture is re-run on every minor bump. Match an anchored, escaped `^…$`. Circus collection, `beforeAll` counter green. Per-test coverage posts `Profiler.startPreciseCoverage` and `Profiler.takePreciseCoverage` on a `node:inspector` `Session`. `v8.startPreciseCoverage` does not exist. Do not enable Jest coverage collection in the same process. Jest 30 is a follow-up on that pin. A red counter stays on the custom runner. It does not change the manifest to file paths, and it does not become `runCLI` per batch.

### Elixir (ExUnit)

1. **First PR.** Mix project, stdio binary, Port, session loop, `only_test_ids: MapSet.new([{Module, :name}])` plus `ExUnit.run/1` one id at a time. A list logs a `FunctionClauseError` and returns 0 tests. `setup_all` counter green across at least two batches with at least two of the group's tests in one batch, and the matching after-hook counter (`on_exit`) agrees. The adapter runs `after_suite` once. `transport --snapshot` on the manifest, conformance green. Advertise `select`. Replace `mix test` on one internal app. `path:line` is `include: [location: …]` on Mix 1.17.3 through 1.20.4. `--failed` is a separate path. The adapter sets the `MapSet` itself.
2. `:cover` around each test, fragment upload, advertise `record`.
3. Hex publish path: checksummed `priv/transport`, README, GitHub Action example.

The private `ExUnit.Runner` module is not on this path. Pin the Elixir versions CI already runs.

## Conformance before publish

A client slice is mergeable when:

- The transport scenarios pass, including reconnect, a repeated id, a cross-runner `remove` with no assign after it, a manual rerun that is `assign` then `assign`, `close` with an integer status, and `SIGTERM` after a failure and during a stalled fragment upload.
- A sample project (Django, a Surefire suite, Laravel, a Vitest package, Phoenix) runs a subset and exits with the framework status.
- The group-hook counter for that framework equals the number of tests assigned from that group, across at least two batches with at least two tests of that group in one batch. The observation channel is the sample project's own fixture output, or the named `report_at_finish` keys `seconds_in_*_all_hooks`. Count the before hook (`setup_all`, `@BeforeAll`, `BeforeClass`, `beforeAll`, or a module-scoped fixture) and the matching after hook (`on_exit`, `@AfterAll`, `tearDownAfterClass`, `afterAll`, or the after-fixture). The Java collect pass does not add to that count. Assert "once" only for a session-scoped fixture the adapter itself registers. Do not invent `suite_hooks` or `group_hooks` fields.
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
