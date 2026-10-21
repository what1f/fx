#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
case "$(uname -m)" in
  arm64) task_target=aarch64-macos.14.0 ;;
  x86_64) task_target=x86_64-macos.14.0 ;;
  *) echo "This consumer test requires macOS arm64 or x86_64" >&2; exit 1 ;;
esac
if [[ "${LIBFX_SKIP_BUILD:-0}" != 1 ]]; then
  zig build libfx-c -Dtarget="$task_target"
fi
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
cat > "$task_tmp/smoke.c" <<'C_SOURCE'
#include "fx.h"
#include <assert.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static void exchange(FxCore *core, const char *line, const char *expected) {
  assert(fx_core_write(core,(const uint8_t *)line,strlen(line))==0);
  struct pollfd fd={.fd=fx_core_ready_fd(core),.events=POLLIN};
  char result[8192]={0}; size_t total=0;
  for(int i=0;i<40 && !strstr(result,expected);i++) {
    poll(&fd,1,100);
    unsigned char wake[256]; while(read(fd.fd,wake,sizeof(wake))>0){}
    FxBuffer b={0}; assert(fx_core_drain(core,&b)==0);
    assert(total+b.len<sizeof(result)); if(b.len)memcpy(result+total,b.data,b.len);
    total+=b.len; fx_buffer_free(b);
  }
  assert(strstr(result,expected));
}
int main(void) {
  FxBuffer error={0};
  const char *options="{\"apiKey\":\"test-only\",\"home\":\"/tmp/libfx-c-smoke\",\"workspaceRoot\":\"/tmp\"}";
  assert(fx_core_abi_version()==1);
  for(int i=0;i<12;i++){
    FxCore *core=fx_core_create((const uint8_t *)options,strlen(options),&error);
    assert(core); assert(!error.len);
    assert(fx_core_write(core,NULL,1)==-1);
    assert(fx_core_write(core,NULL,0)==0);
    assert(fx_core_write_attachment(core,0,NULL,0)==-1);
    assert(fx_core_write_attachment(core,1,NULL,0)==0);
    assert(fx_core_write_attachment(core,1,NULL,0)==-1);
    fx_core_discard_attachments(core);
    FxBuffer absent={0}; assert(fx_core_take_attachment(core,1,&absent)==0);
    assert(fx_core_fetch_disposition(core,999)==0);
    assert(fx_core_start_fetch(core,999,200)==0);
    assert(fx_core_push_fetch(core,999,NULL,1)==-1);
    assert(fx_core_push_fetch(core,999,NULL,0)==0);
    assert(fx_core_finish_fetch(core,999)==0);
    assert(fx_core_fail_fetch(core,999)==0);
    fx_core_abort_fetch(core); fx_core_abort_fetch(core);
    exchange(core,"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{}}}\n","\"id\":1");
    exchange(core,"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"libfx/new\",\"params\":{}}\n","sessionId");
    fx_core_close(core); fx_core_close(core);
    assert(fx_core_write(core,NULL,0)==-1);
    fx_core_destroy(core);
  }
  for(int i=0;i<80;i++) {
    FxCore *bad=fx_core_create((const uint8_t *)"{}",2,&error);
    assert(!bad && error.len);fx_buffer_free(error);
  }
  FxCore *last=fx_core_create((const uint8_t *)options,strlen(options),&error);
  assert(last); fx_core_destroy(last);
  FxCore *bad=fx_core_create(NULL,1,&error);
  assert(!bad && error.len);fx_buffer_free(error);
  fx_buffer_free((FxBuffer){0});
  puts("C ABI smoke passed: initialize, session creation, repeated teardown, invalid options");
}
C_SOURCE
cc -mmacosx-version-min=14.0 -I swift/Sources/CFx/include   "$task_tmp/smoke.c" zig-out/lib/libfx_core.a -o "$task_tmp/smoke"
"$task_tmp/smoke"
