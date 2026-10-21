# JavaScript and TypeScript (Vitest, then Jest)

Marketing order: fourth. Feasibility of full parity: fourth. One language, two frameworks, one core package. **Vitest is the first framework.** Jest is second, on the same core, and it is feasible with risk. Playwright is out of scope until a design partner asks; the runner model is browser processes.

TypeScript is not a separate client. Vitest and Jest both run it.

Read [SPEC.md](SPEC.md) for the wire contract and the parity bar.

**Verdict: feasible with risk. Nothing is blocked, and neither framework needs a fork.** Vitest `>= 4.1.1 < 5` keeps one long-lived main process. A file with any `dynamic: true` entry takes every id from `collectTests`; parse ids are manifest ids only for files with no dynamic tests. The shipping loop puts one id in one spec and one `runTestSpecifications` call, so `beforeAll` re-enters. Each such call boots a new worker. One spec per `moduleId` that lists every id of that file runs them all in one call, and under that shape `beforeAll` runs once per file, which is short of P15. Jest's public `TestSequencer`, `--shard`, and `--listTests` are static and outside the contract. The warm path is a custom `runner` (the public config key that replaces `jest-runner`) with `runInBand`, holding the process until `close` and running assigned names through circus in the parent. `@jest/core` 29.7.0 and 30.5.2 export only `.` and `./package.json`. `@jest/core/build/watch` is not exported. The client does not import it, and it does not pass `--watch`. Knapsack Pro's Jest client (`runCLI` per batch of file paths) leaves workers cold and runs files; that shape is outside the contract.

## Parity

Rows P4, P10–P14, P16, P19, P23–P27, and P29–P31 are the session loop in `@selectiveci/core`, on napi-rs or `transport --stdio`. Port of `Controller`. Rating: proven. The two adapters differ on the rows below.

### Vitest (first)

Pin Vitest `>= 4.1.1 < 5`. `testIds` on `TestSpecification` landed in 4.1.0. `standalone()` landed in 4.1.1; at 4.1.0 only `init()` exists. Vitest 5.0.5 is current, so an open `>= 4.1` admits it. Stay below 5 until the collect-versus-parse rule is re-probed on that major. Under this pin the entry is `experimental_parseSpecifications`. `standalone()` prepares reporters and coverage and does not run tests. Keep the instance for the shard and do not call `close()` between batches.

