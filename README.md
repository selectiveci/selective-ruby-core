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

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/selectiveci/selective-ruby-core. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/selectiveci/selective-ruby-core/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
