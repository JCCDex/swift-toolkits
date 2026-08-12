#!/bin/bash
#
# test_ios_simulator.sh — Run SwiftVault tests on an iOS simulator with
# optional code coverage.
#
# Usage:
#   ./Scripts/test_ios_simulator.sh
#   COVERAGE=1 ./Scripts/test_ios_simulator.sh
#
# Environment variables (all optional):
#   SCHEME        — SPM scheme name (default: swift-toolkits)
#   DEVICE_NAME   — Simulator device name (default: SwiftVaultTinkTest)
#   DEVICE_TYPE   — Simulator device type identifier
#   DEVICE_OS     — iOS major version to run on (e.g. "18"); empty = newest available
#   COVERAGE      — Set to "1" to enable coverage collection
#   COVERAGE_DIR  — Directory for coverage output (default: coverage)

set -euo pipefail

SCHEME="${SCHEME:-swift-toolkits}"
DEVICE_NAME="${DEVICE_NAME:-SwiftVaultTinkTest}"
DEVICE_TYPE="${DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-16}"
DEVICE_OS="${DEVICE_OS:-}"
COVERAGE="${COVERAGE:-0}"
COVERAGE_DIR="${COVERAGE_DIR:-coverage}"

if [[ -n "$DEVICE_OS" ]]; then
  RUNTIME_ID="${RUNTIME_ID:-$(xcrun simctl list runtimes | awk -F ' - ' -v os="$DEVICE_OS" '/iOS/ && $0 !~ /unavailable/ && $0 !~ /beta/ && $0 ~ "iOS " os "\\." { runtime=$NF } END { print runtime }')}"
else
  RUNTIME_ID="${RUNTIME_ID:-$(xcrun simctl list runtimes | awk -F ' - ' '/iOS/ && $0 !~ /unavailable/ && $0 !~ /beta/ { runtime=$NF } END { print runtime }')}"
fi

if [[ -z "$RUNTIME_ID" ]]; then
  echo "Unable to find an available iOS simulator runtime" >&2
  exit 1
fi

DEVICE_ID="$(xcrun simctl list devices available | sed -n "s/.*$DEVICE_NAME (\([^)]*\)).*/\1/p" | head -n 1)"

if [[ -z "$DEVICE_ID" ]]; then
  echo "Creating simulator device '$DEVICE_NAME' …"
  DEVICE_ID="$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME_ID")"
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

XCODEBUILD_ARGS=(
  test
  -skipPackagePluginValidation
  -scheme "$SCHEME"
  -destination "id=$DEVICE_ID"
)

if [[ "$COVERAGE" == "1" ]]; then
  DERIVED_DATA="$ROOT_DIR/.build/DerivedData/ios-coverage"
  mkdir -p "$DERIVED_DATA"

  XCODEBUILD_ARGS+=(
    -enableCodeCoverage YES
    -derivedDataPath "$DERIVED_DATA"
  )

  echo "Running tests with coverage on simulator $DEVICE_NAME ($DEVICE_ID) …"
else
  echo "Running tests on simulator $DEVICE_NAME ($DEVICE_ID) …"
fi

xcodebuild "${XCODEBUILD_ARGS[@]}"

# ── Coverage collection ──────────────────────────────────────────────────────

if [[ "$COVERAGE" == "1" ]]; then
  echo ""
  echo "Collecting coverage data …"

  mkdir -p "$COVERAGE_DIR"

  # Find the .profraw file produced by the test run
  PROFRAW="$(find "$DERIVED_DATA" -type f -name '*.profraw' | head -n 1)"
  if [[ -z "$PROFRAW" ]]; then
    echo "Warning: no .profraw file found — coverage not generated" >&2
    exit 0
  fi

  PROFDATA="$COVERAGE_DIR/default.profdata"
  xcrun llvm-profdata merge -sparse "$PROFRAW" -o "$PROFDATA"

  # Locate the test binary inside the .xctest bundle (largest Mach-O binary)
  TEST_BINARY="$(find "$DERIVED_DATA/Build/Products" -type f \
    -path '*.xctest/*' \
    ! -name '*.plist' \
    ! -name '*.dylib' \
    ! -name '*.so' \
    ! -name '*.swiftmodule' \
    ! -name '*.json' \
    -size +100k \
    | head -n 1)"

  if [[ -z "$TEST_BINARY" ]]; then
    echo "Warning: no test binary found — coverage not generated" >&2
    exit 0
  fi

  # Human-readable summary
  xcrun llvm-cov report "$TEST_BINARY" \
    --instr-profile "$PROFDATA" \
    --ignore-filename-regex='.*Tests\.swift|.build/' \
    > "$COVERAGE_DIR/summary.txt"

  # lcov export for downstream tools (codecov, coveralls, etc.)
  xcrun llvm-cov export -format=lcov "$TEST_BINARY" \
    --instr-profile "$PROFDATA" \
    --ignore-filename-regex='.*Tests\.swift|.build/' \
    > "$COVERAGE_DIR/lcov.info"

  echo "Coverage reports written to $COVERAGE_DIR/"
  cat "$COVERAGE_DIR/summary.txt"
fi