| Id | Mechanism | Rating |
|---|---|---|
| P1 | `createVitest` once. `globTestSpecifications` to learn the files. The shipping loop is one `createSpecification(moduleId, { testIds: [id] })` and one `runTestSpecifications` call per assigned id, including when two ids share a file. That is what re-enters `beforeAll` (P15). Each call boots a new worker (consecutive calls got different pids). One spec per `moduleId` carrying every id of that file (`createSpecification(moduleId, { testIds: idsForThatFile })`, the shape `toTestSpecification` uses) is what runs every id of the file in one call. Several `createSpecification(moduleId, { testIds: [id] })` objects in one call run only the first id per file; the second is skipped ("No test suite found"), and a skip mapped to `pending` would count as a pass. `rerunTestSpecifications` also emits watcher events; use `runTestSpecifications`. Do not call `startVitest` per batch. A custom `poolRunner` is unprobed and is not the mechanism. | feasible with risk |
| P2 | `TestCase.id` (file hash, suite index, test index). Vitest documents that callers must not parse the id; it can start with a minus. Use it whole. The indexes are positional: inserting a `test.each` row shifts later static ids. The id survives a comment-only line shift. It does not survive an inserted test. `generateFileHash` from `vitest/node` has existed since v3. `TestCase.toTestSpecification()` (4.1+) returns a spec for that case and is the same filter. | proven |
| P3 | `experimental_parseSpecifications` on this pin (rollup `parseAst` over Vite `ssrTransform`, no import following). It counts `test.each` as one entry. Runtime expands the rows, so a later static parse id names the wrong test. If a file has any `dynamic: true` entry, every id in that file comes from `collectTests` (the file executes, callbacks do not, isolation off for that pass). Parse ids are manifest ids only for files with no dynamic tests. A probe on Vitest 4.1.12: the collect id for `z` ran only body `z`. The `-dynamic` postfix cannot filter a run. Pin stays below 5 until this is re-probed on that major. | feasible with risk |
| P5–P7, P20 | A custom reporter's `onTestCaseResult`, forwarded only for assigned ids. `pass` / `fail` / `skip` map to `passed` / `failed` / `pending`. Every batch also fires `skipped` for unassigned siblings. Under `isolate: true` a later skip overwrote a pass for the same `TestCase.id`. A later skip must not overwrite a pass within the batch. Project frame first. | proven |
| P8, P9 | Drop the earlier case result from the reporter's store before the id runs again. `remove_failed` deletes by `TestCase.id`. | proven |
| P15, P16 | `beforeAll` / `afterAll` run for every assigned test. The shipping loop is one id per call, including two ids of the same file, so the hook re-enters. One spec that lists every id of a file runs `beforeAll` once per file per call and is short of this row. Time those hooks for P16. `globalSetup` stays once (P14). | feasible with risk |
| P17 | The main process and the Vite server stay up across calls. The worker does not: each one-id call boots a new worker. Module invalidation is not a warm-worker lever, because the worker is new. A custom `poolRunner` is unprobed and is not how this row is met. | feasible with risk |
| P18 | `include`, `exclude`, `testNamePattern` from the project config, and CLI path filters, bound discovery. `selective exec vitest` collects and returns without a socket. `--shard` and `--changed` are off. | proven |
| P21 | `fileParallelism: false` runs one file at a time. `maxWorkers: 1` with `isolate: false` is one worker within a call, not across calls (see P1). Vitest 4 removed `poolOptions`. `singleFork` is ignored, with a deprecation warning. A parent-only trace is empty if tests run in a worker we do not wrap. The first recording PR asserts the fragment names a project source file. | proven |
| P22 | A dynamic id that collides after `collectTests` gets a warning and a suffix. | proven |
| P28 | `@vitest/coverage-v8` precise coverage around the test. Map script URLs back to git paths. Drop `node_modules`, `\0`, and `node:`. Advertise `record` only after a fixture shows a repo path that exists in the snapshot. Istanbul is the other provider; v8 is first. | feasible with risk |
| P32 | `standalone()` does not run the suite. The session loop is what waits. | proven |

### Jest (second)

Pin Jest 29, then re-run the same fixture on 30 before widening the range. `@jest/core` 29.7.0 and 30.5.2 export only `.` and `./package.json`. `@jest/core/build/watch` is not exported. The public surface is the config key `runner` (it replaces `jest-runner`), `runInBand`, and `runCLI` from the package root. `TestScheduler` calls `runner.runTests` once with all files. The custom runner sets `supportsEventEmitters`, collects names, holds the process until `close`, and runs the assigned names through circus in the parent with a per-batch `testNamePattern`. `runCLI` per batch is the cold, file-level shape and is not the client. The client does not pass `--watch`. The haste map is built once. `testNamePattern` is an anchored, escaped `^…$` against the case-folded full name the custom environment registered. Jest compiles that pattern with the `i` flag, so `^d same$` also ran `SAME`.

