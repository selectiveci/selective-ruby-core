# PHP (PHPUnit, then Pest)

Marketing order: third. Feasibility of full parity: third. PHPUnit is the base. Pest runs on top of PHPUnit, so the Pest package is a bootstrap on the PHPUnit client, not a second session loop. ParaTest and `pest --parallel` are local process pools. `pest --dirty` is changed files. Both are outside the parity bar.

Read [SPEC.md](SPEC.md) for the wire contract and the parity bar.

**Verdict: feasible with risk.** PHPUnit 10 through 13 have no `TestResult`. `TestSuite::run()` returns void, and the result facade is a process-global collector with no reset. `TestSuite::run()` checks `TestResultFacade::shouldStop()` against that collector. Nine flags can latch it: `stopOnDefect`, `stopOnError`, `stopOnFailure`, `stopOnWarning`, `stopOnRisky`, `stopOnIncomplete`, `stopOnSkipped`, `stopOnNotice`, and `stopOnDeprecation`. On PHPUnit 13 the names are the `…Threshold` forms. There is no public API to clear them. Before `Registry::init`, write a copy of `phpunit.xml` beside the original with all nine false, and strip `--stop-on-*` from the forwarded argv. On 13, do not install the SIGINT or time-limit handlers. An assigned id with no outcome after `run()` is reported `failed`. No row is blocked. No fork. PHPUnit's draft parallel worker (PR 6784; the surviving patch id is `4c649e05`, and `52db4ed` is no longer in that PR's history) is an existence proof of a process that boots once and runs many tests. Its scheduler hands out classes, and ours hands out methods, so we do not adopt that scheduler. `TestSuite`, the `TestCase` constructor, and `setData` are `@internal` on 10+. PHPUnit 13 adds emitter arguments to that constructor.

## Parity

Rows P4, P10–P14, P16, P19, P23–P27, and P29–P31 are the session loop on `transport --stdio`. Port of `Controller`. Rating: proven.

