# Java (JUnit 5)

Marketing order: last. Feasibility of full parity: second, behind pytest. JUnit 5 is the framework. Tests run through Maven Surefire or a Gradle `Test` task, so the client is the launcher plus a host. TestNG is out of scope until someone asks. Develocity and CloudBees Smart Tests already sit inside the build tool; that is a product overlap, and it does not change the runner.

Read [SPEC.md](SPEC.md) for the wire contract and the parity bar.

**Verdict: feasible with risk.** `Launcher.execute` of a unique id is the proven split, and it is what IDEs already do in a JVM that is already up. The host is a Surefire provider, because `mvn test` is where the classpath, `argLine`, and the Spring context actually exist. The provider SPI javadoc says it can change in a minor release, so the host wiring is feasible with risk, not a proven split. A CLI that is handed the same classpath is the conformance harness for the same code, not a smaller client. Gradle is the second host, same launcher. No row is blocked. No fork. Develocity's distributor is a different broker; we do not copy it.

## Parity

Rows P4, P10–P13, P16, P19, P23–P27, and P29–P31 are the session loop on `transport --stdio`, inside the Surefire forked JVM. Port of `Controller`. Rating: proven. P14 is in the table: a rebuilt engine can re-run suite extensions.

| Id | Mechanism | Rating |
|---|---|---|
| P1 | `Launcher.discover` once for static tests. Each `run_test_cases` id is one `launcher.execute(request)` with `DiscoverySelectors.selectUniqueId`, in this JVM. Hold that id's result until `execute` returns, then send it (P5–P7). `SurefireProvider.invoke()` is the loop: Surefire has already forked, put the classpath and `argLine` in place, and called `invoke`. The provider reads the socket until `close`. Do not shell `mvn -Dtest=Class#method` per batch. One unique id per `execute` so `@BeforeAll` re-enters on the real run (P15). The provider SPI can change in a minor, so the host is the risk; the launcher call is the proven mechanism. Under a forked Surefire JVM, `invoke()`'s `RunResult` is discarded. The build counts streamed reporter events. Send Surefire `RunListener` events from the client's own store at `close`, one per id, never from the live JUnit listener during the run. | feasible with risk |
| P2 | The platform unique id, `[engine:junit-jupiter]/[class:com.example.BillingTest]/[method:tax()]`. Stable across line shifts. Static `@Test` methods come from `Launcher.discover`. `@TestFactory` children and `@ParameterizedTest` invocations are absent from a discovery-only `TestPlan` (JUnit 5.12.2: discovery found 1 test where a full run found 3). `@ParameterizedClass` is `@since 5.13` and is not in the 5.12.2 jar, so do not cite that jar for a parameterized class. Their ids arrive through `TestExecutionListener.dynamicTestRegistered` during an execution pass. That pass selects `[test-factory:]`, `[test-template:]`, and, on 5.13+, `[class-template:]`. Selecting only the first two leaves class-template tests unassigned and the shard exits 0. The interceptor skips `interceptDynamicTest`, `interceptTestTemplateMethod`, `interceptTestMethod`, `interceptBeforeEachMethod`, `interceptAfterEachMethod`, `interceptBeforeAllMethod`, and `interceptAfterAllMethod`. What still runs: the factory method, argument providers, class-level callbacks that are not those interceptors, the test-class constructor, and `BeforeEachCallback`. Child bodies do not run. Attach no reporting listener to this pass. A container that finishes `FAILED` during the pass (a factory or `@MethodSource` that throws) is itself a manifest entry, its method unique id. Executing that id re-raises and reports `failed`. Factories and providers must be deterministic. Pin the JUnit range CI runs and test it, including 5.13+ for class templates. Vintage ids come from the platform too. v1 registers the junit-jupiter engine and still reports vintage tests that appear in the plan. No separate JUnit 4 runner. TestNG is out of scope. | feasible with risk |
| P3 | Static tests: `TestPlan` from `discover`, walking containers to methods. Dynamic and parameterized tests: the collect pass in P2, which does call `execute` with bodies skipped. Do not claim those ids exist without `execute`. An empty plan exits 1. | feasible with risk |
| P5–P7, P20 | `TestExecutionListener.executionFinished` and `executionSkipped`, read after `execute` returns for that one id. `SUCCESSFUL` → `passed`, `FAILED` → `failed`, `ABORTED` (a failed assumption; Surefire reports it through `testAssumptionFailure`) → `pending`, `executionSkipped` (`@Disabled` or a disabled condition) → `pending`. There is no `DISABLED` status. If the class or factory container finished `FAILED`, before or after the test, send `failed` with that container's throwable. This overrides a leaf `passed`. If an ancestor container was `ABORTED` or skipped and the test has no event of its own (an assumption in `@BeforeAll`, a `@Disabled` class), send `pending`. Otherwise send the test's own status. An assigned id always gets a result. Project frame first (`SourceFile` plus line, else the class name). Exit 1 when any remaining assigned test is `failed`, or when a hook outside a test failed. Holding the result until `execute` returns is still one id, inside the batch. | feasible with risk |
| P8, P9 | The client's own per-id store is what exit status reads, and what the `RunListener` events at `close` are built from. A retry replaces the entry there before the rerun. Listeners that write JUnit XML see one result per id. `remove_failed` matches the unique id. | feasible with risk |
| P14 | A fresh `Launcher.execute` rebuilds the engine. Root-store suite extensions re-run on every `execute`, and the adapter cannot stop that. A launcher-session store is opt-in for the extension author and is not on every JUnit 5 line this client supports. `LauncherSessionListener` is a different callback from a root-store extension. Assert "once" only for a session-scoped fixture the adapter itself registers. A project suite extension may run again. That divergence is named here. `@BeforeAll` still re-enters per assigned test (P15). | feasible with risk |
| P15, P16 | JUnit runs `@BeforeAll` once per class per `execute`. One id per `execute` re-enters it, including on a later batch. An `execute` of two methods of one class runs `@BeforeAll` once and is short of parity. The collect pass skips `interceptBeforeAllMethod` and `interceptAfterAllMethod`, so it does not add a hook count. Time the real-run callbacks for P16. `@BeforeAll` static state that the author expected to survive a class is reset per assigned test, matching RSpec's rewrite of `:all` to `:each`. | feasible with risk |
| P17 | The JVM and loaded classes stay. Discovery is not repeated per batch. | proven |
| P18 | Tags, `include`/`exclude` engines, and the Surefire `<includes>` patterns bound discovery the way `mvn test` would have. A launcher main with a classpath and no socket runs discovery and returns, for the dry-run. | proven |
| P21 | Surefire `forkCount` and Gradle `maxParallelForks` are the CI matrix's job, not an inner pool. Inside the forked JVM the provider runs the assigned ids one at a time so a JaCoCo dump belongs to one id. | proven |
| P22 | Platform unique ids are positional. A dynamic child cannot collide with another by taking a suffix: `selectUniqueId` of an id with `~` or `-dup` spliced into the segment selects nothing or rejects the segment. A duplicate id in the collect pass is a client bug. Fail that pass. Do not invent a suffix. | feasible with risk |
| P28 | JaCoCo agent once. Around each test, `org.jacoco.agent.rt.IAgent.getExecutionData(true)` dumps and resets. Map a class to a source path through the `SourceFile` attribute plus the package, and keep the path only when it is in the git snapshot. Inner classes map to the outer file. `.kt` is fine when it is in git. Generated sources that are not in git are dropped. Advertise `select` until a fixture shows a snapshot key. Do not fail the run to attach the agent. | feasible with risk |
| P32 | `invoke()` returns when the session closes. Surefire's normal provider does not get to run the whole suite first. | proven |