| Id | Mechanism | Rating |
|---|---|---|
| P1 | The custom runner above, with `runInBand`, in the parent. One full name per file execution so `beforeAll` re-enters. The process stays up until `close`. | feasible with risk |
| P2 | Repo-relative file path plus the full name (ancestor `describe` titles plus the test title). A full name is not unique across files. `testNamePattern` matches the name; the path is part of the manifest id. | proven |
| P3 | Circus runs `describe` callbacks when the file loads. A custom environment records `test` / `it` registrations and does not call `run()` during collection. `test.each` names exist after that evaluation. `--listTests` prints files and is not discovery. | feasible with risk |
| P5–P7, P20 | Circus `test_done` and `test_fn_failure`, forwarded only for assigned ids. Skip maps to `pending`. Jest marks unassigned siblings pending. A later skip must not overwrite a pass for the same id. | feasible with risk |
| P8, P9 | Jest aggregates results per `scheduleTests`. Drop the earlier assertion result for that path-plus-name id before the rerun, including from the junit reporter. `remove_failed` matches that id. | feasible with risk |
| P15, P16 | One name per file execution re-runs `beforeAll` / `afterAll`. A batch of two names loaded once runs `beforeAll` once and is short of parity. `globalSetup` stays once. Count `beforeAll` in CI. | feasible with risk |
| P17 | The haste map and the transformed file cache stay. The file is re-entered for hooks; it is not re-transformed from source each time unless the cache key changes. | feasible with risk |
| P18 | `testPathPatterns`, `testPathIgnorePatterns`, and the project's config bound which files are collected. Flags Jest would have honored still apply. `selective exec jest` collects and returns without a socket. | proven |
| P21 | `runInBand` so the trace is in the parent. `maxWorkers` greater than 1 puts tests in children and the parent's coverage is empty. | proven |
| P22 | Two tests with the same full name in one file: the custom environment renames the second registration, warns, and both ship in the manifest. The rename writes `state.currentDescribeBlock.children[…].name`. The jest-circus README calls that state unsupported. Pin the minor and re-run the duplicate fixture on every bump. Dedupe on the case-folded full name, because `testNamePattern` is compiled with the `i` flag. Match with an anchored, escaped `^…$`. A suffix that exists only in the manifest selects nothing through `testNamePattern`, and the unsuffixed name runs both duplicates. On jest 29.7.0 and 30.5.2, `^d same \(2\)$` ran nothing until the environment renamed the second registration, and then it ran only that test. The same full name in two files is two ids, because the path is part of the id (P2). | feasible with risk |
| P28 | Open a `node:inspector` `Session` and post `Profiler.startPreciseCoverage` and `Profiler.takePreciseCoverage` around each test inside the custom runner. `v8.startPreciseCoverage` does not exist (`typeof` is `undefined` on Node 16 through 26). Do not enable Jest's own coverage collection in the same process: two precise-coverage sessions corrupt each other's counts. Do not set `coverageProvider: 'v8'` alongside this session. Reverse source maps so the fragment names git paths. Advertise `select` until a fixture shows a project file. | feasible with risk |
| P32 | The custom runner owns the process. Jest's CLI autorun does not. | proven |

## Binding

**napi-rs, with the stdio sidecar when the `.node` fails to load.**

Node's native-addon distribution is a solved problem: per-target packages in `optionalDependencies` (`@selectiveci/transport-linux-x64-gnu`, `...-linux-arm64-gnu`, `...-linux-x64-musl`, `...-darwin-arm64`, `...-darwin-x64`, `...-win32-x64-msvc`). napi-rs builds them. The package exports the same session, snapshot, and upload functions as the Rust crate. Windows x86_64 is in the matrix because local frontend repos run tests on Windows. Windows arm64 can wait.

