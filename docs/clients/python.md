# Python (pytest)

Marketing order: second. Feasibility of full parity: first. pytest is the client to build. It also collects `unittest` tests, so one adapter covers Django and the stdlib runner. Django's own `manage.py test` runner is a later adapter if a design partner needs it.

Read [SPEC.md](SPEC.md) for the wire contract and the parity bar.

**Verdict: proven for the split.** The worker loop pytest-xdist already runs in production is the Selective loop with the controller removed. P15, re-entering module and class fixtures without tearing the session down, is feasible with risk because it goes through pytest's setup stack. No row is blocked. No fork.

## Parity

Rows P4, P10–P14, P16, P19, P23–P27, and P29–P31 are the session loop, on the PyO3 binding or `transport --stdio`. Port of `Controller`. Rating: proven.

| Id | Mechanism | Rating |
|---|---|---|
| P1 | One pytest process. Collect once, replace `pytest_runtestloop`, and on each `run_test_cases` call `pytest_runtest_protocol` for those items. The process stays up, so session fixtures and Django setup stay warm. Do not register `pytest_xdist_make_scheduler`: the controller is the Selective server. Do not load `pytest-xdist -n` under this command, and do not shell `pytest nodeid` per batch. | proven |
| P2 | Node id (`tests/test_billing.py::TestTax::test_round`). Plugins already key on it. It survives a line shift. | proven |
| P3 | `session.items` after collection. `pytest --collect-only` in a subprocess is the Ruby dry-run if in-process collection disturbs plugins; prefer in-process. A failed `CollectReport` exits non-zero before the manifest: pytest's own code is 2, unless `--continue-on-collection-errors`, which exits 1 to match native pytest. Empty items exit 1. Replacing `pytest_runtestloop` skips pytest's "Interrupted: N errors during collection" check, so the adapter applies this exit itself. | proven |
| P5–P7, P20 | `pytest_runtest_makereport`. A test is `failed` when the latest setup, call, or teardown report for that id failed. Otherwise `skipped` maps to `pending`. Project frame first. Exit status is computed from that per-id store plus any failed `CollectReport`, and written to `session.exitstatus` from a `trylast` `pytest_sessionfinish`. Do not read `session.testsfailed`: it also counts collect reports and never decrements when a retry replaces a failure. Exit 1 for any remaining `failed` test, whichever phase failed, or for a failed collect report. | proven |
| P8, P9 | Before a repeated id, drop the earlier report from junitxml and pytest-html. Those plugins keep results on private objects, so this row is not a public hook. `remove_failed` deletes by node id. | feasible with risk |
| P15, P16 | RSpec's `:all` → `:each` means module, class, and package fixtures run again for every assigned test. Session fixtures stay up (`before(:suite)`). Tear the stack down to the session node between items. `session._setupstate.teardown_exact(session)` does that (private), and `nextitem=session` is the same request off pytest's public contract. `FixtureDef.finish()` on the cached non-session defs is not that operation: it hits `AssertionError: previous item was not torn down properly` and later bodies never run. `SetupState.teardown_exact(None)` and `nextitem=None` tear the session stack down too, so the idle gap between batches must not pass `nextitem=None`. Time those re-entries for P16. Pin the pytest series in CI and assert a module fixture's setup count equals the number of assigned tests. | feasible with risk |
| P17 | Collection loads modules once. The run loop does not re-import. | proven |
| P18 | The Selective command accepts the same paths, `-k`, `-m`, and ini config pytest would have used. `selective exec pytest` collects and returns without a socket. | proven |
| P21 | In-process concurrency (`pytest-xdist` workers, `pytest-parallel`) is off under this command so coverage contexts stay on one id. The server's batches are the parallelism. | proven |
| P22 | Two collected items that would share a node id get a warning and a suffix so both ship in the manifest. Importlib import mode is the wrong example: it already gives same-named files distinct node ids. The real case is `--keep-duplicates`, or a custom collector that emits two items with the same node id. | proven |
| P28 | coverage.py `Coverage(source=project, data_file=None)`. Under `selective pytest`, the console script sets `COVERAGE_CORE=ctrace` before pytest starts. `set_option("run:core", "ctrace")` is used only on an instance the client builds, and only before `start()`. Calling it after `start()` is inert (`core` stays `SysMonitor`). It is also inert on pytest-cov's instance, which starts `Coverage` in `pytest_load_initial_conftests`. Never `stop` / `erase` / `start` that instance: doing so wiped a user's report from 100% to 60%. Read `dict(cov.sys_info())["core"]` after `start()` (before `start()` it is `'-none-'`). Require `CTracer`. Otherwise advertise `select`. The guard is truthful, so a wrong core falls back to `select` and does not upload a fragment. On CPython 3.14+ the default core is SysMonitor. It attributes disjoint files, and it gives a shared line only to the first test that ran it, so a later test's fragment omits that file. `switch_context(nodeid)` from `pytest_runtest_setup` through fixture teardown. Ignore `site-packages`, the virtualenv, and `SELECTIVE_TEST_MAP_IGNORE`. Detect spawns with `sys.addaudithook` (`subprocess.Popen`, `os.fork`, `os.posix_spawn`, `os.system`, `os.exec*`, and a multiprocessing start). Exclude every test whose fixture closure includes a spawning fixture of any scope. A session-scoped fixture's `Popen` is attributed only to its first user, so that exclusion is by closure, not by "who ran during the test." Django `LiveServer` is a thread (`LiveServerThread`), not a process; it is not the spawn example. A test that spawns a process stays out of the fragment until the child is measured, so the server still selects it as new. | feasible with risk |
| P32 | The plugin owns `pytest_runtestloop`, so pytest does not run the suite during collection. | proven |