Gradle, after Surefire: a plugin or the test worker hosts this launcher. Develocity Test Distribution (Gradle `Test`, and Surefire/Failsafe from 2.22.2) partitions by historical time and can retry in the same JVM (`retryInSameJvm` defaults to true). They require the JUnit Platform. That is the same execution model, pointed at their broker. Our broker is the Selective server.

A CLI jar that cannot see the project's test classpath is not the client. The harness used in conformance constructs the classpath the way Surefire does, then calls the same `invoke` loop.

## Binding

**Stdio sidecar only.** Not JNI, not jni-rs, not the Panama foreign-function API.

JNI loads the Rust library into the test JVM. A panic in the transport aborts the process, which drops every result that was not flushed and fails the shard with no `test_case_result`. The sidecar's crash is a reconnect. jni-rs does not change that boundary.

Panama (`java.lang.foreign`) is a clean way to call a cdylib, and it has been stable since JDK 22. The suites this product is for still run on 17 and 21, and a client that requires 22 does not replace `mvn test` for them. Revisit Panama only if the supported floor moves.

The session loop is Java. It spawns `transport --stdio`, reads lines, and writes lines. Snapshot and upload are the same CLI subcommands. Ship a pure-Java jar. On first run, download the binary for the OS and arch, checksum it, cache it in `~/.selective/transport/<version>/`, and honor `SELECTIVE_TRANSPORT`. v1 triples: Linux gnu and musl, x86_64 and aarch64, plus macOS x86_64 and aarch64. Windows when the archive exists; enterprise CI is almost all Linux. A missing binary exits 1.