`dlopen` failures (Electron's Node, an unsigned-binary policy, a musl host that got the gnu package) fall through to `transport --stdio`. There is no pure-JS WebSocket client behind that. `ws` is not a dependency.

Build the `.node` from the `selective-transport` crate in the core repo's release workflow. The framework packages depend on the core package and do not compile Rust.

POSIX FIFOs are not a Node option. The current Ruby transport cannot run on Windows. Stdio or napi are the two faces that can.

## Vitest

The node API above is the whole adapter. `--shard`, `--changed`, and Nx or Turborepo "affected" select projects or files at launch. Selective runs inside one project, on ids.

Coverage URLs that still point at a transformed module (`\0`, a Vite id) must be resolved to the source file before we advertise `record`. A fragment path that is not a `git ls-tree` key never matches, and the test would stop being selectable.

## Jest

`TestSequencer.sort`, `--shard`, `--listTests`, and `--changedSince` fix a file list before the run. Reporters see results and do not choose the next test. None of those is the client.

`@knapsack-pro/jest` calls `jest.runCLI` per queue batch with `runTestsByPath`. Their issue 24 records that workers are not reused across `runCLI` calls, and they recommend `--runInBand` to avoid the fork. That is a cold, file-level queue. We do not copy it.

What we copy is a long-lived custom runner in the parent. It sets `supportsEventEmitters`, uses `runInBand`, and sets a per-batch `testNamePattern` to the anchored, case-folded name the custom environment registered. Internals (`jest-circus`, `jest-runner`) move between 27, 29, and 30. The pin is 29 until the `beforeAll` counter and the duplicate-name fixture pass, then 30, and the duplicate fixture is re-run on every minor bump because the rename writes circus state the README calls unsupported.

`beforeAll` runs once per file execution. One assigned name per execution is what makes a later batch re-enter the hook. A custom environment records names at load time, renames a second registration that would share a case-folded full name, and leaves the callbacks uncalled until the server sends the id. The manifest id is the repo-relative path plus that name.

## Packaging and CI

- npm: `@selectiveci/core` (session, napi package, sidecar fallback), `@selectiveci/vitest`, `@selectiveci/jest`.
- Bins: `selective vitest`, `selective jest`. CI replaces `vitest` / `jest` with those.
- The core package is `selectiveci/selective-js-core`. Framework repos depend on it. Create the core repo with the Vitest client, not before.
- GitHub Action unchanged. `fail-fast: false`.

## Risks

- Vitest's node API has already moved once (`state.getFiles` to `state.getTestModules`, `init` to `standalone` in 4.1.1). Under the `< 5` pin the parse entry is `experimental_parseSpecifications`. The pin is `>= 4.1.1 < 5`, plus a CI job on the current 4.x.
- A file with any `dynamic: true` entry takes every id from `collectTests`. A static parse id after `test.each` names the wrong test. The collect pass runs with isolation disabled or it re-boots every file.
- P15 is one id per call, which boots a new worker each time. One spec listing every id of a file runs `beforeAll` once per file. The counter is taken on the one-id-per-call loop. The main process and the Vite server stay up; the worker does not.
- Vite module ids versus git paths in the fragment. Advertise `select` until a recorded test lists a project source file.
- Jest's warm loop is a custom `runner` with `supportsEventEmitters` and `runInBand`. `@jest/core` does not export `build/watch`. A Jest major that stops honoring `runInBand` changes the worker boundary; the pin catches it. The duplicate-name fixture, including the case-folded name, is re-run on every minor bump.
- Both tools spawn workers. A trace taken only in the parent is empty when the test ran in a child.
- Monorepos. One Selective command is one package. Nx affected stays outside.
- The JavaScript full-run list already includes `package.json`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, and `tsconfig.json`. Still to add: `vitest.config.*`, `jest.config.*`, and `vite.config.*`.
- Windows CI for the napi packages is part of the core release, not each framework repo.

## Effort

Vitest is a medium slice: core session on the sidecar, then napi, then `createVitest` / one id per `runTestSpecifications` call / `experimental_parseSpecifications` for files with no dynamic tests, with `collectTests` for any file that has a `dynamic: true` entry and the `beforeAll` counter on that one-id loop. v8 coverage follows, and `record` waits on path mapping (`\0` and `node:` URLs resolved to git paths). Jest is a larger slice on the same core, dominated by the custom runner and circus collection. Jest starts after Vitest conformance is green. There is no file-level slice.

Repositories: `selectiveci/selective-js-core`, `selectiveci/selective-js-vitest`, `selectiveci/selective-js-jest`.

## Prior art

- `vitest --shard`, `jest --shard`: static file splits. The opposite of a queue.
- Jest's sequencer and haste map: file ordering, still static.
- Vitest `createVitest` / `runTestSpecifications`: the API this client should wrap. Wallaby and the Vitest UI already drive it.
- Nx / Turborepo affected: project selection, not test selection.
- Datadog and CloudBees Smart Tests: hosted competitors with their own Jest and Vitest integrations. Same "one command" bar.
