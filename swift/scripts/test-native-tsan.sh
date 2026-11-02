#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
case "$(uname -m)" in
  arm64) task_target=aarch64-macos.14.0 ;;
  x86_64) task_target=x86_64-macos.14.0 ;;
  *) echo "Native Thread Sanitizer checks require macOS" >&2; exit 1 ;;
esac
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
zig build libfx-c -Dtarget="$task_target" -Dlibfx-tsan=true --prefix "$task_tmp/native"
mkdir -p "$task_tmp/package/swift"
cp Package.swift Package.resolved "$task_tmp/package/"
cp -R swift/Sources swift/Tests swift/Artifacts "$task_tmp/package/swift/"
task_archive="$task_tmp/package/swift/Artifacts/CFx.xcframework/macos-arm64_x86_64/libfx_core.a"
cp "$task_tmp/native/lib/libfx_core.a" "$task_archive"
nm -u "$task_archive" > "$task_tmp/native-symbols.txt"
if ! rg -q '__tsan_(read|write|func_entry)' "$task_tmp/native-symbols.txt"; then
  echo "Native archive has no Thread Sanitizer instrumentation" >&2
  exit 1
fi
swift test --package-path "$task_tmp/package" --sanitize thread --no-parallel \
  --filter "${LIBFX_NATIVE_TSAN_FILTER:-EngineLifecycleTests|CancellationOrderingTests|SessionLeaseTests|AgentLeaseTests|JournalAdmissionTests}"