| Id | Mechanism | Rating |
|---|---|---|
| P1 | One PHP process. Boot through PHPUnit's configuration and bootstrap once. Build each class with `TestSuite::fromClassReflector` and narrow it with `setTests()` to the assigned ids, then call `TestSuite::run()`. `TestSuite::empty()` plus `addTest(new ClassName('methodName'))` leaves `isForTestClass()` false, so `setUpBeforeClass` and `tearDownAfterClass` never run (measured on 10.5.66, 11.5.57, 12.5.40, and 13.4.3). There is no `TestResult` argument on 10, 11, 12, or 13. The Laravel application stays booted. Do not spawn a PHPUnit process per batch (that is ParaTest's chunk model). All nine stop flags are false in the copied `phpunit.xml` before `Registry::init`, and `--stop-on-*` is stripped from argv. On 13, do not install SIGINT or time-limit handlers. One method per `run()` so class hooks re-enter (P15). | feasible with risk |
| P2 | `Class::method`, and the data-set id from `--list-tests-xml` (`Class::method#dataset`). PHPUnit 10.5 writes `testCaseClass` / `testCaseMethod`. PHPUnit 11 and later write a `testSuite` document with `testClass` / `testMethod`. Text-mode `--list-tests` prints `Class::method"name"` for a named data set. Prefer the XML id for that major. It survives a line shift. | proven |
| P3 | `--list-tests-xml` (or the suite built and not run) for discovery. Bodies have not run. Empty list exits 1. Cases come from `TestSuite::fromClassReflector`, then `setTests()` keeps the assigned ids. Do not call `setData` with provider keys: `setData(3, [3])` is listed as `#0` because integer keys are renumbered. `setData` and the `TestCase` constructor are `@internal`. `TestBuilder` stayed in `PHPUnit\Framework` from 9.6 through 13.4. What changed is its signature, not its namespace. Stay off it anyway. Providers must be deterministic, because they execute at build time; cache the built cases. | feasible with risk |
| P5–P7, P20 | An Extension subscriber writes the client's own per-id store. The process-global facade is not the store: it has no reset, and one failure stays latched. Errors and failures map to `failed`, skipped and incomplete to `pending`, the rest to `passed`. An assigned id with no outcome after `run()` is `failed`. Project frame first. Exit 1 when any remaining assigned test in that store is a hard failure. | feasible with risk |
| P8, P9 | Retries replace the entry in the client's per-id store. The facade still counts a failure the retry replaced, so exit status does not read the facade. `remove_failed` matches class, method, and data-set name. | feasible with risk |
| P15, P16 | One test per `TestSuite::run`, built with `fromClassReflector` and narrowed with `setTests()`, re-enters `#[BeforeClass]` / `setUpBeforeClass`, which is the RSpec `:all` → `:each` rule. A suite of two methods from one class runs `BeforeClass` once and is short of parity. `TestSuite::empty()` plus `addTest` does not re-enter those hooks. `BeforeClass` time goes to `seconds_in_*_all_hooks`. Suite bootstrap stays once (P14). | feasible with risk |
| P17 | The bootstrap and the class files stay loaded. `require` runs once. | proven |
| P18 | `phpunit.xml`, `--filter`, `--testsuite`, and `--group` bound discovery the way `vendor/bin/phpunit` would have. `selective exec phpunit` lists tests and does not open a socket. | proven |
| P21 | `pest --parallel` and ParaTest stay off. Coverage is per process. The assigned ids run one at a time in this process. | proven |
| P22 | Two methods cannot share a name on one class. A data set whose name repeats gets a warning and a suffix. | proven |
| P28 | When `record: true` and the `pcov` extension is loaded, `SebastianBergmann\CodeCoverage` `start($id)` / `stop()` around the test, including `setUp` and `tearDown`. Ignore `vendor/` and `SELECTIVE_TEST_MAP_IGNORE`. Xdebug is slower; use it only when PCOV is absent and the user opted in. Advertise `select` when neither is loaded. Installing the package does not require PCOV. | proven |
| P32 | The script is `vendor/bin/selective`. It does not call PHPUnit's `Application::run` in a way that executes and exits before the socket loop. Extensions from `phpunit.xml` still load. | proven |

ParaTest's `WrapperRunner` (`--functional`) is the same shape: one worker, bootstrap once, one method at a time. PHPUnit PR 6784 (surviving patch id `4c649e05`; `52db4ed` is no longer in that PR's history; distribution unit is one class so `BeforeClass` stays once per class) shows the project itself now wants a persistent worker. Our unit is one method because of P15. One method per `fromClassReflector` suite is what re-enters `BeforeClass`. Per-major conformance sets each of the nine stop flags, lets batch 1 trip it, and requires batch 2 to run.

## Binding

**Stdio sidecar only.** Not `ext-php-rs`, not `ext-ffi`.

An `ext-php-rs` extension is a real `.so` with a stable Rust story, and it is the wrong distribution. PHP extensions are one build per PHP minor (8.2, 8.3, 8.4, and the next), per ZTS or NTS, per arch. CI images often have no compiler. `pecl install` failing is the same class of incident as a Ruby native extension that does not build, except here the extension would be the transport itself, so a build failure would take the whole client down rather than just recording.

`FFI` can call a cdylib without a custom extension, but `ffi.enable` defaults to preload-only and many hosts set it to `false`. We would still ship a `.so` per arch.

The sidecar is one binary, spawned with `proc_open`, URL in the environment, newline JSON on the pipes. PHP does not open a WebSocket. `symfony/process` is fine; so is `proc_open`. Snapshot and upload are `transport --snapshot` and `transport --upload-fragment`.

v1 targets: Linux gnu x86_64 and aarch64, macOS x86_64 and aarch64, plus musl once the transport matrix has it (Alpine PHP images are common). Windows PHP exists for local dev and is not a v1 blocker; the stdio binary covers it when the Windows archive exists. Download on first `vendor/bin/selective` run, checksum, cache in `~/.selective/transport/<version>/`, override with `SELECTIVE_TRANSPORT`. If the binary is missing, exit 1.

