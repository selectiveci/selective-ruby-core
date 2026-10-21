# JavaScript and TypeScript (Vitest, then Jest)

Marketing order: fourth. Feasibility of full parity: fourth. One language, two frameworks, one core package. **Vitest is the first framework.** Jest is second, on the same core, and it is feasible with risk. Playwright is out of scope until a design partner asks; the runner model is browser processes.

TypeScript is not a separate client. Vitest and Jest both run it.

Read [SPEC.md](SPEC.md) for the wire contract and the parity bar.

**Verdict: feasible with risk. Nothing is blocked, and neither framework needs a fork.** Vitest `>= 4.1.1 < 5` runs a list of test ids inside one long-lived instance; static tests are the proven part, and `test.each` needs a collect pass. One id per `runTestSpecifications` call forks a new worker, so the warm-worker candidate is the batch's specs in one call, and that still has to re-prove `beforeAll`. Jest's public `TestSequencer`, `--shard`, and `--listTests` are static and outside the contract. The warm path is a custom `runner` (the public config key that replaces `jest-runner`) with `runInBand`, holding the process until `close` and running assigned names through circus in the parent. `@jest/core` 29 and 30 export only `.` and `./package.json`. A deep import of `packages/jest-core/src/watch.ts` throws `ERR_PACKAGE_PATH_NOT_EXPORTED`. Do not design the client as that import, and do not depend on `--watch` under `CI`. Knapsack Pro's Jest client (`runCLI` per batch of file paths) leaves workers cold and runs files; that shape is outside the contract.

## Parity

Rows P4, P10–P14, P16, P19, P23–P27, and P29–P31 are the session loop in `@selectiveci/core`, on napi-rs or `transport --stdio`. Port of `Controller`. Rating: proven. The two adapters differ on the rows below.

### Vitest (first)

Pin Vitest `>= 4.1.1 < 5`. `testIds` on `TestSpecification` landed in 4.1.0. `standalone()` landed in 4.1.1; at 4.1.0 only `init()` exists. Vitest 5.0.5 is current, so an open `>= 4.1` admits it. Stay below 5 until `parseSpecifications` is re-probed on that major. `standalone()` prepares reporters and coverage and does not run tests. Keep the instance for the shard and do not call `close()` between batches.

| Id | Mechanism | Rating |
|---|---|---|
| P1 | `createVitest` once. `globTestSpecifications` to learn the files. Pass the batch's ids as separate specs in one `runTestSpecifications` call (`project.createSpecification(moduleId, { testIds: [id] })` per id, then one call). A probe of that shape kept one worker pid. One id per call forks a new worker: the pool keeps a runner only when the next queued task is already there and `isolate` matches, so sequential one-id calls get different pids. That shape is not the warm path. Do not say the pool stays at one worker for the life of the instance. Re-run the `beforeAll` counter under the one-call batch, because a kept worker is when module-graph invalidation matters (P15). `rerunTestSpecifications` also emits watcher events; use `runTestSpecifications`. Do not call `startVitest` per batch. | feasible with risk |
| P2 | `TestCase.id` (file hash, suite index, test index). Vitest documents that callers must not parse the id; it can start with a minus. Use it whole. The indexes are positional: inserting a `test.each` row shifts later static ids. The id survives a comment-only line shift. It does not survive an inserted test. `generateFileHash` from `vitest/node` has existed since v3. `TestCase.toTestSpecification()` (4.1+) returns a spec for that case and is the same filter. | proven |
| P3 | Static tests: `experimental_parseSpecifications` on 4.1 (rollup `parseAst` over Vite `ssrTransform`, no import following). Later majors rename it to `parseSpecifications`. `test.each`, `test.for`, and template names are marked `dynamic: true` with an id postfix of `-dynamic`, and that id cannot filter the run. For those, `collectTests` executes the file and not the callbacks, inside this instance, with isolation off for the collect pass so it stays cheap. The names from that pass are the manifest ids, and later batches filter them with `testIds`. | proven for static tests; feasible with risk for dynamic tests |
| P5–P7, P20 | A custom reporter's `onTestCaseResult`. `pass` / `fail` / `skip` map to `passed` / `failed` / `pending`. Project frame first. | proven |
| P8, P9 | Drop the earlier case result from the reporter's store before the id runs again. `remove_failed` deletes by `TestCase.id`. | proven |
| P15, P16 | `beforeAll` / `afterAll` run for every assigned test, including two ids from the same file in one `runTestSpecifications` call and an id from a later batch. A batch that runs the hook once per file is short of parity. The counter is re-run under the one-call batch in P1. If a kept worker with `isolate: false` then skips `beforeAll` on the second id, invalidate that module in the Vite graph before the id. Time those hooks for P16. `globalSetup` stays once (P14). | feasible with risk |
| P17 | The Vite server and the worker stay up. Module invalidation is only the P15 lever, and only for the file about to run. | proven |
| P18 | `include`, `exclude`, `testNamePattern` from the project config, and CLI path filters, bound discovery. `selective exec vitest` collects and returns without a socket. `--shard` and `--changed` are off. | proven |
| P21 | `fileParallelism: false` runs one file at a time. `maxWorkers: 1` with `isolate: false` keeps one worker within a call, not across calls (see P1). Vitest 4 removed `poolOptions`; `singleFork` is ignored with a deprecation warning. A parent-only trace is empty if tests run in a worker we do not wrap. The first recording PR asserts the fragment names a project source file. | proven |
| P22 | A dynamic id that collides after `collectTests` gets a warning and a suffix. | proven |
| P28 | `@vitest/coverage-v8` precise coverage around the test. Map script URLs back to git paths. Drop `node_modules`, `\0`, and `node:`. Advertise `record` only after a fixture shows a repo path that exists in the snapshot. Istanbul is the other provider; v8 is first. | feasible with risk |
| P32 | `standalone()` does not run the suite. The session loop is what waits. | proven |

