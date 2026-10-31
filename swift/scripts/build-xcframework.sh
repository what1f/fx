#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "XCFramework packaging requires macOS and Xcode" >&2
  exit 1
fi
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
for task_arch in aarch64 x86_64; do
  zig build libfx-c -Dtarget="${task_arch}-macos.14.0" --prefix "$task_tmp/$task_arch"
done
mkdir -p "$task_tmp/Headers"
cp swift/Sources/CFx/include/fx.h "$task_tmp/Headers/fx.h"
sed 's@include/fx.h@fx.h@' swift/Sources/CFx/module.modulemap > "$task_tmp/Headers/module.modulemap"
xcrun lipo -create "$task_tmp/aarch64/lib/libfx_core.a" "$task_tmp/x86_64/lib/libfx_core.a" -output "$task_tmp/libfx_core.a"
xcodebuild -create-xcframework -library "$task_tmp/libfx_core.a" -headers "$task_tmp/Headers" -output "$task_tmp/CFx.xcframework"
mkdir -p swift/Artifacts
rm -rf swift/Artifacts/CFx.xcframework
mv "$task_tmp/CFx.xcframework" swift/Artifacts/CFx.xcframework