xdist holds one item back so `nextitem` is the following test and fixture finalizers can see it. Between Selective batches the next id is unknown. Passing `nextitem=None` finalizes the whole stack, including session fixtures, which breaks P14. Tear down to the session node and keep session fixtures. `session._setupstate.teardown_exact(session)` is private. `nextitem=session` asks for the same teardown and is off pytest's contract. `FixtureDef.finish()` on the non-session defs cached for that item is not equivalent: the runner then raises `AssertionError: previous item was not torn down properly` and later bodies never run. Dropping an earlier junitxml or pytest-html report (P8) also goes through those plugins' private stores. P15 is not the only private surface. The module-fixture counter is what makes a wrong teardown loud.

## Binding

**PyO3 and maturin for the primary artifact. The stdio sidecar is the fallback, not a second protocol.**

Ship a wheel that links the `selective-transport` crate and exposes `connect`, `recv`, `send`, `close`, `snapshot_tree`, and `upload_fragment`. maturin with cibuildwheel is how this class of package is released (the same shape as `pydantic-core` and `watchfiles`). Build manylinux and musllinux, macOS x86_64 and arm64, and Windows x86_64. Windows matters for local `pytest` even when CI is Linux. Skip Windows arm64 and PyPy in v1.

If the extension fails to import (PyPy, a musl wheel that was not published, a corporate interpreter with an unusual ABI), spawn `transport --stdio` the same way and keep the session loop. Do not add a `websockets` dependency as a third path. The import error and the spawn error both exit 1 only when neither face can connect.

Build the extension from the crate (a git dependency or a submodule), the way other PyO3 projects do. Do not load Ruby's `transport` executable as a Python module.

## Discovery and running a subset

pytest's public hooks are the best fit of the five languages.

pytest-xdist is the pattern to copy, not the process model to shell out to:

- Each worker collects the full suite and sends node ids to a controller.
- The controller checks the collections match, then sends work in chunks.
- A worker replaces `pytest_runtestloop` and sits idle. When indexes arrive it runs `pytest_runtest_protocol` for those items. It holds one item back so `nextitem` (fixture teardown of the previous test) is known.
- `pytest_xdist_make_scheduler` is how a custom distributor plugs in. We do not plug in there: our controller is the Selective server, and there is one process per CI shard, not a local controller plus workers.

The Selective adapter is one pytest process that behaves like an xdist worker whose controller is remote:

