# Build plan

Design only. No new client repository is created by this document.

Build order is feasibility of the [parity bar](SPEC.md#parity-bar): a warm process, server-assigned test ids, hook re-entry, retries, and the test-map fragment. The marketing note (Elixir, Python, PHP, JavaScript, Java) still decides when a language is announced. It does not decide which client is writable first. Elixir remains the suite we can dogfood, and it is last in this list because a repeated `ExUnit.run/1` is the least proven loop.

The contract is [SPEC.md](SPEC.md). Language notes: [python.md](python.md), [java.md](java.md), [php.md](php.md), [javascript.md](javascript.md), [elixir.md](elixir.md).

## Order

| Rank | Language | First framework | Later framework, same split | Verdict |
|---|---|---|---|---|
| 1 | Python | pytest | Django's runner only if a partner needs it | Proven split. P15 (module fixtures vs session fixtures) is the one private surface. |
| 2 | Java | JUnit Platform launcher inside a Surefire provider | Gradle test worker, same launcher | Proven split. JaCoCo path mapping is the recording risk. |
| 3 | PHP | PHPUnit 10+ `TestSuite` of one method | Pest, a bootstrap on the PHPUnit client | Proven split. Data-provider construction across majors is the risk. |
| 4 | JavaScript | Vitest `>= 4.1` | Jest 29, then 30 | Feasible with risk. Vitest static tests are proven; `test.each` and Jest's watch internals are the risk. |
| 5 | Elixir | ExUnit | none | Feasible with risk. Public `only_test_ids` and `ExUnit.run/1`. A second run in one VM is not Mix's normal path. |

No language is blocked. None of these need a framework fork or an upstream feature. A file-level or statically sharded mode is not a slice in any repository.

What "first framework" means: the adapter that implements every parity row. Vitest before Jest, because `runTestSpecifications` plus `testIds` is a public API and Jest's warm loop is `@jest/core`. PHPUnit before Pest, because Pest emits PHPUnit cases. Surefire before Gradle, because `SurefireProvider.invoke()` is the JVM `mvn test` already forked; a classpath-only main is the harness for that same loop, not a client that ships ahead of Surefire.

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

| Language | Binding to ship | Fallback if the native face fails |
|---|---|---|
| Elixir | Erlang Port, `transport --stdio` | Exit 1. A Rustler NIF is not the fallback. |
| Python | PyO3 wheel | `transport --stdio` |
| JavaScript | napi-rs `.node` | `transport --stdio` |
| PHP | `transport --stdio` | Exit 1. No PHP extension and no FFI. |
| Java | `transport --stdio` | Exit 1. No JNI and no Panama. |

Recording uses the language's own coverage tool (`:cover`, coverage.py, PCOV, V8, JaCoCo). The Ruby C tracer is not ported. If that tool is missing, the client advertises `test_map=select` and still orchestrates.

## Shared prerequisite (transport)

In `selectiveci/transport`, before any language repository:

1. Extract the session type from `src/main.rs`. The CLI's FIFO mode stays, so Ruby does not change.
2. Add `--stdio`, with `SELECTIVE_TRANSPORT_URL` in the environment rather than the API key on `argv`.
3. Add `--build-env`, `--snapshot`, and `--upload-fragment`, matching the Ruby scripts so clients do not reimplement CI detection, `git ls-tree`, or the gzip POST.
4. Add the conformance mock and the scenarios listed in the spec. Scenarios live here and are versioned with the protocol.
5. Extend the release matrix with musl (x86_64 and aarch64) and Windows x86_64, built from an old glibc for the gnu targets, the way the current four archives are. Publish checksums. Keep the existing archive names.

Rustls stays. Do not link OpenSSL.

This slice is the critical path. It is similar in size to one language session loop, and it removes that loop's hardest bugs (framing, certificates, Windows pipes) from every later agent.

## Repositories

One repository per framework, mirroring `selective-ruby-core` plus `selective-ruby-rspec` and `selective-ruby-minitest`. Do not create empty core repositories ahead of the first adapter. A second framework in a language is what justifies a core split. JavaScript has two frameworks, so the core package is created with Vitest.

| Repository | Contains | Depends on |
|---|---|---|
| `selectiveci/transport` | Crate, CLI, conformance | — |
| `selectiveci/selective-elixir-exunit` | Port, session, ExUnit adapter | transport binary |
| `selectiveci/selective-python-pytest` | PyO3 binding, pytest adapter | transport crate and binary |
| `selectiveci/selective-php-phpunit` | Sidecar session, PHPUnit adapter | transport binary |
| `selectiveci/selective-php-pest` | Pest bootstrap on the PHPUnit client | selective-php-phpunit |
| `selectiveci/selective-js-core` | napi binding, sidecar fallback, session | transport crate and binary |
| `selectiveci/selective-js-vitest` | Vitest adapter | selective-js-core |
| `selectiveci/selective-js-jest` | Jest adapter | selective-js-core |
| `selectiveci/selective-java-junit` | Sidecar session, Surefire provider hosting the launcher | transport binary |

Each client runs the transport repo's conformance scenarios in CI. A green local mock is not a private copy of the scenarios.

Server follow-ups, not client repositories: per-language full-run patterns (`mix.exs`, `conftest.py`, `phpunit.xml`, `vitest.config.ts`, `pom.xml`, lockfiles, migrations). Until those exist, an untraced change full-runs, which is safe. The systemic-failure backtrace filter is Ruby-specific; clients put a repo-relative frame first so the current filter still groups.

`setup-selective` stays as it is. It is already language-agnostic.

## Slices per language

Each slice is a PR an agent can finish and conformance-test. The first PR of a language is a client only when every parity row that PR claims is actually running: per-test ids, a warm process, a retry that replaces the earlier result, `remove_failed_test_case_result`, and the group-hook counter (P15). Advertising `select` until the tracer is trustworthy is fine. Advertising a file id is not.

### Python (pytest)

1. **First PR.** Package with the sidecar face, pytest collection, replaced `pytest_runtestloop`, module-fixture counter green, snapshot on the manifest, conformance green, a Django skeleton in CI. Advertise `select`.
2. coverage.py contexts and upload.
3. maturin wheels (manylinux, musllinux, macOS, Windows) and the import-then-sidecar fallback.

The wheel slice is last so the adapter is not waiting on cibuildwheel.

### Java (JUnit Platform, Surefire host)

1. **First PR.** Surefire provider whose `invoke()` discovers, opens the session, and `execute`s unique ids one at a time. `@BeforeAll` counter green. Conformance on JDK 17 and 21, in a forked Surefire JVM. The classpath-fed main is in this PR as the mock-server harness.
2. Gradle plugin or test-worker host, same launcher.
3. JaCoCo dump-and-reset and class-to-source mapping. Advertise `select` until a fragment path is a snapshot key.

### PHP (PHPUnit, then Pest)

1. **First PR.** Composer package, sidecar session, one-method `TestSuite` in the booted process, `BeforeClass` counter green, conformance on PHPUnit 10, 11, 12, and 13, plus a Laravel skeleton.
2. PCOV per-test coverage and upload.
3. `selective/pest` repository: Pest bootstrap, same session, its own conformance file of Pest-style names.

### JavaScript (Vitest, then Jest)

1. **First PR, core plus Vitest.** `selective-js-core` on the sidecar. Vitest `createVitest`, `standalone`, `parseSpecifications`, `collectTests` for dynamic cases, `runTestSpecifications` with one `testIds` entry per call, one fork, `beforeAll` counter green, conformance green. napi packages can land in this PR or the next; the sidecar works first.
2. napi `optionalDependencies` and the `dlopen` fallback. v8 coverage, with transformed URLs resolved to git paths before we advertise `record`.
3. **Jest PR.** Jest 29 watch-loop driver (`runInBand`, programmatic config, not the CLI `--watch` flag) in `selective-js-jest`, circus collection, `beforeAll` counter green. Jest 30 is a follow-up on that pin. A red counter sends the work back to the watch loop or the long-lived `jest-worker` farm. It does not change the manifest to file paths.

### Elixir (ExUnit)

1. **First PR.** Mix project, stdio binary, Port, session loop, `only_test_ids` plus `ExUnit.run/1` one id at a time, `setup_all` counter green, `transport --snapshot` on the manifest, conformance green. Advertise `select`. Replace `mix test` on one internal app.
2. `:cover` around each test, fragment upload, advertise `record`.
3. Hex publish path: checksummed `priv/transport`, README, GitHub Action example.

The private `ExUnit.Runner` module is not on this path. Pin the Elixir versions CI already runs.

## Conformance before publish

A client slice is mergeable when:

- The transport scenarios pass, including reconnect, a repeated id, `remove_failed_test_case_result` from a simulated other runner, `close` with an integer status, and `SIGTERM` after a failure.
- A sample project (Django, a Surefire suite, Laravel, a Vitest package, Phoenix) runs a subset and exits with the framework status.
- The group-hook counter for that framework is greater than one across two batches of the same group (`setup_all`, `@BeforeAll`, `BeforeClass`, `beforeAll`, or a module-scoped fixture), and the suite hook ran once.
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
