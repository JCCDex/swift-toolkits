#!/bin/bash
#
# generate_html_coverage.sh — Generate an HTML coverage report from
# llvm-cov profdata + test binary using only Xcode toolchain.
#
# Open coverage/index.html in a browser to see per-line coverage
# (green = covered, red = uncovered, grey = not compiled).
#
# Usage (standalone, after running tests with --enable-code-coverage):
#   ./Scripts/generate_html_coverage.sh
#
# Usage (with explicit inputs):
#   PROFDATA=path/to/default.profdata \
#   TEST_BINARY=path/to/test-binary \
#   COVERAGE_DIR=coverage \
#   ./Scripts/generate_html_coverage.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COVERAGE_DIR="${COVERAGE_DIR:-$ROOT_DIR/coverage}"
HTML_DIR="${COVERAGE_DIR}/html"

# ── Locate inputs if not provided ────────────────────────────────────────────

PROFDATA="${PROFDATA:-$(find "$COVERAGE_DIR" -type f -name '*.profdata' | head -n 1)}"

if [[ -z "$PROFDATA" ]]; then
  echo "Error: no .profdata file found in $COVERAGE_DIR" >&2
  echo "Run tests with coverage first, or set PROFDATA=…" >&2
  exit 1
fi

# Find the test binary — check multiple common locations
if [[ -z "${TEST_BINARY:-}" ]]; then
  # SPM macOS
  TEST_BINARY="$(find "$ROOT_DIR/.build" -type f \
    \( -name 'swift-toolkitsPackageTests' -o -name 'swift_toolkitsPackageTests' \) \
    -size +100k 2>/dev/null | head -n 1)"

  # SPM iOS simulator (xcodebuild)
  if [[ -z "$TEST_BINARY" ]]; then
    TEST_BINARY="$(find "$ROOT_DIR/.build/DerivedData" -type f \
      -path '*.xctest/*' \
      ! -name '*.plist' ! -name '*.dylib' ! -name '*.so' \
      ! -name '*.swiftmodule' ! -name '*.json' \
      -size +100k 2>/dev/null | head -n 1)"
  fi
fi

if [[ -z "$TEST_BINARY" ]]; then
  echo "Error: no test binary found" >&2
  echo "Set TEST_BINARY=… to the executable inside the .xctest bundle" >&2
  exit 1
fi

echo "profdata:    $PROFDATA"
echo "test binary: $TEST_BINARY"
echo ""

# ── Generate HTML ────────────────────────────────────────────────────────────

mkdir -p "$HTML_DIR"

xcrun llvm-cov show "$TEST_BINARY" \
  --instr-profile "$PROFDATA" \
  --ignore-filename-regex='.*Tests\.swift|.build/' \
  --format=html \
  --output-dir "$HTML_DIR" \
  --show-instantiations \
  --show-line-counts-or-regions \
  --show-expansions

echo "HTML coverage report generated:"
echo "  $HTML_DIR/index.html"
echo ""
echo "Open it with:"
echo "  open $HTML_DIR/index.html"
