#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
task_arch="${LIBFX_C_ARCH:-$(uname -m)}"
task_archive="${LIBFX_C_ARCHIVE:-swift/Artifacts/CFx.xcframework/macos-arm64_x86_64/libfx_core.a}"
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
cc -arch "$task_arch" -mmacosx-version-min=14.0 -fobjc-arc -Wall -Wextra -Werror \
  -I swift/Sources/CFx/include swift/Tests/CABI/fetch.m "$task_archive" -framework Foundation -o "$task_tmp/fetch"
FX_TRACE=1 FX_TRACE_LOG="$task_tmp/trace.log" FX_TRACE_SCOPES=napi,acp,interrupt FX_TRACE_STDERR=1 \
  /usr/bin/arch -"$task_arch" "$task_tmp/fetch" > "$task_tmp/stdout" 2> "$task_tmp/stderr"
test ! -s "$task_tmp/stdout"
test ! -s "$task_tmp/stderr"
test ! -e "$task_tmp/trace.log"
echo "C ABI fetch identity, body separation, backpressure, URL rejection and ambient trace isolation passed ($task_arch)"
