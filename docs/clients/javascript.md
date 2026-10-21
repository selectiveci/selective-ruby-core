# JavaScript and TypeScript (Vitest, then Jest)

Marketing order: fourth. Feasibility of full parity: fourth. One language, two frameworks, one core package. **Vitest is the first framework.** Jest is second, on the same core, and it is feasible with risk. Playwright is out of scope until a design partner asks; the runner model is browser processes.

TypeScript is not a separate client. Vitest and Jest both run it.

Read [SPEC.md](SPEC.md) for the wire contract and the parity bar.

**Verdict: feasible with risk. Nothing is blocked, and neither framework needs a fork.** Vitest 4.1 runs a list of test ids inside one long-lived instance; static tests are proven, and `test.each` needs a collect pass. Jest's public `TestSequencer`, `--shard`, and `--listTests` are static and outside the contract. The warm path is Jest's own watch loop, driven as a library with `runInBand`, so CI's habit of turning `--watch` off does not apply. Knapsack Pro's Jest client (`runCLI` per batch of file paths) leaves workers cold and runs files; that shape is outside the contract.

## Parity

Rows P4, P10–P14, P16, P19, P23–P27, and P29–P31 are the session loop in `@selectiveci/core`, on napi-rs or `transport --stdio`. Port of `Controller`. Rating: proven. The two adapters differ on the rows below.

### Vitest (first)

Pin Vitest `>= 4.1`. `testIds` on `TestSpecification` landed in 4.1.0. `standalone()` (4.1.1; `init` is the deprecated name) prepares reporters and coverage and does not run tests. Keep the instance for the shard and do not call `close()` between batches.

| Id | Mechanism | Rating |
|---|---|---|
| P1 | `createVitest` once. `globTestSpecifications` to learn the files. Each assigned id becomes `project.createSpecification(moduleId, { testIds: [id] })`, then `runTestSpecifications`. One id per call so `beforeAll` re-enters (P15). `rerunTestSpecifications` also emits watcher events; use `runTestSpecifications`. Do not call `startVitest` per batch. The forks pool stays at one worker for the life of the instance. | proven |
| P2 | `TestCase.id` (file hash, suite index, test index). Vitest documents that callers must not parse the id; it can start with a minus. Use it whole. `generateFileHash` from `vitest/node` has existed since v3. `TestCase.toTestSpecification()` (4.1+) returns a spec for that case and is the same filter. | proven |
| P3 | Static tests: `experimental_parseSpecifications` on 4.1 (rollup `parseAst` over Vite `ssrTransform`, no import following). Later majors rename it to `parseSpecifications`. `test.each`, `test.for`, and template names are marked `dynamic: true` with an id postfix of `-dynamic`, and that id cannot filter the run. For those, `collectTests` executes the file and not the callbacks, inside this instance, with isolation off for the collect pass so it stays cheap. The names from that pass are the manifest ids, and later batches filter them with `testIds`. | proven for static tests; feasible with risk for dynamic tests |
| P5–P7, P20 | A custom reporter's `onTestCaseResult`. `pass` / `fail` / `skip` map to `passed` / `failed` / `pending`. Project frame first. | proven |
| P8, P9 | Drop the earlier case result from the reporter's store before the id runs again. `remove_failed` deletes by `TestCase.id`. | proven |
| P15, P16 | One `testIds` entry per `runTestSpecifications` re-executes the file's hooks, so `beforeAll` / `afterAll` run per assigned test. If a warm worker with `isolate: false` then skips `beforeAll` on the second call, invalidate that module in the Vite graph before the call. A conformance fixture counts `beforeAll`. Time those hooks for P16. `globalSetup` stays once (P14). | feasible with risk |
| P17 | The Vite server and the worker stay up. Module invalidation is only the P15 lever, and only for the file about to run. | proven |
| P18 | `include`, `exclude`, `testNamePattern` from the project config, and CLI path filters, bound discovery. `selective exec vitest` collects and returns without a socket. `--shard` and `--changed` are off. | proven |
| P21 | `fileParallelism: false`, `poolOptions.forks.singleFork` (one worker). A parent-only trace is empty if tests run in a worker we do not wrap. The first recording PR asserts the fragment names a project source file. | proven |
| P22 | A dynamic id that collides after `collectTests` gets a warning and a suffix. | proven |
| P28 | `@vitest/coverage-v8` precise coverage around the test. Map script URLs back to git paths. Drop `node_modules`, `\0`, and `node:`. Advertise `record` only after a fixture shows a repo path that exists in the snapshot. Istanbul is the other provider; v8 is first. | feasible with risk |
| P32 | `standalone()` does not run the suite. The session loop is what waits. | proven |

### Jest (second)

Pin one major. Jest 29 is the installed base; re-run the same fixture on 30 before widening the range. The CLI clears `--watch` when `CI` is set, so the client does not pass `--watch` on argv. It builds the global config itself (`watch: true`, `runInBand: true`) and calls the watch entry in `@jest/core` (`packages/jest-core/src/watch.ts`, `updateConfigAndRun` / `startRun`). `shouldRunInBand` returns true when `runInBand` is set, including in watch mode (current `testSchedulerHelper.ts`; on 29.2 the same outcome comes from `runInBand` forcing `maxWorkers` to 1, and watch mode runs in band when there is one worker). Each batch sets `testNamePattern` to the assigned full names and calls `startRun` again. The haste map is built once.