## Discovery and running a subset

PHPUnit extension subscribers observe a run. They do not pause it, and they are how results reach the client's store, because `run()` returns void. `--filter` is fixed before `Application` starts. The client is the process: it builds each class with `TestSuite::fromClassReflector`, narrows with `setTests()`, and calls `run()` on the already-booted bootstrap. The copied `phpunit.xml` has all nine stop flags false, and `--stop-on-*` is not forwarded.

Support PHPUnit 10 and later. CI runs 10, 11, 12, and 13. The file allowed to construct cases is the adapter's suite builder. It uses `fromClassReflector` and `setTests()`, not `TestSuite::addTest(new TestCase)` and not `TestBuilder`. `--list-tests-xml` is read with the 10.5 element names on 10 and the 11+ names after that.

Pest's `it()` / `test()` names are the ids in Pest output. The Pest package depends on the PHPUnit package, registers `Pest.php`, and uses this runner. `pest --parallel` stays off.

## Coverage (test map)

PCOV is the tracer. Xdebug is the fallback and is too slow to turn on for every recording run if PCOV is present.

PHPUnit already knows how to do per-test coverage: `SebastianBergmann\CodeCoverage` `start($id)` and `stop()` around a test, with the PCOV driver. The adapter does that when `record: true`, including `setUp` and `tearDown`. Files come from the coverage data for that id. Ignore `vendor/` and `SELECTIVE_TEST_MAP_IGNORE`.

Advertise `record` when the `pcov` extension is loaded, `select` when it is not. Do not require PCOV to install the package. The warning tells the user to install the `pcov` extension (a distro package, not a compiler step for our code).

PCOV is per process. Tests that shell out miss those files. Same tradeoff as everywhere else.

## Packaging and CI

- Packagist: `selective/phpunit`, later `selective/pest`.
- Composer bin: `vendor/bin/selective`. CI changes `vendor/bin/phpunit` to `vendor/bin/selective phpunit`.
- No PHP extension in the package. `composer require` must succeed with only PHP.
- The GitHub Action is unchanged.

## Risks

- Data-provider construction is the row that moves between majors. The matrix is PHPUnit 10, 11, 12, and 13. The suite builder is the only file that constructs cases. It uses `TestSuite::fromClassReflector` and `setTests()`. Both are `@internal`, and 13 adds emitter arguments, so the pin is what catches a signature change. Each of the nine stop flags is a conformance case.
- Laravel's `CreatesApplication` and `RefreshDatabase` assume they run inside PHPUnit's lifecycle. Building our own suite and skipping that lifecycle is the bug to avoid. Run a Laravel skeleton in CI, not only bare PHPUnit.
- Data providers that generate different sets on different shards (random, time) produce manifests the server cannot reconcile. Document that providers must be deterministic. Ruby has the same constraint and does not solve it.
- Pest's architecture plugins that swap the test runner. Re-test when Pest majors.
- Server full-run patterns need `composer.lock`, `phpunit.xml`, `pest.php`, `tests/Pest.php`, `tests/TestCase.php`, and Laravel migrations.

## Effort

Sidecar integration is the small slice. The PHPUnit library runner is the large slice, mostly because of version skew and Laravel boot, not because of the protocol. Pest is a follow-up package in `selectiveci/selective-php-pest` that should be thin. Recording with PCOV is a third slice on the PHPUnit repo, smaller than the runner.

Repositories: `selectiveci/selective-php-phpunit`, then `selectiveci/selective-php-pest`.

## Prior art

- ParaTest: process pool, file or test distribution, wrappers around PHPUnit's CLI. Useful as a reference for result XML, not as the runtime.
- `pest --parallel`: ParaTest underneath.
- `pest --dirty`: git dirty files only.