### Jest (second)

Pin Jest 29, then re-run the same fixture on 30 before widening the range. `@jest/core` 29.7.0 and 30.5.2 export only `.` and `./package.json`. Importing `packages/jest-core/src/watch.ts` throws `ERR_PACKAGE_PATH_NOT_EXPORTED`. The public surface is the config key `runner` (it replaces `jest-runner`), `runInBand`, and `runCLI` from the package root. `TestScheduler` calls `runner.runTests` once with all files. A custom runner collects names, holds the process until `close`, and runs the assigned names through circus in the parent. `runCLI` per batch is the cold, file-level shape and is not the client. Do not pass `--watch`, and do not claim the CLI clears it when `CI` is set; that claim was not re-checked, and the design does not need it. The haste map is built once. `testNamePattern` is an anchored, escaped `^…$` against the name the custom environment registered.

| Id | Mechanism | Rating |
|---|---|---|
| P1 | The custom runner above, with `runInBand`, in the parent. One full name per file execution so `beforeAll` re-enters. The process stays up until `close`. | feasible with risk |
| P2 | Full name: ancestor `describe` titles plus the test title, the string `--testNamePattern` already matches. | proven |
| P3 | Circus runs `describe` callbacks when the file loads. A custom environment records `test` / `it` registrations and does not call `run()` during collection. `test.each` names exist after that evaluation. `--listTests` prints files and is not discovery. | feasible with risk |
| P5–P7, P20 | Circus `test_done` and `test_fn_failure`. Skip maps to `pending`. | feasible with risk |
| P8, P9 | Jest aggregates results per `scheduleTests`. Drop the earlier assertion result for that full name before the rerun, including from the junit reporter. `remove_failed` matches the full name. | feasible with risk |
| P15, P16 | One name per file execution re-runs `beforeAll` / `afterAll`. A batch of two names loaded once runs `beforeAll` once and is short of parity. `globalSetup` stays once. Count `beforeAll` in CI. | feasible with risk |
| P17 | The haste map and the transformed file cache stay. The file is re-entered for hooks; it is not re-transformed from source each time unless the cache key changes. | feasible with risk |
| P18 | `testPathPatterns`, `testPathIgnorePatterns`, and the project's config bound which files are collected. Flags Jest would have honored still apply. `selective exec jest` collects and returns without a socket. | proven |
| P21 | `runInBand` so the trace is in the parent. `maxWorkers` greater than 1 puts tests in children and the parent's coverage is empty. | proven |
| P22 | Two tests with the same full name: the custom environment renames the second registration, warns, and both ship in the manifest. Match with an anchored, escaped `^…$`. A suffix that exists only in the manifest selects nothing through `testNamePattern`, and the unsuffixed name runs both duplicates. On jest 29.7.0, `^d same \(2\)$` ran nothing until the environment renamed the second registration, and then it ran only that test. | feasible with risk |
| P28 | `coverageProvider: 'v8'`. Jest 29 has no `takePreciseCoverage` hook in a custom environment. v8 coverage through `collect-v8-coverage` in jest-runtime is per file. Per-test coverage means starting Node's `v8.startPreciseCoverage` (or the inspector) between tests inside the custom runner, then resetting. Reverse source maps so the fragment names git paths. Advertise `select` until a fixture shows a project file. | feasible with risk |
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

