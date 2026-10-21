# Python (pytest)

Marketing order: second. pytest is the client to build. It also collects `unittest` tests, so one adapter covers Django and the stdlib runner. Django's own `manage.py test` runner is a later adapter if a design partner needs it.

Read [SPEC.md](SPEC.md) for the wire contract.

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

xdist's "keep one test queued so `nextitem` is set" detail matters for fixture finalizers. When the server has not yet sent the next id, pass `nextitem=None` for the last test of the batch. Finalizers still run; they just cannot see the following item. That matches a worker that is about to go idle.

## Coverage (test map)

coverage.py is the tracer. It is the same data pytest-cov and pytest-testmon already collect.

- Start `Coverage` with `source` set to the project root, branch measurement off, data file disabled.
- `switch_context(nodeid)` in `pytest_runtest_setup`, and read the files measured for that context after the test (including fixture setup and teardown).
- Ignore `site-packages`, the virtualenv, and `SELECTIVE_TEST_MAP_IGNORE`.
- Advertise `record` when `coverage` imports. If it does not, advertise `select` and warn. Do not make `coverage` a hard dependency of merely running a subset; make it a dependency of the wheel so recording works by default, and catch `ImportError`.

pytest-cov owns the coverage singleton if the suite already enabled it. Detect that and use the running `Coverage` instance rather than starting a second tracer. Two tracers in one process is the failure mode Ruby hit with SimpleCov.

The C tracer in coverage.py is fast enough that we should not write our own. Per-test file sets are what the fragment stores. Contexts give that directly.

Subprocess tests (a Django `LiveServer` in another process, `multiprocessing`) are invisible unless the child starts coverage too. Document that. The server full-runs on an untraced changed file, so a missed subprocess dependency is safe and expensive, not a silent skip.

## Packaging and CI

- PyPI: `selective-pytest`. Console script `selective` so CI changes `pytest` to `selective pytest`.
- Wheels carry the extension. The sidecar fallback binary is downloaded on first use from the transport release, checksummed, cached under the user cache directory, overridable with `SELECTIVE_TRANSPORT`.
- classifiers and `requires-python` should match what we run in CI (3.9+ or whatever a design partner forces; decide at the first PR, do not guess a floor in code before that).
- GitHub Action is unchanged. `runner-id` is the matrix index.

## Risks

- pytest's run loop is public, but plugins that wrap `pytest_runtest_protocol` assume they see every item in collection order. Holding the loop and running a subset surprises plugins that zip reports against `session.items`. Run conformance with pytest-django, pytest-xdist **not** loaded, and a junitxml plugin. Tell users to remove `-n` from the Selective command: xdist would schedule a second time inside a shard.
- Collection order can differ across processes when a plugin walks the filesystem in an unstable order. Node ids are the identity, so the set is what matters. The server asks one runner for the manifest (the first open socket) and the others only execute. Any shard can be that runner, including after a reconnect, so every process collects and caches the collection.
- `coverage` plus pytest-cov double-start.
- HTTP stubs swallowing the fragment upload. The Rust upload helper avoids that. Do not use `urllib` inside the test process.
- Full-run patterns for `conftest.py`, `pytest.ini`, `pyproject.toml`, `requirements*.txt`, `uv.lock`, Django `settings.py`, and migration packages belong on the server.

## Effort

Medium. Three slices: PyO3 session (or sidecar first, extension in the same PR if it stays small) plus the pytest run-loop until conformance is green; coverage.py contexts and upload; cibuildwheel matrix including musl and Windows. The run loop is smaller than ExUnit's because the hooks are public. The wheel matrix is the part that looks like a project of its own; cibuildwheel is the whole answer, do not hand-roll images.

Ship the sidecar path first inside the Python repo so conformance does not wait on wheels, then turn the same Python session object onto the extension. One repository, `selectiveci/selective-python-pytest`.

## Prior art

- pytest-xdist: worker/controller protocol, `pytest_runtestloop`, load scheduling. Copy the worker loop. Leave the controller to Selective.
- pytest-split: static split by duration. Not dynamic.
- pytest-testmon: local selection from coverage.py data. Same tracing idea, no hosted queue.
- Datadog Test Impact Analysis and CloudBees Smart Tests: the hosted competitors. Their clients are the UX bar for "replace `pytest` with one command."