Maven Central gets the jar only. Native classifiers can wait until in-process bindings are actually wanted.

## Discovery and running a subset

The table above is the runner. The host order is Surefire first, then Gradle, same `Launcher`. Gradle `Test` has no public `executer` from 5.6 through current. `createTestExecuter()` is internal. `setTestExecuter` is package-private, which is what Develocity calls. Neither is API. The host is an init script, or a `Test` task that calls the launcher on the worker classpath. It still executes unique ids in the warm test worker. JDK 17 and 21. No JDK 22+ APIs. Do not shell `mvn -Dtest=` per batch. Conformance fixtures: a throwing `@BeforeAll`, a throwing `@AfterAll`, an assumption in `@BeforeAll`, a `@Disabled` class, and a factory that throws during the collect pass.

## Coverage (test map)

JaCoCo is the tracer, because it is already on the Surefire `argLine` of most suites.

- Attach the JaCoCo agent once.
- Around each test, dump execution data and reset (`org.jacoco.agent.rt.IAgent.getExecutionData(true)` resets as it dumps).
- The dump names classes, not source files. Resolve a class to a `.java` path through the class file's `SourceFile` attribute plus the package directory, and check that the path exists in the git snapshot. Inner classes map to the outer source file.
- Ignore the test classpath's dependency jars. Only project output directories count.
- Advertise `record` when the agent is attached, `select` when it is not. Do not fail the run to attach it. The Gradle/Maven plugins can add the agent on recording runs later; v1 can document `-javaagent`.

Kotlin and generated sources: `SourceFile` may be a `.kt` file, which is what we want if it is in git. Generated sources that are not in git must be dropped from the fragment or they will never match a blob.

JaCoCo probes bytecode that ran. A constant inlined from another class may not mark that class. A changed path full-runs when no test traces it, when the path is new, or when it matches a full-run pattern. A file some other test already traced is not a full-run, so a dependency this test reached only through an unmeasured child is a skip.

## Packaging and CI

- Maven Central: `ci.selective:selective-junit`. Pure Java, so one jar.
- Coordinates and the CLI live in `selectiveci/selective-java-junit`.
- The Surefire provider can be the same jar with a provider-class entry in `META-INF/services`, or a second artifact once the CLI conformance is green. One repository either way.
- Gradle plugin id `ci.selective.junit`, published to the Plugin Portal when the Gradle slice exists. Not in the first PR.
- GitHub Action unchanged.

## Risks

- The Surefire provider is the client. A unit test of `Launcher.execute` that never sees a Spring `argLine` has not finished P1 for a real build. The conformance project is a small Surefire suite with a context that fails if the JVM was not the forked one.
- JaCoCo class-to-source mapping for generated and multi-release jars. Orchestration ships while this advertises `select`.
- Gradle's test worker API moves. The plugin stays thin. The protocol stays in the jar.
- JDK 17 and 21 both run the conformance suite.
- Java has no language full-run list yet. Still to add: `pom.xml`, `build.gradle`, `build.gradle.kts`, `settings.gradle`, `gradle.lockfile`, `src/main/resources/application*.yml`, and Flyway and Liquibase directories. A changed path full-runs when no test traces it, when the path is new, or when it matches a full-run pattern. A file some other test already traced is not a full-run.
- Develocity already selects inside some of these builds. The first Java client is for suites that do not have it. We do not wrap their distributor.

## Effort

The launcher loop inside `SurefireProvider.invoke()` is the first slice, on JDK 17 and 21, with the `@BeforeAll` counter in that PR. The classpath-fed main is part of that slice, because it is how the mock server runs without Maven. Gradle is the next slice. JaCoCo mapping is the recording slice. Feasibility puts this language second, behind pytest, because the runner API is the one the platform already documents. The build-tool host is real work and it is the client, not a follow-up that can be skipped.

## Prior art

- JUnit Platform `Launcher`, unique ids, and `TestExecutionListener`. IDEs already drive this. Copy that, and point it at the server.
- Maven Surefire's JUnit Platform provider. Implement a sibling provider, do not wrap the `mvn` CLI.
- Gradle `Test` task and Develocity's test distributor. Their distribution unit is historical timing, and retries can stay in the JVM. The Selective host is the same launcher with the Selective server as the broker. `maxParallelForks` stays a CI setting.
- JaCoCo's agent dump-and-reset, which IntelliJ and mutation-testing tools use per test.
