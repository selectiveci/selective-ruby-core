# Java (JUnit 5)

Marketing order: last. Feasibility of full parity: second, behind pytest. JUnit 5 is the framework. Tests run through Maven Surefire or a Gradle `Test` task, so the client is the launcher plus a host. TestNG is out of scope until someone asks. Develocity and CloudBees Smart Tests already sit inside the build tool; that is a product overlap, and it does not change the runner.

Read [SPEC.md](SPEC.md) for the wire contract and the parity bar.

**Verdict: proven for the split.** The JUnit Platform `Launcher` was built to discover a plan and then `execute` unique ids, which is what IDEs already do, in the JVM that is already up. The first framework is that launcher **hosted by a Surefire provider**, because `mvn test` is where the classpath, `argLine`, and the Spring context actually exist. A CLI that is handed the same classpath is the conformance harness for the same code, not a smaller client. Gradle is the second host, same launcher. No row is blocked. No fork. Develocity's distributor is a different broker; we do not copy it.

## Parity

Rows P4, P10–P14, P16, P19, P23–P27, and P29–P31 are the session loop on `transport --stdio`, inside the Surefire forked JVM. Port of `Controller`. Rating: proven.

| Id | Mechanism | Rating |
|---|---|---|
| P1 | `Launcher.discover` once. Each `run_test_cases` id is `launcher.execute(request)` with `DiscoverySelectors.selectUniqueId`, in this JVM. `SurefireProvider.invoke()` is the loop: Surefire has already forked, put the classpath and `argLine` in place, and called `invoke`. The provider reads the socket until `close`. Do not shell `mvn -Dtest=Class#method` per batch. One unique id per `execute` so `@BeforeAll` re-enters (P15). | proven |
| P2 | The platform unique id, `[engine:junit-jupiter]/[class:com.example.BillingTest]/[method:tax()]`. Stable across line shifts. `@TestFactory` dynamic children get ids at discovery time; factories must be deterministic. Vintage ids come from the platform too. v1 registers the junit-jupiter engine and still reports vintage tests that appear in the plan. No separate JUnit 4 runner. TestNG is out of scope. | proven |
| P3 | `TestPlan` from `discover`, walking containers to methods and dynamic tests, without `execute`. An empty plan exits 1. | proven |
| P5–P7, P20 | `TestExecutionListener.executionFinished`. `SUCCESSFUL` → `passed`, `FAILED` and `ABORTED` → `failed`, skipped / `DISABLED` → `pending`. Project frame first (`SourceFile` plus line, else the class name). Exit 1 when a remaining test failed or aborted. | proven |
| P8, P9 | Listeners that write JUnit XML see one result per id. Replace the earlier one before the rerun. `remove_failed` matches the unique id. | proven |
| P15, P16 | JUnit runs `@BeforeAll` once per class per `execute`. One id per `execute` re-enters it, including on a later batch. An `execute` of two methods of one class runs `@BeforeAll` once and is short of parity. Time those callbacks for P16. `@BeforeAll` static state that the author expected to survive a class is reset per assigned test, matching RSpec's rewrite of `:all` to `:each`. Suite-level extensions registered once stay once (P14). | proven |
| P17 | The JVM and loaded classes stay. Discovery is not repeated per batch. | proven |
| P18 | Tags, `include`/`exclude` engines, and the Surefire `<includes>` patterns bound discovery the way `mvn test` would have. A launcher main with a classpath and no socket runs discovery and returns, for the dry-run. | proven |
| P21 | Surefire `forkCount` and Gradle `maxParallelForks` are the CI matrix's job, not an inner pool. Inside the forked JVM the provider runs the assigned ids one at a time so a JaCoCo dump belongs to one id. | proven |
| P22 | Unique ids are unique per plan. A dynamic factory that emits a duplicate gets a warning and a suffix, and both tests are listed. | proven |
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

The table above is the runner. The host order is Surefire first, then Gradle, same `Launcher`. `Test.executer` is the Gradle hook if it stays stable on the two LTS lines we declare; an init script that builds the classpath and calls the same launcher main is the fallback host, and it still executes unique ids in the warm test worker. JDK 17 and 21. No JDK 22+ APIs.

## Coverage (test map)

JaCoCo is the tracer, because it is already on the Surefire `argLine` of most suites.

- Attach the JaCoCo agent once.
- Around each test, dump execution data and reset (`org.jacoco.agent.rt.IAgent.getExecutionData(true)` resets as it dumps).
- The dump names classes, not source files. Resolve a class to a `.java` path through the class file's `SourceFile` attribute plus the package directory, and check that the path exists in the git snapshot. Inner classes map to the outer source file.
- Ignore the test classpath's dependency jars. Only project output directories count.
- Advertise `record` when the agent is attached, `select` when it is not. Do not fail the run to attach it. The Gradle/Maven plugins can add the agent on recording runs later; v1 can document `-javaagent`.

Kotlin and generated sources: `SourceFile` may be a `.kt` file, which is what we want if it is in git. Generated sources that are not in git must be dropped from the fragment or they will never match a blob.

JaCoCo probes bytecode that ran. A constant inlined from another class may not mark that class. The server full-runs on an untraced changed file. That is the same safe bias as the Ruby tracer's known gaps.

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
- Server full-run patterns: `pom.xml`, `build.gradle`, `build.gradle.kts`, `settings.gradle`, `gradle.lockfile`, `src/main/resources/application*.yml`, Flyway and Liquibase directories. Until those exist, an untraced change full-runs, which is the safe direction.
- Develocity already selects inside some of these builds. The first Java client is for suites that do not have it. We do not wrap their distributor.

## Effort

The launcher loop inside `SurefireProvider.invoke()` is the first slice, on JDK 17 and 21, with the `@BeforeAll` counter in that PR. The classpath-fed main is part of that slice, because it is how the mock server runs without Maven. Gradle is the next slice. JaCoCo mapping is the recording slice. Feasibility puts this language second, behind pytest, because the runner API is the one the platform already documents. The build-tool host is real work and it is the client, not a follow-up that can be skipped.

## Prior art

- JUnit Platform `Launcher`, unique ids, and `TestExecutionListener`. IDEs already drive this. Copy that, and point it at the server.
- Maven Surefire's JUnit Platform provider. Implement a sibling provider, do not wrap the `mvn` CLI.
- Gradle `Test` task and Develocity's test distributor. Their distribution unit is historical timing, and retries can stay in the JVM. The Selective host is the same launcher with the Selective server as the broker. `maxParallelForks` stays a CI setting.
- JaCoCo's agent dump-and-reset, which IntelliJ and mutation-testing tools use per test.
