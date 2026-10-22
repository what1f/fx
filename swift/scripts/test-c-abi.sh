#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
task_arch="${LIBFX_C_ARCH:-$(uname -m)}"
task_archive="${LIBFX_C_ARCHIVE:-zig-out/lib/libfx_core.a}"
case "$task_arch" in
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
#include <dirent.h>
#include <errno.h>
#include <stdlib.h>
#include <time.h>
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
static const char *test_options="{\"apiKey\":\"test-only\",\"home\":\"/tmp\",\"workspaceRoot\":\"/tmp\"}";
static double now(void) {
  struct timespec t; assert(clock_gettime(CLOCK_MONOTONIC,&t)==0);
  return (double)t.tv_sec+(double)t.tv_nsec/1e9;
}
static FxCore *new_core(void) {
  FxBuffer error={0};
  FxCore *core=fx_core_create((const uint8_t *)test_options,strlen(test_options),&error);
  assert(core && !error.len); fx_buffer_free(error); return core;
}
static void wake_and_drain(FxCore *core,FxBuffer *out) {
  int fd=fx_core_ready_fd(core); assert(fd>=0);
  struct pollfd ready={.fd=fd,.events=POLLIN};
  int result=poll(&ready,1,20); assert(result>=0 || errno==EINTR);
  unsigned char bytes[256]; while(read(fd,bytes,sizeof(bytes))>0){}
  assert(fx_core_drain(core,out)==0);
}
static void normal_exit(FxCore *core) {
  fx_core_close(core);
  double deadline=now()+5;
  while(!fx_core_exited(core) && now()<deadline) {
    FxBuffer out={0}; wake_and_drain(core,&out); fx_buffer_free(out);
  }
  assert(fx_core_exited(core) && fx_core_exit_code(core)==0);
}
static int fd_count(void) {
  DIR *directory=opendir("/dev/fd"); assert(directory);
  int count=0; struct dirent *entry;
  while((entry=readdir(directory))) if(strcmp(entry->d_name,".") && strcmp(entry->d_name,".."))count++;
  assert(closedir(directory)==0); return count;
}
static void relative_paths(void) {
  for(int field=0;field<2;field++) for(int long_path=0;long_path<2;long_path++) {
    size_t size=long_path ? 16u*1024 : 8;
    char *path=malloc(size+1),*options=malloc(size+256); assert(path && options);
    memset(path,'x',size); path[size]=0;
    snprintf(options,size+256,"{\"apiKey\":\"x\",\"home\":\"%s\",\"workspaceRoot\":\"%s\"}",field==0 ? path : "/tmp",field==1 ? path : "/tmp");
    FxBuffer error={0}; FxCore *core=fx_core_create((uint8_t *)options,strlen(options),&error);
    assert(!core && error.len==strlen("InvalidPath") && !memcmp(error.data,"InvalidPath",error.len));
    fx_buffer_free(error); free(options); free(path);
  }
  puts("C ABI path admission passed: relative home/workspace rejected before starting a runtime");
}
static void bounds(void) {
  FxCore *core=new_core();
  size_t maximum=8u*1024*1024;
  uint8_t *bytes=malloc(maximum+1); assert(bytes); memset(bytes,' ',maximum+1);
  assert(fx_core_write(core,bytes,maximum+1)==-1);
  assert(fx_core_write(core,bytes,maximum)==0);
  fx_core_destroy(core);
  core=new_core();
  assert(fx_core_write_attachment(core,1,bytes,4u*1024*1024+1)==-1);
  assert(fx_core_write_attachment(core,1,bytes,4u*1024*1024)==0);
  assert(fx_core_write_attachment(core,1,bytes,1)==-1);
  assert(fx_core_write_attachment(core,2,bytes,4u*1024*1024)==0);
  assert(fx_core_write_attachment(core,3,bytes,1)==-1);
  fx_core_discard_attachments(core);
  for(uint32_t id=1;id<=8;id++)assert(fx_core_write_attachment(core,id,bytes,1)==0);
  assert(fx_core_write_attachment(core,9,bytes,1)==-1);
  fx_core_discard_attachments(core);
  assert(fx_core_write_attachment(core,UINT32_MAX,bytes,1)==0);
  FxBuffer absent={0}; assert(fx_core_take_attachment(core,UINT32_MAX,&absent)==0);
  assert(absent.data==NULL && absent.len==0); fx_buffer_free(absent);
  fx_core_discard_attachments(core); normal_exit(core); fx_core_destroy(core); free(bytes);
  const size_t limits[]={64u*1024,1024,16u*1024};
  for(size_t field=0;field<3;field++) for(size_t extra=0;extra<2;extra++) {
    // A 16KiB path cannot name a usable macOS directory. Only its option
    // rejection boundary is portable; valid paths are exercised above.
    if(field==2 && extra==0)continue;
    size_t size=limits[field]+extra;
    char *value=malloc(size+1),*json=malloc(size+256); assert(value && json);
    memset(value,'x',size); value[size]=0;
    if(field==0)snprintf(json,size+256,"{\"apiKey\":\"%s\",\"home\":\"/tmp\",\"workspaceRoot\":\"/tmp\"}",value);
    if(field==1)snprintf(json,size+256,"{\"apiKey\":\"x\",\"model\":\"%s\",\"home\":\"/tmp\",\"workspaceRoot\":\"/tmp\"}",value);
    if(field==2)snprintf(json,size+256,"{\"apiKey\":\"x\",\"home\":\"%s\",\"workspaceRoot\":\"/tmp\"}",value);
    FxBuffer error={0}; core=fx_core_create((const uint8_t *)json,strlen(json),&error);
    if(extra)assert(!core && error.len); else {assert(core && !error.len);fx_core_destroy(core);}
    fx_buffer_free(error); free(value); free(json);
  }
  size_t option_limit=2u*1024*1024;
  uint8_t *options=malloc(option_limit+1); assert(options);
  memset(options,' ',option_limit+1); memcpy(options,test_options,strlen(test_options));
  FxBuffer error={0}; core=fx_core_create(options,option_limit,&error);
  assert(core && !error.len); fx_core_destroy(core); fx_buffer_free(error);
  core=fx_core_create(options,option_limit+1,&error);
  assert(!core && error.len); fx_buffer_free(error); free(options);
  puts("C ABI bounds passed: exact input/options/field/attachment limits and slot recovery");
}
static void ready_bursts(void) {
  FxCore *core=new_core();
  exchange(core,"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{}}}\n","\"id\":1");
  for(int batch=0;batch<20;batch++) {
    char input[8192],output[65536]; size_t used=0,total=0; output[0]=0;
    for(int index=0;index<50;index++) {
      int written=snprintf(input+used,sizeof(input)-used,"{\"jsonrpc\":\"2.0\",\"id\":%d,\"method\":\"unknown-readiness-method\"}\n",2+batch*50+index);
      assert(written>0 && (size_t)written<sizeof(input)-used); used+=(size_t)written;
    }
    assert(fx_core_write(core,(uint8_t *)input,used)==0);
    double deadline=now()+5; int received=0;
    while(received<50 && now()<deadline) {
      struct pollfd ready={.fd=fx_core_ready_fd(core),.events=POLLIN};
      int notified=poll(&ready,1,5000);
      assert(notified==1 && (ready.revents&(POLLIN|POLLHUP)));
      unsigned char wakes[256]; while(read(ready.fd,wakes,sizeof(wakes))>0){}
      // Readiness is edge-triggered. Drain all queued bytes before waiting
      // again, including bytes appended after drain sampled its allocation.
      for(;;) {
        FxBuffer out={0}; assert(fx_core_drain(core,&out)==0);
        if(!out.len) { fx_buffer_free(out); break; }
        assert(total+out.len<sizeof(output));
        memcpy(output+total,out.data,out.len); total+=out.len;output[total]=0;fx_buffer_free(out);
        char *line=output,*end;
        while((end=strchr(line,'\n'))) {
          *end=0; char *id=strstr(line,"\"id\":"); assert(id);
          assert(strtol(id+5,NULL,10)==2+batch*50+received);
          assert(strstr(line,"\"code\":-32601")); received++; line=end+1;
        }
        size_t pending=total-(size_t)(line-output); memmove(output,line,pending); total=pending; output[total]=0;
      }
    }
    assert(received==50 && total==0);
  }
  normal_exit(core); fx_core_destroy(core);
  puts("C ABI readiness passed: 20 coalescing bursts, 1000 exact ordered replies, graceful exit");
}
static void output_pressure(void) {
  const size_t count=180000, length=count*3;
  uint8_t *input=malloc(length); assert(input);
  for(size_t index=0;index<count;index++)memcpy(input+index*3,"{}\n",3);
  FxCore *core=new_core(); assert(fx_core_write(core,input,length)==0);
  // Match the original exit-code owner's unread interval before draining.
  assert(poll(NULL,0,5000)==0); assert(!fx_core_exited(core));
  size_t received=0,output_bytes=0,pending=0; char line[4096]; double deadline=now()+20;
  while(received<count && now()<deadline) {
    FxBuffer out={0}; wake_and_drain(core,&out); output_bytes+=out.len;
    for(size_t index=0;index<out.len;index++) {
      assert(pending+1<sizeof(line)); line[pending++]=(char)out.data[index];
      if(out.data[index]=='\n') {
        line[pending]=0; assert(strstr(line,"\"code\":-32600")); received++; pending=0;
      }
    }
    fx_buffer_free(out);
  }
  assert(received==count && pending==0 && output_bytes>8u*1024*1024);
  normal_exit(core); fx_core_destroy(core);
  core=new_core(); assert(fx_core_write(core,input,length)==0);
  usleep(100000); assert(!fx_core_exited(core));
  double before=now(); fx_core_destroy(core); assert(now()-before<5);
  free(input);
  puts("C ABI output passed: 180000 lossless replies above queue capacity and blocked-output destroy");
}
// Opt-in regression for an accepted but unusable filesystem path. Failure
// must reach the caller through create/exit status, never abort the host.
static void long_home_probe(void) {
  const size_t size=16u*1024;
  char *home=malloc(size+1),*options=malloc(size+256); assert(home && options);
  memset(home,'x',size); home[size]=0;
  snprintf(options,size+256,"{\"apiKey\":\"x\",\"home\":\"%s\",\"workspaceRoot\":\"/tmp\"}",home);
  FxBuffer error={0}; FxCore *core=fx_core_create((uint8_t *)options,strlen(options),&error);
  free(options); free(home);
  if(!core) { assert(error.len); fx_buffer_free(error); return; }
  assert(!error.len); fx_buffer_free(error);
  double deadline=now()+5;
  while(!fx_core_exited(core) && now()<deadline) {
    FxBuffer out={0}; wake_and_drain(core,&out); fx_buffer_free(out);
  }
  assert(fx_core_exited(core) && fx_core_exit_code(core)!=0);
  fx_core_destroy(core);
}
int main(void) {
  setvbuf(stdout,NULL,_IONBF,0);
  alarm(90);
  const char *probe=getenv("LIBFX_C_LONG_HOME_PROBE");
  if(probe && !strcmp(probe,"1")) { long_home_probe(); return 0; }
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
  relative_paths(); bounds(); ready_bursts(); output_pressure();
  int descriptors=fd_count();
  for(int index=0;index<32;index++) {
    FxCore *repeated=new_core(); assert(fx_core_ready_fd(repeated)>=0);
    fx_core_close(repeated); fx_core_destroy(repeated);
  }
  assert(fd_count()==descriptors);
  puts("C ABI descriptor cleanup passed: 32 repeated handles with borrowed readers");
  puts("C ABI smoke passed: initialize, session creation, repeated teardown, invalid options");
}
C_SOURCE
cc -arch "$task_arch" -mmacosx-version-min=14.0 -Wall -Wextra -Werror -I swift/Sources/CFx/include \
  "$task_tmp/smoke.c" "$task_archive" -o "$task_tmp/smoke"
/usr/bin/arch -"$task_arch" "$task_tmp/smoke"
