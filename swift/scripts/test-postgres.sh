#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
pg_bin="${LIBFX_POSTGRES_BIN_DIR:-/opt/homebrew/opt/postgresql@17/bin}"
if [[ ! -x "$pg_bin/postgres" ]]; then
  pg_bin="$(dirname "$(command -v postgres)")"
fi
if ! "$pg_bin/postgres" --version | rg -q 'PostgreSQL\) 17\.'; then
  echo "PostgreSQL 17 is required; set LIBFX_POSTGRES_BIN_DIR to its bin directory" >&2
  exit 1
fi
task_tmp="$(mktemp -d "${TMPDIR:-/tmp}/libfx-postgres.XXXXXX")"
report_dir="${LIBFX_POSTGRES_REPORT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/libfx-postgres-report.XXXXXX")}"
mkdir -p "$report_dir" "$task_tmp/socket"
cleanup() {
  task_status=$?
  trap - EXIT INT TERM HUP
  if [[ -f "$task_tmp/data/postmaster.pid" ]]; then
    "$pg_bin/pg_ctl" -D "$task_tmp/data" -m immediate -w stop >> "$report_dir/cluster-stop.log" 2>&1 || true
  fi
  rm -rf "$task_tmp"
  exit "$task_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
"$pg_bin/initdb" -D "$task_tmp/data" -U libfx_test -A trust --no-locale -E UTF8 > "$report_dir/initdb.log" 2>&1
started=0
for attempt in 1 2 3; do
  task_port="$(python3 - <<'PY'
import socket
with socket.socket() as server:
    server.bind(('127.0.0.1', 0))
    print(server.getsockname()[1])
PY
)"
  if "$pg_bin/pg_ctl" -D "$task_tmp/data" -l "$report_dir/postgres.log" -w -t 15 \
    -o "-h 127.0.0.1 -p $task_port -k $task_tmp/socket -c max_connections=40 -c shared_buffers=16MB" \
    start >> "$report_dir/cluster-start.log" 2>&1; then
    started=1
    break
  fi
done
[[ "$started" == 1 ]]
export PGHOST=127.0.0.1 PGPORT="$task_port" PGUSER=libfx_test PGDATABASE=libfx_test
printf 'host=%s\nport=%s\ndata=%s\n' "$PGHOST" "$PGPORT" "$task_tmp/data" > "$report_dir/cluster.txt"
"$pg_bin/createdb" libfx_test
"$pg_bin/psql" -X -A -t -c 'SHOW server_version_num' > "$report_dir/server-version.txt"
export LIBFX_POSTGRES_TEST_HOST=127.0.0.1
export LIBFX_POSTGRES_TEST_PORT="$task_port"
export LIBFX_POSTGRES_TEST_USER=libfx_test
export LIBFX_POSTGRES_TEST_DATABASE=libfx_test
export LIBFX_POSTGRES_TEST_URL="postgres://libfx_test@127.0.0.1:$task_port/libfx_test?sslmode=disable"
scratch="${LIBFX_POSTGRES_SCRATCH:-$task_tmp/build}"
set +e
swift test --package-path swift --scratch-path "$scratch" --no-parallel \
  --filter "${LIBFX_POSTGRES_TEST_FILTER:-Postgres}" "$@" \
  > "$report_dir/tests.stdout" 2> "$report_dir/tests.stderr"
test_status=$?
set -e
if [[ "$test_status" == 0 ]] && ! rg -q 'Test run with [1-9][0-9]* tests? .*passed' "$report_dir/tests.stdout" "$report_dir/tests.stderr"; then
  echo 'Postgres integration selected no passing tests' >> "$report_dir/tests.stderr"
  test_status=1
fi
printf '%s\n' "$test_status" > "$report_dir/tests.exit"
cat "$report_dir/tests.stdout"
cat "$report_dir/tests.stderr" >&2
printf 'Postgres integration report: %s\n' "$report_dir"
exit "$test_status"
