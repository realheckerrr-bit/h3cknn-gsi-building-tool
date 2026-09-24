#!/usr/bin/env bash
# Regression test for direct and extensionless GSI input preservation.

set -Eeuo pipefail

ROOT_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/preserve-gsi-test.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT

for command_name in file mke2fs xz gzip od; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "[-] Missing test dependency: $command_name" >&2
    exit 1
  }
done

truncate -s 8M "$TEST_DIR/source.img"
mke2fs -t ext4 -F -L system "$TEST_DIR/source.img" >/dev/null

run_case() {
  local input="$1"
  local name="$2"
  local output="$TEST_DIR/$name"
  mkdir -p "$output"
  bash "$ROOT_DIR/scripts/preserve_gsi.sh" "$input" "$name" "$output" >/dev/null
  xz -t "$output/output/$name.img.xz"
  gzip -t "$output/output/$name.img.gz"
  gzip -dc "$output/output/$name.img.gz" > "$TEST_DIR/$name.out.img"
  test "$(od -An -tx1 -j1080 -N2 "$TEST_DIR/$name.out.img" | tr -d '[:space:]')" = 53ef
}

run_case "$TEST_DIR/source.img" direct

xz -c "$TEST_DIR/source.img" > "$TEST_DIR/source-xz-no-extension"
run_case "$TEST_DIR/source-xz-no-extension" xz-extensionless

gzip -c "$TEST_DIR/source.img" > "$TEST_DIR/source-gz-no-extension"
run_case "$TEST_DIR/source-gz-no-extension" gz-extensionless

echo "==> GSI input preservation test passed."