What we copy is a long-lived custom runner in the parent, with `runInBand`, and `testNamePattern` set to the anchored name the custom environment registered. Internals (`jest-circus`, `jest-runner`) move between 27, 29, and 30. The pin is 29 until the `beforeAll` counter and the duplicate-name fixture pass, then 30.

`beforeAll` runs once per file execution. One assigned name per execution is what makes a later batch re-enter the hook. A custom environment records names at load time, renames a second registration that would share a full name, and leaves the callbacks uncalled until the server sends the id.

## Packaging and CI

- npm: `@selectiveci/core` (session, napi package, sidecar fallback), `@selectiveci/vitest`, `@selectiveci/jest`.
- Bins: `selective vitest`, `selective jest`. CI replaces `vitest` / `jest` with those.
- The core package is `selectiveci/selective-js-core`. Framework repos depend on it. Create the core repo with the Vitest client, not before.
- GitHub Action unchanged. `fail-fast: false`.

## Risks

- Vitest's node API has already moved once (`state.getFiles` to `state.getTestModules`, `init` to `standalone` in 4.1.1, `experimental_parseSpecifications` renamed to `parseSpecifications` after 4.1). The pin is `>= 4.1.1 < 5`, plus a CI job on the current 4.x, calling the name that major exports.
- Dynamic tests need `collectTests`. Static parse cannot filter them. The collect pass has to run with isolation disabled or it re-boots every file.
- `beforeAll` on a kept worker with `isolate: false` might not re-enter. The counter fixture is re-run under the one-call batch. Module-graph invalidation is the lever if the counter stays at 1. One id per call forks, so a counter taken only on that shape does not prove the warm path.
- Vite module ids versus git paths in the fragment. Advertise `select` until a recorded test lists a project source file.
- Jest's warm loop is a custom `runner` plus `runInBand`. `@jest/core` does not export `watch.ts`. A Jest major that stops honoring `runInBand` changes the worker boundary; the pin catches it. The duplicate-name fixture has to be green before P22 is more than feasible with risk.
- Both tools spawn workers. A trace taken only in the parent is empty when the test ran in a child.
- Monorepos. One Selective command is one package. Nx affected stays outside.
- Server full-run patterns: `package-lock.json`, `pnpm-lock.yaml`, `vitest.config.*`, `jest.config.*`, `vite.config.*`.
- Windows CI for the napi packages is part of the core release, not each framework repo.

## Effort

Vitest is a medium slice: core session on the sidecar, then napi, then `createVitest` / one `runTestSpecifications` call for the batch / `parseSpecifications`, with the dynamic-test collect path and the `beforeAll` counter re-run under that one-call shape. v8 coverage follows, and `record` waits on path mapping (`\0` and `node:` URLs resolved to git paths). Jest is a larger slice on the same core, dominated by the custom runner and circus collection. Jest starts after Vitest conformance is green. There is no file-level slice.

Repositories: `selectiveci/selective-js-core`, `selectiveci/selective-js-vitest`, `selectiveci/selective-js-jest`.

## Prior art

- `vitest --shard`, `jest --shard`: static file splits. The opposite of a queue.
- Jest's sequencer and haste map: file ordering, still static.
- Vitest `createVitest` / `runTestSpecifications`: the API this client should wrap. Wallaby and the Vitest UI already drive it.
- Nx / Turborepo affected: project selection, not test selection.
- Datadog and CloudBees Smart Tests: hosted competitors with their own Jest and Vitest integrations. Same "one command" bar.
