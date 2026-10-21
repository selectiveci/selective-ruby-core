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
| P3 | `session.items` after collection. `pytest --collect-only` in a subprocess is the Ruby dry-run if in-process collection disturbs plugins; prefer in-process. Empty items exit 1. | proven |
| P5–P7, P20 | `pytest_runtest_makereport`. A test is `failed` when its setup, call, or teardown report failed (pytest's own `testsfailed` rule). Otherwise `skipped` maps to `pending`. Project frame first. Exit 1 for any remaining `failed` test, whichever phase failed. | proven |
| P8, P9 | Before a repeated id, drop the earlier report from junitxml and pytest-html. Those plugins keep results on private objects, so this row is not a public hook. `remove_failed` deletes by node id. | feasible with risk |
| P15, P16 | RSpec's `:all` → `:each` means module, class, and package fixtures run again for every assigned test. Session fixtures stay up (`before(:suite)`). `SetupState.teardown_exact(None)` tears the session stack down too, so the idle gap between batches must not pass `nextitem=None`. After each item, finish fixture defs whose scope is not `session` and leave the session stack. Time those re-entries for P16. Pin the pytest series in CI and assert a module fixture's setup count equals the number of assigned tests. | feasible with risk |
| P17 | Collection loads modules once. The run loop does not re-import. | proven |
| P18 | The Selective command accepts the same paths, `-k`, `-m`, and ini config pytest would have used. `selective exec pytest` collects and returns without a socket. | proven |
| P21 | In-process concurrency (`pytest-xdist` workers, `pytest-parallel`) is off under this command so coverage contexts stay on one id. The server's batches are the parallelism. | proven |
| P22 | Two collected items that would share a node id get a warning and a suffix so both ship in the manifest. Importlib import mode is the wrong example: it already gives same-named files distinct node ids. The collision is two items whose node ids are actually equal. | proven |
| P28 | coverage.py `Coverage(source=project, data_file=None)`. Record mode sets the core to ctrace before any test (`COVERAGE_CORE=ctrace`, or `cov.set_option("run:core", "ctrace")`), including when the client reuses pytest-cov's instance. Then `dict(cov.sys_info())["core"] == "CTracer"`. Otherwise advertise `select`. On CPython 3.14+ the default core is SysMonitor. It attributes disjoint files, and it gives a shared line only to the first test that ran it, so a later test's fragment omits that file. `switch_context(nodeid)` from `pytest_runtest_setup` through fixture teardown. Ignore `site-packages`, the virtualenv, and `SELECTIVE_TEST_MAP_IGNORE`. A test that spawns a process stays out of the fragment until the child is measured, so the server still selects it as new. | feasible with risk |
| P32 | The plugin owns `pytest_runtestloop`, so pytest does not run the suite during collection. | proven |

xdist holds one item back so `nextitem` is the following test and fixture finalizers can see it. Between Selective batches the next id is unknown. Passing `nextitem=None` finalizes the whole stack, including session fixtures, which breaks P14. Finish non-session fixtures between batches and keep session fixtures. `SetupState.teardown_exact` and `session._setupstate` are private. `FixtureDef.finish()` on the non-session defs cached for that item is the same private operation. Dropping an earlier junitxml or pytest-html report (P8) also goes through those plugins' private stores. P15 is not the only private surface.

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
- Set the core to ctrace for record mode, before the first test: `COVERAGE_CORE=ctrace` or `cov.set_option("run:core", "ctrace")`. Do this on the instance pytest-cov already started, too. Check `dict(cov.sys_info())["core"] == "CTracer"`. If it is not, advertise `select` and warn. On CPython 3.14+ the default is SysMonitor. Disjoint files still attribute. A line both tests ran is recorded only for the first test, and the later test's fragment omits that file.
- `switch_context(nodeid)` in `pytest_runtest_setup`, and read the files measured for that context after the test (including fixture setup and teardown).
- Ignore `site-packages`, the virtualenv, and `SELECTIVE_TEST_MAP_IGNORE`.
- Advertise `record` only when `coverage` imports and the core check above passes. If `coverage` does not import, advertise `select` and warn. Do not make `coverage` a hard dependency of merely running a subset; make it a dependency of the wheel so recording works by default, and catch `ImportError`. This note does not set a Python floor beyond recording the fact that 3.14+ is where SysMonitor is the default. The CI floor is chosen in the first PR.

pytest-cov owns the coverage singleton if the suite already enabled it. Detect that and use the running `Coverage` instance rather than starting a second tracer. Two tracers in one process is the failure mode Ruby hit with SimpleCov.

CTracer is fast enough that we should not write our own. Per-test file sets are what the fragment stores. Contexts give that directly when the core is CTracer. SysMonitor is not that tracer.

The server full-runs a changed path only when no test traces it (`selector.ex`: a path in the suite or already traced stays in selection; otherwise the run is `untraced_change`). A dependency missed through a subprocess is a silent skip whenever another test traces the same file. Until child processes are measured, a test that starts one (a Django `LiveServer` in another process, `multiprocessing`) stays out of the fragment, so the server keeps selecting it as new.

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
- Full-run patterns for `conftest.py`, `pytest.ini`, `pyproject.toml`, `requirements*.txt`, `uv.lock`, Django `settings.py`, and migration packages belong on the server.

## Effort

Medium. Three slices: sidecar session plus the pytest run loop until conformance is green, including the module-fixture counter; coverage.py contexts on ctrace, a two-tests-share-a-helper fixture, and upload; cibuildwheel matrix including musl and Windows. The wheel matrix is the part that looks like a project of its own; cibuildwheel is the whole answer, do not hand-roll images.

Ship the sidecar path first inside the Python repo so conformance does not wait on wheels, then turn the same Python session object onto the extension. One repository, `selectiveci/selective-python-pytest`.

## Prior art

- pytest-xdist: worker/controller protocol, `pytest_runtestloop`, load scheduling. Copy the worker loop. Leave the controller to Selective.
- pytest-split: static split by duration. Not dynamic.
- pytest-testmon: local selection from coverage.py data. Same tracing idea, no hosted queue.
- Datadog Test Impact Analysis and CloudBees Smart Tests: the hosted competitors. Their clients are the UX bar for "replace `pytest` with one command."
