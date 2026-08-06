#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${WORK_DIR:-/tmp/tink-objc-build}"
BAZELISK_BIN="${BAZELISK_BIN:-/tmp/bazelisk}"
TINK_REPO_URL="${TINK_REPO_URL:-https://github.com/tink-crypto/tink-objc.git}"
TINK_REF="${TINK_REF:-main}"
OUTPUT_DIR="${1:-$ROOT_DIR/Vendor/Tink}"

mkdir -p "$OUTPUT_DIR"
rm -rf "$WORK_DIR"

git clone --depth=1 --branch "$TINK_REF" "$TINK_REPO_URL" "$WORK_DIR"

if [[ ! -x "$BAZELISK_BIN" ]]; then
  curl -L https://github.com/bazelbuild/bazelisk/releases/download/v1.29.0/bazelisk-darwin-arm64 -o "$BAZELISK_BIN"
  chmod +x "$BAZELISK_BIN"
fi

python3 - <<'PY' "$WORK_DIR/tools/release/postprocess_xcframework.sh"
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = """  if [[ \"${PLATFORM}\" =~ .*simulator ]]; then
    ld_args+=( -ios_simulator_version_min )
  else
    ld_args+=( -ios_version_min )
  fi
  ld_args+=( \"${MINIMUM_IOS_VERSION}\" )
"""
new = """  if [[ \"${PLATFORM}\" =~ .*simulator ]]; then
    ld_args+=( -platform_version ios-simulator )
  else
    ld_args+=( -platform_version ios )
  fi
  ld_args+=( \"${MINIMUM_IOS_VERSION}\" \"${MINIMUM_IOS_VERSION}\" )
"""
if old not in text:
    raise SystemExit("expected linker flag block not found in postprocess_xcframework.sh")
path.write_text(text.replace(old, new, 1))
PY

cd "$WORK_DIR"
"$BAZELISK_BIN" build //Tink:Tink_static_xcframework

rm -rf "$OUTPUT_DIR/Tink.xcframework"
unzip -qq bazel-bin/Tink/Tink.xcframework.zip -d "$OUTPUT_DIR"

echo "Vendored Tink.xcframework at $OUTPUT_DIR/Tink.xcframework"