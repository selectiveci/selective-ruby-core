# Build plan

Design only. No new client repository is created by this document. Order follows the marketing note: Elixir, Python, PHP, JavaScript, Java. Elixir starts even if the request form is empty, because we can dogfood it. The others wait on the trigger in that note (design partners) unless we choose otherwise.

The contract is [SPEC.md](SPEC.md). Language notes: [elixir.md](elixir.md), [python.md](python.md), [php.md](php.md), [javascript.md](javascript.md), [java.md](java.md).

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
| `selectiveci/selective-java-junit` | Sidecar session, launcher CLI, then Surefire | transport binary |

Each client runs the transport repo's conformance scenarios in CI. A green local mock is not a private copy of the scenarios.

Server follow-ups, not client repositories: per-language full-run patterns (`mix.exs`, `conftest.py`, `phpunit.xml`, `vitest.config.ts`, `pom.xml`, lockfiles, migrations). Until those exist, an untraced change full-runs, which is safe. The systemic-failure backtrace filter is Ruby-specific; clients put a repo-relative frame first so the current filter still groups.

`setup-selective` stays as it is. It is already language-agnostic.

## Slices per language

Each slice is a PR an agent can finish and conformance-test. "First PR" is the first one that talks to the mock and runs a real suite subset.

### Elixir

1. **First PR.** Mix project, download the stdio binary, Port, session loop, ExUnit discovery and batch execution, `transport --snapshot` on the manifest, conformance green. Advertise `select`. Replace `mix test` on one internal app.
2. `:cover` around each test, fragment upload, advertise `record`.
3. Hex publish path: checksummed `priv/transport`, README, GitHub Action example.

Risk to watch in PR 1: `ExUnit.Runner` is private. Pin Elixir versions in CI.

### Python

1. **First PR.** Package with the sidecar face only, pytest collection and a replaced run loop, snapshot on the manifest, conformance green, a Django skeleton in CI. Advertise `select`.
2. coverage.py contexts and upload.
3. maturin wheels (manylinux, musllinux, macOS, Windows) and the import-then-sidecar fallback.

The wheel slice is last so the adapter is not blocked on cibuildwheel.

### PHP

1. **First PR.** Composer package, sidecar session, PHPUnit 10+ discovery and in-process batches, conformance on 10, 11, and 12, plus a Laravel skeleton.
2. PCOV per-test coverage and upload.
3. `selective/pest` repository: Pest bootstrap, same session, its own conformance file of Pest-style names.

### JavaScript

1. **First PR, core plus Vitest.** `selective-js-core` on the sidecar, Vitest `createVitest` and `runTestSpecifications`, one worker, conformance green. napi packages can land in this PR or the next; the sidecar must work first.
2. napi `optionalDependencies` and the `dlopen` fallback. v8 coverage, with transformed URLs resolved to git paths before we advertise `record`.
3. **Jest PR.** Circus collection in `selective-js-jest` against the same core. If per-test deferral is unstable, ship file-level ids and say so in the README rather than blocking the repository.

### Java

1. **First PR.** Pure-Java CLI, sidecar, JUnit Platform discover and `execute` by unique id, conformance on JDK 17 and 21.
2. Surefire provider so `mvn test` can delegate without a hand-built classpath.
3. Gradle plugin.
4. JaCoCo dump-and-reset, class file to source path. Advertise `select` until this is right.

## Conformance before publish

A client slice is mergeable when:

- The transport scenarios pass, including reconnect, a repeated id, `remove_failed_test_case_result` from a simulated other runner, `close` with an integer status, and `SIGTERM` after a failure.
- A sample project (Phoenix, Django, Laravel, a Vitest package, a Surefire project) runs a subset and exits with the framework status.
- Recording slices additionally upload a fragment whose paths are keys in the snapshot.
- Install does not require a compiler, except the PyO3 and napi release workflows themselves.

Do not publish to Hex, PyPI, Packagist, npm, or Maven Central from the first PR. Publishing is the last slice of each language, after a design partner has run it.

## What we are not doing

- A WebSocket client in Elixir, Python, PHP, Node, or Java.
- Rustler NIFs, `ext-php-rs`, JNI, or Panama as the transport.
- Porting `selective_tracer`.
- Playwright, TestNG, Django's runner, or a second JS test runner besides Jest and Vitest, until a partner asks.
- A hosted selector inside Nx, Turborepo, or Develocity.
