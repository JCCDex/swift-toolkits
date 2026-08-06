#!/bin/bash
#
# generate_coverage_report.sh — Run macOS tests with code coverage.
#
# Produces coverage/summary.txt and coverage/lcov.info.
# Can be run standalone or via: bundle exec fastlane macos_test

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COVERAGE_DIR="${COVERAGE_DIR:-$ROOT_DIR/coverage}"
cd "$ROOT_DIR"

echo "Running macOS tests with code coverage …"
swift test --enable-code-coverage

PROFDATA_PATH="$(find .build -type f -name 'default.profdata' | head -n 1)"

if [[ -z "$PROFDATA_PATH" ]]; then
  echo "Unable to locate default.profdata coverage file" >&2
  exit 1
fi

# SPM test binary name varies by platform and Swift version — find the
# executable Mach-O binary inside the .xctest bundle (largest file)
TEST_BINARY="$(find .build -type f \
  \( -name 'swift-toolkitsPackageTests' -o -name 'swift_toolkitsPackageTests' \) \
  -size +100k \
  | head -n 1)"

if [[ -z "$TEST_BINARY" ]]; then
  echo "Unable to locate test binary under .build/" >&2
  exit 1
fi

mkdir -p "$COVERAGE_DIR"

xcrun llvm-cov report "$TEST_BINARY" \
  --instr-profile "$PROFDATA_PATH" \
  --ignore-filename-regex='.*Tests\.swift|.build/' \
  > "$COVERAGE_DIR/summary.txt"

xcrun llvm-cov export -format=lcov "$TEST_BINARY" \
  --instr-profile "$PROFDATA_PATH" \
  --ignore-filename-regex='.*Tests\.swift|.build/' \
  > "$COVERAGE_DIR/lcov.info"

echo "Coverage reports written to $COVERAGE_DIR/"
cat "$COVERAGE_DIR/summary.txt"
