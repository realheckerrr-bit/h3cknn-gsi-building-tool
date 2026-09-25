#!/usr/bin/env bash
# Exercise the EROFS repack path and the EROFS boot-contract validator.

set -Eeuo pipefail

ROOT_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/repack-erofs-test.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT

for command_name in mkfs.erofs fsck.erofs xz gzip file; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "[-] Missing test dependency: $command_name" >&2
    exit 1
  }
done

mkdir -p "$TEST_DIR/system/bin" "$TEST_DIR/system/etc/selinux"
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
cat > "$TEST_DIR/system/etc/selinux/plat_file_contexts" <<'EOF'
/system/bin/init u:object_r:init_exec:s0
EOF

pushd "$TEST_DIR" >/dev/null
bash "$ROOT_DIR/scripts/repack_gsi.sh" "$TEST_DIR/system" repack-erofs erofs
popd >/dev/null

OUTPUT_DIR="$TEST_DIR/workspace/output"
bash "$ROOT_DIR/scripts/validate_gsi_output.sh" \
  "$OUTPUT_DIR/repack-erofs.img.xz" \
  "$OUTPUT_DIR/repack-erofs.img.gz"

echo "==> EROFS repack integration test passed."
