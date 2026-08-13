# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

## Available Actions

## iOS

### ios macos_test

```sh
[bundle exec] fastlane ios macos_test
```

Run macOS tests with coverage (xcodebuild + xcov)

### ios ios_test

```sh
[bundle exec] fastlane ios ios_test
```

Run iOS Simulator tests with coverage (xcodebuild + xcov)

### ios all_tests

```sh
[bundle exec] fastlane ios all_tests
```

Run all tests (macOS + iOS Simulator) with coverage

### ios ios_test_only

```sh
[bundle exec] fastlane ios ios_test_only
```

Run iOS Simulator tests only (no coverage)

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
