#!/usr/bin/env bash
# Regression test for the complete device-neutral TrebleDroid target matrix.

set -Eeuo pipefail

ROOT_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/source-variant-test.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT

# build_source.sh intentionally stops after validation because this smoke test
# does not contain an Android source tree. A valid target must get past the
# variant guard; an invalid target must fail there with status 2.
for variant in \
  treble_arm64_avN treble_arm64_bvN treble_arm64_bgS \
  treble_arm_avN treble_arm_bvN \
  treble_a64_avN treble_a64_bvN treble_a64_bgS; do
  LOG="$TEST_DIR/$variant.log"
  set +e
  bash "$ROOT_DIR/source/build_source.sh" "$TEST_DIR/tree" "$variant" userdebug >"$LOG" 2>&1
  STATUS=$?
  set -e
  if [ "$STATUS" -eq 2 ] || grep -Fq 'Unsupported Treble variant' "$LOG"; then
    echo "[-] Valid Treble target was rejected: $variant" >&2
    cat "$LOG" >&2
    exit 1
  fi
done

LOG="$TEST_DIR/invalid.log"
set +e
bash "$ROOT_DIR/source/build_source.sh" "$TEST_DIR/tree" treble_arm64_invalid userdebug >"$LOG" 2>&1
STATUS=$?
set -e
if [ "$STATUS" -ne 2 ] || ! grep -Fq 'Unsupported Treble variant' "$LOG"; then
  echo "[-] Invalid Treble target was not rejected early." >&2
  cat "$LOG" >&2
  exit 1
fi

echo "==> Treble source variant matrix test passed."
