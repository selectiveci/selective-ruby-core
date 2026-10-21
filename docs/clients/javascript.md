# JavaScript and TypeScript (Vitest, then Jest)

Marketing order: fourth. One language, two frameworks, two repositories, one core package. Vitest before Jest: Vitest exposes a programmatic runner, and Jest's public extension points are static. Playwright is out of scope until a design partner asks; the CI time is often there, and the runner model is different (browser processes).

TypeScript is not a separate client. Vitest and Jest both run it.

Read [SPEC.md](SPEC.md) for the wire contract.

## Binding

**napi-rs, with the stdio sidecar when the `.node` fails to load.**

Node's native-addon distribution is a solved problem: per-target packages in `optionalDependencies` (`@selectiveci/transport-linux-x64-gnu`, `...-linux-arm64-gnu`, `...-linux-x64-musl`, `...-darwin-arm64`, `...-darwin-x64`, `...-win32-x64-msvc`). napi-rs builds them. The package exports the same session, snapshot, and upload functions as the Rust crate. Windows x86_64 is in the matrix because local frontend repos run tests on Windows. Windows arm64 can wait.

`dlopen` failures (Electron's Node, an unsigned-binary policy, a musl host that got the gnu package) fall through to `transport --stdio`. There is no pure-JS WebSocket client behind that. `ws` is not a dependency.

Build the `.node` from the `selective-transport` crate in the core repo's release workflow. The framework packages depend on the core package and do not compile Rust.

POSIX FIFOs are not a Node option. The current Ruby transport cannot run on Windows. Stdio or napi are the two faces that can.

## Vitest

Vitest's node API is the adapter.

- `createVitest` from `vitest/node` builds an instance without running.
- `init` loads reporters and the coverage provider and does not run tests. Keep `watch: true` even though we do not use the file watcher: Vitest uses that flag to allow a long-lived instance.
- Collected files come from the project graph (`globTestSpecifications` / module specifications). The manifest id is the test's full name plus its file, the same string Vitest prints (`tests/billing.test.ts > tax > rounds`). Confirm the exact property against the Vitest major we pin; this API has moved before.
- `runTestSpecifications` runs a specific list in the already-initialized process. Use that for each `run_test_cases` batch. `rerunTestSpecifications` also emits watcher events; prefer `runTestSpecifications` so reporters do not think a file changed.
- Results come from a custom reporter (`onTestCaseResult` / the task state on the modules returned from the run). Map `pass` / `fail` / `skip` to `passed` / `failed` / `pending`.

Do not call `startVitest` per batch. That boots Vite each time.

Vitest workers (`forks`, `threads`, `vmForks`) run files in other processes. For v1, use the `forks` pool with a single worker, or run in-process if the project is not using a browser pool. Recording has to wrap the test that actually executes. A pool of workers means the trace has to happen in the worker, which means the Selective reporter must be injected into the worker, not only the main process. Start with one fork so the first client is honest. Parallelism inside a shard is a later change; Selective's parallelism is the CI matrix.

`--shard` and `--changed` are static and must not be combined with the Selective command. Nx and Turborepo "affected" are a different layer (which projects run). Selective runs inside one project.

### Coverage

`@vitest/coverage-v8` uses V8's inspector coverage. Per test, the worker can `startPreciseCoverage` / `takePreciseCoverage` around the test (Node's `inspector` / `v8`). Map script URLs to repo-relative files, drop `node_modules` and Vite's virtual modules (`\0`, `node:`). Advertise `record` when the coverage provider can be constructed. Istanbul (`@vitest/coverage-istanbul`) is the other provider; support v8 first because new Vitest projects default to it.

Vite transforming a file means the covered URL might be a transformed module id. Resolve it back to the source file or the fragment will name paths that are not in `git ls-tree`, and selection will never match. That resolution is the Vitest recording risk.

## Jest

Jest's public hooks do not take a remote queue.

