#!/usr/bin/env bash
# Exercise the OEM-repack ext4 path and validate both published image forms.

set -Eeuo pipefail

ROOT_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/repack-gsi-test.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/system/etc/selinux"
mkdir -p "$TEST_DIR/system/bin"
cat > "$TEST_DIR/system/build.prop" <<'EOF'
ro.treble.enabled=true
ro.product.system.cpu.abilist=arm64-v8a,armeabi-v7a,armeabi
ro.build.version.release=14
ro.build.version.sdk=34
EOF
cat > "$TEST_DIR/system/bin/init" <<'EOF'
#!/system/bin/sh
EOF
chmod 755 "$TEST_DIR/system/bin/init"
# A small text context file lets e2fsdroid exercise its SELinux-label path
# when the host provides that Android build tool. Hosts without it use the
# guarded mounted-copy fallback in repack_gsi.sh.
cat > "$TEST_DIR/system/etc/selinux/plat_file_contexts" <<'EOF'
/ u:object_r:system_file:s0
EOF

pushd "$TEST_DIR" >/dev/null
bash "$ROOT_DIR/scripts/repack_gsi.sh" "$TEST_DIR/system" repack-smoke ext4
popd >/dev/null

OUTPUT_DIR="$TEST_DIR/workspace/output"
bash "$ROOT_DIR/scripts/validate_gsi_output.sh" \
  "$OUTPUT_DIR/repack-smoke.img.xz" \
  "$OUTPUT_DIR/repack-smoke.img.gz"

RAW_IMAGE="$TEST_DIR/repack-smoke.raw.img"
gzip -dc "$OUTPUT_DIR/repack-smoke.img.gz" > "$RAW_IMAGE"
debugfs -R 'cat /build.prop' "$RAW_IMAGE" 2>/dev/null \
  | grep -F 'ro.treble.enabled=true' >/dev/null

# A filesystem with build.prop but no second-stage init must not pass the
# release validator merely because its ext4 magic is valid.
BAD_IMAGE="$TEST_DIR/repack-smoke.bad.raw.img"
cp -- "$RAW_IMAGE" "$BAD_IMAGE"
debugfs -w -R 'rm /bin/init' "$BAD_IMAGE" >/dev/null 2>&1
gzip -c "$BAD_IMAGE" > "$TEST_DIR/repack-smoke.bad.img.gz"
xz -c "$BAD_IMAGE" > "$TEST_DIR/repack-smoke.bad.img.xz"
if bash "$ROOT_DIR/scripts/validate_gsi_output.sh" \
  "$TEST_DIR/repack-smoke.bad.img.xz" \
  "$TEST_DIR/repack-smoke.bad.img.gz" >/dev/null 2>&1; then
  echo "[-] Image without second-stage init incorrectly passed validation." >&2
  exit 1
fi

echo "==> ext4 repack integration test passed."
