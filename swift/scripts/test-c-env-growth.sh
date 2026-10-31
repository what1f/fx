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
python3 - "$task_arch" "$task_tmp" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

architecture, directory = sys.argv[1:]
root = Path(directory)
# Match the upstream process isolation: no ambient configuration or credentials.
environment = {"PATH": os.environ["PATH"], "HOME": os.environ.get("HOME", "/tmp")}
for names in (0, 10, 200):
    for run in range(3):
        workspace = root / f"run-{names}-{run}"
        workspace.mkdir()
        result = subprocess.run(
            ["/usr/bin/arch", f"-{architecture}", str(root / "fetch"), "--environment-growth", str(names), str(workspace)],
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30,
        )
        assert result.returncode == 0, f"{names} new variables, run {run}: exit {result.returncode}\n{result.stderr.decode(errors='replace')}"
        assert not result.stdout, f"{names} new variables, run {run}: unexpected stdout"
        assert not result.stderr, f"{names} new variables, run {run}: {result.stderr.decode(errors='replace')}"
print(f"C ABI environment growth passed: 0, 10 and 200 variables after first create; 3 isolated runs each, 3 model turns per run ({architecture})")
PY
