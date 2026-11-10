#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
task_arch="${LIBFX_C_ARCH:-$(uname -m)}"
task_archive="${LIBFX_C_ARCHIVE:-swift/Artifacts/CFx.xcframework/macos-arm64_x86_64/libfx_core.a}"
case "$task_arch" in
  arm64|x86_64) ;;
  *) echo "This consumer requires macOS arm64 or x86_64" >&2; exit 1 ;;
esac
task_tmp="$(mktemp -d /tmp/libfx-c-security.XXXXXX)"
trap 'rm -rf "$task_tmp"' EXIT
mkdir "$task_tmp/home" "$task_tmp/workspace"
cat > "$task_tmp/security.c" <<'C'
#include "fx.h"
#include <assert.h>
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static char options[4096];

static FxCore *create(void) {
    FxBuffer error = {0};
    FxCore *core = fx_core_create((const uint8_t *)options, strlen(options), &error);
    assert(core && error.len == 0);
    fx_buffer_free(error);
    return core;
}

static double now(void) {
    struct timespec value;
    assert(clock_gettime(CLOCK_MONOTONIC, &value) == 0);
    return (double)value.tv_sec + (double)value.tv_nsec / 1e9;
}

static void exchange(FxCore *core, const char *message, const char *required, const char *second) {
    assert(fx_core_write(core, (const uint8_t *)message, strlen(message)) == 0);
    struct pollfd ready = {.fd = fx_core_ready_fd(core), .events = POLLIN};
    char output[65536] = {0};
    size_t count = 0;
    double deadline = now() + 5;
    while (now() < deadline) {
        int status = poll(&ready, 1, 100);
        assert(status >= 0 || errno == EINTR);
        uint8_t wakes[256];
        while (read(ready.fd, wakes, sizeof(wakes)) > 0) {}
        for (;;) {
            FxBuffer buffer = {0};
            assert(fx_core_drain(core, &buffer) == 0);
            if (buffer.len == 0) {
                fx_buffer_free(buffer);
                break;
            }
            assert(buffer.len < sizeof(output) - count);
            memcpy(output + count, buffer.data, buffer.len);
            count += buffer.len;
            output[count] = 0;
            fx_buffer_free(buffer);
        }
        if (strstr(output, required) && (!second || strstr(output, second))) return;
    }
    assert(!"Timed out waiting for security response");
}

int main(int argc, char **argv) {
    alarm(45);
    assert(argc == 2);
    int length = snprintf(options, sizeof(options),
        "{\"apiKey\":\"security-test-key\",\"home\":\"%s/home\",\"workspaceRoot\":\"%s/workspace\"}", argv[1], argv[1]);
    assert(length > 0 && (size_t)length < sizeof(options));
    assert(fx_core_abi_version() == 1);
    FxCore *cores[64];
    for (size_t index = 0; index < 64; index++) cores[index] = create();
    FxBuffer error = {0};
    FxCore *overflow = fx_core_create((const uint8_t *)options, strlen(options), &error);
    assert(!overflow && error.len == strlen("TooManyRuntimes"));
    assert(memcmp(error.data, "TooManyRuntimes", error.len) == 0);
    fx_buffer_free(error);
    fx_core_close(cores[0]);
    fx_core_destroy(cores[0]);
    cores[0] = create();
    for (size_t index = 0; index < 64; index++) fx_core_close(cores[index]);
    for (size_t index = 0; index < 64; index++) fx_core_destroy(cores[index]);

    FxCore *core = create();
    exchange(core,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{}}}\n",
        "\"id\":1", "\"result\"");
    char request[8192];
    length = snprintf(request, sizeof(request),
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\",\"params\":{\"cwd\":\"%s/workspace\",\"mcpServers\":[{\"name\":\"blocked\",\"command\":\"/bin/sh\",\"args\":[\"-c\",\"exit 0\"],\"env\":[]}]}}\n", argv[1]);
    assert(length > 0 && (size_t)length < sizeof(request));
    exchange(core, request, "\"code\":-32602", "MCP servers are unavailable");
    length = snprintf(request, sizeof(request),
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/new\",\"params\":{\"cwd\":\"%s/workspace\",\"mcpServers\":[]}}\n", argv[1]);
    assert(length > 0 && (size_t)length < sizeof(request));
    exchange(core, request, "\"id\":3", "\"sessionId\"");
    fx_core_close(core);
    double deadline = now() + 5;
    while (!fx_core_exited(core) && now() < deadline) usleep(1000);
    assert(fx_core_exited(core) && fx_core_exit_code(core) == 0);
    fx_core_destroy(core);
    puts("C ABI security passed: 64 live runtimes, overflow refusal, slot reuse, raw MCP refusal and session recovery");
    return 0;
}
C
clang -arch "$task_arch" -mmacosx-version-min=14.0 -Wall -Wextra -Werror \
  -I swift/Sources/CFx/include "$task_tmp/security.c" "$task_archive" -o "$task_tmp/security"
set +e
if [[ "$task_arch" == x86_64 && "$(uname -m)" == arm64 ]]; then
  arch -x86_64 "$task_tmp/security" "$task_tmp" > "$task_tmp/stdout" 2> "$task_tmp/stderr"
else
  "$task_tmp/security" "$task_tmp" > "$task_tmp/stdout" 2> "$task_tmp/stderr"
fi
task_status=$?
set -e
cat "$task_tmp/stdout"
if [[ -s "$task_tmp/stderr" ]]; then cat "$task_tmp/stderr" >&2; exit 1; fi
if [[ "$task_status" != 0 ]]; then exit "$task_status"; fi
rg -q '^C ABI security passed:' "$task_tmp/stdout"
