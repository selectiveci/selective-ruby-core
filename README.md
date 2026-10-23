# Selective Ruby Core

Selective is the fastest way to get the feedback you need out of your existing CI!

Do not use this gem directly. It is a library used by runners such as [selective-ruby-rspec](https://github.com/selectiveci/selective-ruby-rspec).

## Test selection

When a suite enables test selection in Selective, the runner takes part
automatically. There's nothing to configure in the project:

- **Recording.** On a recording run (chosen by the server, at most about once
  a day, or forced with `SELECTIVE_TEST_MAP_RECORD=1`), every test is traced
  and the files it executes are uploaded when the runner finishes.
- **Selecting.** On other runs the runner sends the git blob hash of every
  tracked file with its manifest, and the server skips tests none of whose
  files changed.

Recording uses the optional `selective_tracer` native extension, which is
built when the gem is installed, so installing the gem needs `make` (as any
gem with a native extension does). If the tracer itself can't be built (no
C compiler, an unsupported Ruby, or a compile error), installation still
succeeds and the runner can still run selected subsets; it just can't
record. To build it for development:

```bash
bundle exec rake compile
```

| Variable | Effect |
|---|---|
| `SELECTIVE_TEST_MAP_RECORD=1` | Record a map on this run, however fresh the current one is (for example a nightly full run). |
| `SELECTIVE_TEST_MAP_DISABLE=1` | Take no part in selection: always run the full suite, never record. |
| `SELECTIVE_TEST_MAP_IGNORE=dir1,dir2` | Extra directories inside the project whose code isn't the project's own (vendored code, generated clients). Installed gems are ignored automatically. |

## Transport

The runner spawns the `transport` binary from `lib/bin/transport`, or from
`SELECTIVE_TRANSPORT` when that variable is an explicit path. The default is
stdio:

```text
SELECTIVE_TRANSPORT_URL=wss://... transport --stdio
```

The URL, including the API key, is that environment variable. It is not a
process argument. The runner writes client messages to the transport's stdin
and reads server commands from its stdout, one JSON object per line. A line
whose contents are `exit` shuts the transport down and is not a test result.
The transport's own logs are inherited on stderr, so a refused connection is
printed by the transport itself.

`SELECTIVE_TRANSPORT_FIFO=1` keeps the previous sidecar for this release. That
mode still creates `/tmp/<runner_id>_1` and `/tmp/<runner_id>_2` and still
passes the URL and runner id as arguments. Stdio does not create those FIFOs.

A binary without `--stdio`, such as v0.1.1 or v0.1.2, runs as the FIFO sidecar
instead, and the runner prints one warning. A binary that cannot run at all
exits 1 with its own error. `bin/get_transport` builds the commit in `TRANSPORT_REF` at the top of
that script, which needs a Rust toolchain. Change `TRANSPORT_REF` to a release
tag such as `v0.2.0` once a release includes `--stdio`; a tag is downloaded
instead of built, which is what `bin/release` needs for every platform.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/selectiveci/selective-ruby-core. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/selectiveci/selective-ruby-core/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
