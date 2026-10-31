#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_tmp="$(mktemp -d)"
report_dir="${LIBFX_X86_64_CONSUMER_REPORT_DIR:-$(mktemp -d)}"
mkdir -p "$report_dir" "$task_tmp/bin"
trap 'rm -rf "$task_tmp"' EXIT
real_swift="$(command -v swift)"
archive="$repo_root/swift/Artifacts/CFx.xcframework/macos-arm64_x86_64/libfx_core.a"
shasum -a 256 "$archive" > "$report_dir/archive-before.sha256"

# Reuse the full public consumer without changing its native-architecture gate.
cat > "$task_tmp/bin/swift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 6 || "$1" != run || "$2" != --package-path || "$4" != -c || "$5" != release || "$6" != Consumer ]]; then
    echo "Unexpected Swift consumer invocation" >&2
    exit 1
fi
build_args=(--package-path "$3" --scratch-path "$LIBFX_X86_64_SCRATCH" -c release --arch x86_64 --product Consumer)
set +e
"$LIBFX_X86_64_SWIFT" build "${build_args[@]}" > "$LIBFX_X86_64_REPORT/build.stdout" 2> "$LIBFX_X86_64_REPORT/build.stderr"
build_status=$?
set -e
echo "$build_status" > "$LIBFX_X86_64_REPORT/build.exit"
if [[ "$build_status" != 0 ]]; then
    cat "$LIBFX_X86_64_REPORT/build.stdout" "$LIBFX_X86_64_REPORT/build.stderr" >&2
    exit "$build_status"
fi
bin_dir="$("$LIBFX_X86_64_SWIFT" build "${build_args[@]}" --show-bin-path)"
file "$bin_dir/Consumer" > "$LIBFX_X86_64_REPORT/executable.txt"
[[ "$(xcrun lipo -archs "$bin_dir/Consumer")" == x86_64 ]]
set +e
/usr/bin/arch -x86_64 "$bin_dir/Consumer" > "$LIBFX_X86_64_REPORT/runtime.stdout" 2> "$LIBFX_X86_64_REPORT/runtime.stderr"
runtime_status=$?
set -e
echo "$runtime_status" > "$LIBFX_X86_64_REPORT/runtime.exit"
cat "$LIBFX_X86_64_REPORT/runtime.stdout"
if [[ "$runtime_status" != 0 || -s "$LIBFX_X86_64_REPORT/runtime.stderr" ]]; then
    cat "$LIBFX_X86_64_REPORT/runtime.stderr" >&2
    exit 1
fi
SH
chmod +x "$task_tmp/bin/swift"
set +e
PATH="$task_tmp/bin:$PATH" LIBFX_X86_64_SWIFT="$real_swift" LIBFX_X86_64_SCRATCH="$task_tmp/build" \
    LIBFX_X86_64_REPORT="$report_dir" bash "$repo_root/swift/scripts/test-consumer.sh" \
    > "$report_dir/consumer.stdout" 2> "$report_dir/consumer.stderr"
consumer_status=$?
set -e
echo "$consumer_status" > "$report_dir/consumer.exit"
shasum -a 256 "$archive" > "$report_dir/archive-after.sha256"
cat "$report_dir/consumer.stdout"
echo "x86_64 Swift consumer report: $report_dir"
if [[ "$consumer_status" != 0 || -s "$report_dir/consumer.stderr" ]]; then
    cat "$report_dir/consumer.stderr" >&2
    exit 1
fi
cmp "$report_dir/archive-before.sha256" "$report_dir/archive-after.sha256"
echo "x86_64 Release Swift consumer passed under Rosetta; XCFramework unchanged"
