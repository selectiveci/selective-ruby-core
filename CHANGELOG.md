## [Unreleased]

## [0.2.5] - 2024-05-25
- Add first-class support for [Mint](https://www.rwx.com/mint)!

## [0.2.4] - 2024-02-28
- Bugfix quotes in env configuration (such as PR titles)
- Ship transport v0.1.1: https://github.com/selectiveci/transport/releases/tag/v0.1.1

## [0.2.3] - 2024-02-06

- Fix a bug in the file correlator where test files were being correlated to test files
- Fix a bug where the reconnect parameter would never be set upon reconnect
- Increase max number of reconnect/retries from 4 -> 10
- Implement "report at finish" for debug purposes

## [0.2.2] - 2024-01-26

- Pass test case callback to runner

## [0.2.1] - 2024-01-19

- Add Semaphore support

## [0.2.0] - 2024-01-12

- Add committer information to build_env

## [0.1.9] - 2024-01-12

- Bugfix for issue that could cause runner to hang
- Implement basic configuration validation

## [0.1.8] - 2024-01-05

- Fix a minor bug causing the "unable to correlate" warning

## [0.1.7] - 2024-01-05

- PR diff / test-file correlation for smarter test ordering

## [0.1.6] - 2024-01-03

- Upgrade to Ruby 3.3
- Add explicit support for CircleCI
- Refactor controller
- Send version information in connection parameters

## [0.1.5] - 2023-12-08

- Bugfix for zeitwerk when eager loading is enabled
- Increase the time before failure when connection is not made

## [0.1.4] - 2023-12-05

- Always prefer selective env-vars (allow overriding CI provider vars)
- Fix bug where some runner_id's could cause an error

## [0.1.3] - 2023-11-20

- Get run_id and run_attempt from build env if possible
- Misc housekeeping/test/release script updates

## [0.1.2] - 2023-11-10

- Fix modified_test_files
- Implement generic "print_notice" message
- Disable logging by default & add --log flag

## [0.1.1] - 2023-11-03

- Implemented release scripts
- Updated Readme

## [0.1.0] - 2023-10-26

- Initial release