1. Collect once (`pytest_collection_modifyitems` / the session's `items`). Node ids (`tests/test_billing.py::TestTax::test_round`) are the manifest ids. They survive line shifts and are what pytest plugins already key on.
2. Connect, send the manifest (file paths from `item.location` / `item.path`).
3. Replace the run loop. Wait for `run_test_cases`, resolve ids to items, run `pytest_runtest_protocol`.
4. Publish results from `pytest_runtest_makereport`. `passed`, `failed`, and `skipped` map to `passed`, `failed`, and `pending`.
5. On a repeated id, drop the earlier report from any plugin that stores results (pytest-html, junitxml) before the new run, matching the Minitest duplicate-reporter bug.

`pytest --collect-only` in a subprocess is the Ruby dry-run equivalent if collection in the main process disturbs plugins. Prefer in-process collection; a subprocess pays import time twice on a Django settings module.

Do not shell `pytest nodeid` per batch. Django setup and a large conftest make that slower than the selection we are trying to buy.

xdist keeps one item queued so `nextitem` is known. Copy that inside a batch. At the boundary between batches, finish module, class, and package fixtures and keep session fixtures (P15). `nextitem=None` is the end of the session, and it is the wrong signal while the process is still waiting for the server.

## Coverage (test map)

coverage.py is the tracer. It is the same data pytest-cov and pytest-testmon already collect.

- Start `Coverage` with `source` set to the project root, branch measurement off, data file disabled.
- The `selective pytest` console script sets `COVERAGE_CORE=ctrace` in the environment before pytest starts. On an instance the client builds, `set_option("run:core", "ctrace")` happens before `start()`. After `start()`, `set_option` does not change the core. pytest-cov has already called `start()` by `pytest_load_initial_conftests`, so do not `set_option` on that instance and do not restart it. Read `dict(cov.sys_info())["core"]` after `start()`. Require `CTracer`. If it is not, advertise `select` and warn. On CPython 3.14+ the default is SysMonitor. Disjoint files still attribute. A line both tests ran is recorded only for the first test, and the later test's fragment omits that file.
- `switch_context(nodeid)` in `pytest_runtest_setup`, and read the files measured for that context after the test (including fixture setup and teardown).
- Ignore `site-packages`, the virtualenv, and `SELECTIVE_TEST_MAP_IGNORE`.
- Advertise `record` only when `coverage` imports and the core check above passes. If `coverage` does not import, advertise `select` and warn. Do not make `coverage` a hard dependency of merely running a subset; make it a dependency of the wheel so recording works by default, and catch `ImportError`. This note does not set a Python floor beyond recording the fact that 3.14+ is where SysMonitor is the default. The CI floor is chosen in the first PR.

pytest-cov owns the coverage singleton if the suite already enabled it. Detect that and use the running `Coverage` instance rather than starting a second tracer. Two tracers in one process is the failure mode Ruby hit with SimpleCov.

CTracer is fast enough that we should not write our own. Per-test file sets are what the fragment stores. Contexts give that directly when the core is CTracer. SysMonitor is not that tracer.

A changed path full-runs when no test traces it, when the path is new, or when it matches a full-run pattern. A file some other test already traced is not a full-run, so a dependency this test reached only through an unmeasured child is a skip. Detect spawns with `sys.addaudithook` and exclude every test whose fixture closure includes a spawning fixture of any scope. A session-scoped fixture's `Popen` is attributed only to its first user. Django `LiveServer` runs on `LiveServerThread`; it is not a spawned process. Until a spawned child is measured, a test that starts one stays out of the fragment, so the server keeps selecting it as new.

## Packaging and CI

- PyPI: `selective-pytest`. Console script `selective` so CI changes `pytest` to `selective pytest`.
- Wheels carry the extension. The sidecar fallback binary is downloaded on first use from the transport release, checksummed, cached under the user cache directory, overridable with `SELECTIVE_TRANSPORT`.
- classifiers and `requires-python` should match what we run in CI (3.9+ or whatever a design partner forces; decide at the first PR, do not guess a floor in code before that).
- GitHub Action is unchanged. `runner-id` is the matrix index.

## Risks

- pytest's run loop is public, but plugins that wrap `pytest_runtest_protocol` assume they see every item in collection order. Holding the loop and running a subset surprises plugins that zip reports against `session.items`. Run conformance with pytest-django, pytest-xdist not loaded, and a junitxml plugin. Users take `-n` off the Selective command: xdist would schedule a second time inside a shard.
- P15 finishes non-session fixtures through `SetupState`, and P8 drops reports from junitxml and pytest-html. Those objects are private. The conformance fixture (a module-scoped fixture that counts setups, and a session-scoped fixture that must stay at 1) is what locks P15. If a pytest release changes the stack, the pin fails CI.
- Collection order can differ across processes when a plugin walks the filesystem in an unstable order. Node ids are the identity, so the set is what matters. The server asks one runner for the manifest (the first open socket) and the others only execute. Any shard can be that runner, including after a reconnect, so every process collects and caches the collection.
- `coverage` plus pytest-cov double-start.
- HTTP stubs swallowing the fragment upload. The Rust upload helper avoids that. Do not use `urllib` inside the test process.
- The Python full-run list already includes `requirements*.txt`, `poetry.lock`, `pyproject.toml`, `setup.cfg`, `conftest.py`, and `tox.ini`. Still to add: `pytest.ini`, `uv.lock`, Django `settings.py`, and migration packages.

## Effort

Medium. Three slices: sidecar session plus the pytest run loop until conformance is green, including the module-fixture counter and a failed `CollectReport` that exits before the manifest; coverage.py contexts with `COVERAGE_CORE=ctrace` set before pytest starts, a two-tests-share-a-helper fixture, spawn detection, and upload; cibuildwheel matrix including musl and Windows. The wheel matrix is the part that looks like a project of its own; cibuildwheel is the whole answer, do not hand-roll images.

Ship the sidecar path first inside the Python repo so conformance does not wait on wheels, then turn the same Python session object onto the extension. One repository, `selectiveci/selective-python-pytest`.

## Prior art

- pytest-xdist: worker/controller protocol, `pytest_runtestloop`, load scheduling. Copy the worker loop. Leave the controller to Selective.
- pytest-split: static split by duration. Not dynamic.
- pytest-testmon: local selection from coverage.py data. Same tracing idea, no hosted queue.
- Datadog Test Impact Analysis and CloudBees Smart Tests: the hosted competitors. Their clients are the UX bar for "replace `pytest` with one command."
