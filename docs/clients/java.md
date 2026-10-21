# Java (JUnit 5)

Marketing order: last. JUnit 5 is the framework. Tests actually run through Maven Surefire or a Gradle `Test` task, so the client has a library layer and a build-tool layer. TestNG is out of scope until someone asks. Develocity (predictive selection and test distribution) and CloudBees Smart Tests are the competitors; both are already inside the build tool. A two-person team should not start here.

Read [SPEC.md](SPEC.md) for the wire contract.

## Binding

**Stdio sidecar only.** Not JNI, not jni-rs, not the Panama foreign-function API.

JNI loads the Rust library into the test JVM. A panic in the transport aborts the process, which drops every result that was not flushed and fails the shard with no `test_case_result`. The sidecar's crash is a reconnect. jni-rs does not change that boundary.

Panama (`java.lang.foreign`) is a clean way to call a cdylib, and it has been stable since JDK 22. The suites this product is for still run on 17 and 21, and a client that requires 22 does not replace `mvn test` for them. Revisit Panama only if the supported floor moves.

The session loop is Java. It spawns `transport --stdio`, reads lines, and writes lines. Snapshot and upload are the same CLI subcommands. Ship a pure-Java jar. On first run, download the binary for the OS and arch, checksum it, cache it in `~/.selective/transport/<version>/`, and honor `SELECTIVE_TRANSPORT`. v1 triples: Linux gnu and musl, x86_64 and aarch64, plus macOS x86_64 and aarch64. Windows when the archive exists; enterprise CI is almost all Linux. A missing binary exits 1.

Maven Central gets the jar only. Native classifiers can wait until in-process bindings are actually wanted.

## Discovery and running a subset

JUnit Platform is the one runner in this set that was built for "discover everything, then execute some ids."

- `Launcher.discover` with no method filter returns a `TestPlan`.
- Each `TestIdentifier` has a unique id (`[engine:junit-jupiter]/[class:com.example.BillingTest]/[method:tax()]`). That id is stable across line shifts and is the manifest id.
- `launcher.execute` with `DiscoverySelectors.selectUniqueId` runs exactly those tests, including `@BeforeEach` and extensions.
- `TestExecutionListener.executionFinished` reports the result. `SUCCESSFUL` -> `passed`, `FAILED` and `ABORTED` -> `failed`, `DISABLED` / skipped -> `pending`.

The process stays up. Discovery once, then `execute` per batch. A repeated unique id is executed again. Listeners that write JUnit XML must see one result per id; reset or replace the earlier one.

Dynamic tests (`@TestFactory`) get unique ids at discovery time. Use those ids. If a factory is non-deterministic, the manifest and a later retry will disagree; document that factories must be deterministic. Same constraint as PHPUnit data providers.

Vintage (JUnit 4) ids also come from the platform. v1 can advertise the junit-jupiter engine only and still discover vintage tests if they show up in the plan. Do not build a separate JUnit 4 runner.

### Gradle and Maven

The launcher needs a classpath: test classes, main classes, and dependencies. The build tool has it, a standalone jar does not.

v1 is a CLI, `selective junit`, that receives the classpath and the test-classes directory. Developers can prove the protocol without a plugin.

Maven, second: a Surefire provider (`SurefireProvider`) runs inside the forked JVM Surefire already created, so the classpath, `argLine`, and system properties are correct. The provider discovers, opens the session, and executes batches. This is the integration that replaces `mvn test` without asking the user to assemble a classpath. Surefire's provider API is the supported extension point (it is how the JUnit Platform provider itself is wired).

Gradle, third: a plugin that replaces the `Test` task's execution with the same launcher, on the test worker Gradle already forked. Develocity does this with Gradle's internal test-executor hooks. Prefer implementing `Test.executer` only if it stays stable on the Gradle versions we declare; otherwise an init script that builds the classpath and calls the CLI is the boring path. Start with current Gradle LTS and one older LTS, not every major.

Do not shell `mvn -Dtest=Class#method` per batch. That restarts the JVM and Surefire.

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

- Classpath assembly is the product. A launcher that works in a unit test and cannot see a Spring context on CI is not a client. The Surefire provider is the slice that makes it real, and it should follow the CLI immediately.
- JaCoCo class-to-source mapping for generated and multi-release jars.
- Gradle's test worker API moves. Keep the plugin thin and the protocol in the jar.
- JDK 17 and 21 both have to run the conformance suite. Do not use JDK 22+ APIs in the client.
- Server full-run patterns: `pom.xml`, `build.gradle`, `build.gradle.kts`, `settings.gradle`, `gradle.lockfile`, `src/main/resources/application*.yml`, Flyway and Liquibase directories. Enterprise suites will full-run on the first select attempt until those exist, which is correct and looks like "selection did nothing."
- Develocity customers already have a selector in-process. We will not out-integrate that in the first Java release. The CLI is for suites that do not have it.

## Effort

The JUnit Platform loop is a medium slice and the cleanest runner API of the five languages. The Surefire provider is the next slice and is what a design partner can turn on. The Gradle plugin is a third slice. JaCoCo mapping is a fourth, and until it is trustworthy the client advertises `select` (it can run a subset from a map recorded elsewhere, and it can snapshot). Recording is not required for orchestration and ordering.

This is still the last client to start. The binding work is shared with the earlier languages; the cost here is the build tool.

## Prior art

- JUnit Platform `Launcher`, unique ids, and `TestExecutionListener`. IDEs already drive this. Copy that, and point it at the server.
- Maven Surefire's JUnit Platform provider. Implement a sibling provider, do not wrap the `mvn` CLI.
- Gradle `Test` task, `maxParallelForks`, and Develocity's test distributor. Forks are static. Develocity is the bar and the reason this language is last.
- JaCoCo's agent dump-and-reset, which IntelliJ and mutation-testing tools use per test.
