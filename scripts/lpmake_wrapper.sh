#!/usr/bin/env bash

set -Eeuo pipefail

export LD_LIBRARY_PATH="/usr/local/lib/h3cknn-gsi/aosp-lib64:/usr/lib/x86_64-linux-gnu/android${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec /usr/local/lib/h3cknn-gsi/lpmake.bin "$@"