The other shape, if the watch entry fights CI's non-TTY stdio, is a long-lived `jest-worker` farm: `jest-runner` builds a `Farm` per `scheduleTests` and `end()`s it in a `finally`. Keeping the farm and sending the next file is the same process model. Either way the test bodies run in a process we still hold.

| Id | Mechanism | Rating |
|---|---|---|
| P1 | The loop above. One full name per `startRun` so `beforeAll` re-enters. `TestScheduler.scheduleTests` runs the selected files in the parent because `runInBand` is set. | feasible with risk |
| P2 | Full name: ancestor `describe` titles plus the test title, the string `--testNamePattern` already matches. | proven |
| P3 | Circus runs `describe` callbacks when the file loads. A custom environment records `test` / `it` registrations and does not call `run()` during collection. `test.each` names exist after that evaluation. `--listTests` prints files and is not discovery. | feasible with risk |
| P5–P7, P20 | Circus `test_done` and `test_fn_failure`. Skip maps to `pending`. | feasible with risk |
| P8, P9 | Jest aggregates results per `scheduleTests`. Drop the earlier assertion result for that full name before the rerun, including from the junit reporter. `remove_failed` matches the full name. | feasible with risk |
| P15, P16 | One name per file execution re-runs `beforeAll` / `afterAll`. A batch of two names loaded once runs `beforeAll` once and is short of parity. `globalSetup` stays once. Count `beforeAll` in CI. | feasible with risk |
| P17 | The haste map and the transformed file cache stay. The file is re-entered for hooks; it is not re-transformed from source each time unless the cache key changes. | feasible with risk |
| P18 | `testPathPatterns`, `testPathIgnorePatterns`, and the project's config bound which files are collected. Flags Jest would have honored still apply. `selective exec jest` collects and returns without a socket. | proven |
| P21 | `runInBand` so the trace is in the parent. `maxWorkers` greater than 1 puts tests in children and the parent's coverage is empty. | proven |
| P22 | Two tests with the same full name get a warning and a suffix before the manifest is sent. | proven |
| P28 | `coverageProvider: 'v8'`. `takePreciseCoverage` in a custom environment between tests, then reset. Reverse source maps so the fragment names git paths. Advertise `select` until a fixture shows a project file. | feasible with risk |
| P32 | We call the programmatic entry. Jest's CLI autorun and the CI watch-disable do not own the process. | proven |

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

What we do copy is the watch loop's repeated `startRun` inside one process, with `runInBand` so `TestScheduler` stays in the parent, and `testNamePattern` set to the assigned names. Internals (`@jest/core`, `jest-circus`, `jest-runner`) move between 27, 29, and 30. The pin is 29 until the `beforeAll` counter passes, then 30.

`beforeAll` runs once per file execution. One assigned name per execution is what makes a later batch re-enter the hook. A custom environment records names at load time, and the callbacks stay uncalled until the server sends the id.

## Packaging and CI

- npm: `@selectiveci/core` (session, napi package, sidecar fallback), `@selectiveci/vitest`, `@selectiveci/jest`.
- Bins: `selective vitest`, `selective jest`. CI replaces `vitest` / `jest` with those.
- The core package is `selectiveci/selective-js-core`. Framework repos depend on it. Create the core repo with the Vitest client, not before.
- GitHub Action unchanged. `fail-fast: false`.

## Risks

- Vitest's node API has already moved once (`state.getFiles` to `state.getTestModules`, `init` to `standalone` in 4.1.1, `experimental_parseSpecifications` renamed to `parseSpecifications` after 4.1). The pin is `>= 4.1` and a CI job on the current 4.x, calling the name that major exports.
- Dynamic tests need `collectTests`. Static parse cannot filter them. The collect pass has to run with isolation disabled or it re-boots every file.
- `beforeAll` on a warm worker with `isolate: false` might not re-enter. The counter fixture is the gate. Module-graph invalidation is the lever if the counter stays at 1.
- Vite module ids versus git paths in the fragment. Advertise `select` until a recorded test lists a project source file.
- Jest's warm loop uses `@jest/core` internals, and the CLI will not leave `--watch` on under `CI`. The programmatic config is the path. A Jest major that stops honoring `runInBand` inside watch changes the worker boundary; the pin catches it.
- Both tools spawn workers. A trace taken only in the parent is empty when the test ran in a child.
- Monorepos. One Selective command is one package. Nx affected stays outside.
- Server full-run patterns: `package-lock.json`, `pnpm-lock.yaml`, `vitest.config.*`, `jest.config.*`, `vite.config.*`.
- Windows CI for the napi packages is part of the core release, not each framework repo.

## Effort

Vitest is a medium slice: core session on the sidecar, then napi, then `createVitest` / `runTestSpecifications` / `parseSpecifications`, with the dynamic-test collect path and the `beforeAll` counter in the same PR. v8 coverage follows, and `record` waits on path mapping. Jest is a larger slice on the same core, dominated by the watch-loop driver and circus collection. Jest starts after Vitest conformance is green. There is no file-level slice.

Repositories: `selectiveci/selective-js-core`, `selectiveci/selective-js-vitest`, `selectiveci/selective-js-jest`.

## Prior art

- `vitest --shard`, `jest --shard`: static file splits. The opposite of a queue.
- Jest's sequencer and haste map: file ordering, still static.
- Vitest `createVitest` / `runTestSpecifications`: the API this client should wrap. Wallaby and the Vitest UI already drive it.
- Nx / Turborepo affected: project selection, not test selection.
- Datadog and CloudBees Smart Tests: hosted competitors with their own Jest and Vitest integrations. Same "one command" bar.