- `TestSequencer.sort` and `shard` reorder or slice the file list before the run. The list is fixed when the run starts.
- `--listTests` prints files, not test names.
- `--changedSince` is git, local, static.
- Custom reporters see results. They do not choose the next test.
- `jest-circus` is the default runner and its event handler is the closest thing to a hook, but the file's tests are already scheduled when the worker starts.

The adapter is a long-lived Node process that uses Jest's programmatic entry once:

1. Build the haste map and collect test names without executing bodies. Circus runs `describe` callbacks during collection; a custom environment can record `test` / `it` entries (file plus ancestor titles, which is the id) and defer the functions.
2. Send the manifest.
3. On each batch, run those test functions through circus so hooks (`beforeEach`, `afterEach`) still fire.
4. Report from circus events `test_done` / `test_fn_failure`.

This touches Jest internals (`@jest/core`, `jest-circus`, `jest-runner`) that move between Jest 27, 29, and 30. Pin one major for v1 (whichever the first design partner runs; 29 is still the installed base) and add majors after conformance passes on that pin.

The fallback if circus deferral is unstable: run at **file** granularity. The manifest id is the test file, `run_test_cases` runs whole files through `runCLI`'s test path filter in an already-warm runtime if we can keep it, otherwise a single Jest process per batch. File granularity wastes work inside a file and is still a correct client. Prefer per-test, and do not pretend file granularity is per-test in the manifest or flake tracking breaks.

Jest workers are child processes. Same as Vitest: v1 uses one worker so coverage and results stay in a place we control. `maxWorkers: 1`.

### Coverage

Jest's `coverageProvider: 'v8'` is process-wide. Per test, take precise V8 coverage in a custom environment's `handleTestEvent` and reset between tests. Babel/Istanbul instrumentation is the other provider; support the one the project already configured, v8 first. Ignore `node_modules`. Transformed paths need the same source-map reversal as Vitest.

## Packaging and CI

- npm: `@selectiveci/core` (session, napi package, sidecar fallback), `@selectiveci/vitest`, `@selectiveci/jest`.
- Bins: `selective vitest`, `selective jest`. CI replaces `vitest` / `jest` with those.
- The core package is `selectiveci/selective-js-core`. Framework repos depend on it. Create the core repo with the Vitest client, not before.
- GitHub Action unchanged. `fail-fast: false`.

## Risks

- Vitest's node API is public and has already changed shape once (`state.getFiles` to `state.getTestModules`). Pin a major.
- Vite module ids versus git paths in the fragment.
- Jest has no supported "run these names in this warm process" API. Budget the Jest adapter as the one that might ship file-granularity first.
- Both tools spawn workers. A trace taken in the parent is empty. The first PR should assert that a recorded test lists a project file, not only the test file.
- Monorepos. One Selective command is one package. Nx affected stays outside.
- Server full-run patterns: `package-lock.json`, `pnpm-lock.yaml`, `vitest.config.*`, `jest.config.*`, `vite.config.*`.
- Windows CI for the napi packages is part of the core release, not each framework repo.

## Effort

Vitest is a medium slice: core session on the sidecar, then napi, then `createVitest` and `runTestSpecifications`, then v8 coverage. Jest is a larger slice on top of the same core, dominated by circus collection. Do not start Jest until Vitest conformance is green and one real repo has run it. Coverage source-map resolution can slip to a follow-up; until it works, advertise `select` for Vitest rather than uploading paths the server cannot match.

Repositories: `selectiveci/selective-js-core`, `selectiveci/selective-js-vitest`, `selectiveci/selective-js-jest`.

## Prior art

- `vitest --shard`, `jest --shard`: static file splits. The opposite of a queue.
- Jest's sequencer and haste map: file ordering, still static.
- Vitest `createVitest` / `runTestSpecifications`: the API this client should wrap. Wallaby and the Vitest UI already drive it.
- Nx / Turborepo affected: project selection, not test selection.
- Datadog and CloudBees Smart Tests: hosted competitors with their own Jest and Vitest integrations. Same "one command" bar.
