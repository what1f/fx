#ifndef LIBFX_CORE_H
#define LIBFX_CORE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Calls on a core must be serialized by its owner. Destroy only after all host
   operations have stopped. Returned buffers are owned by the caller and must
   be released with fx_buffer_free, including error buffers. Input is copied.
   A ready FD is borrowed; do not close it. Drain its wake bytes before polling
   output/fetch queues. Wake bytes have no payload. */
typedef struct FxCore FxCore;
typedef struct { uint8_t *data; size_t len; } FxBuffer;
/* JSON fields match native libfx: apiKey, provider, configuredProviders, model,
   effort, fast, ultrafast, home, workspaceRoot, gatewayChatUrl.
   home and workspaceRoot must be absolute filesystem paths. */
uint32_t fx_core_abi_version(void);
FxCore *fx_core_create(const uint8_t *, size_t, FxBuffer *error);
void fx_buffer_free(FxBuffer);
int32_t fx_core_ready_fd(FxCore *);
int32_t fx_core_write(FxCore *, const uint8_t *, size_t);
int32_t fx_core_drain(FxCore *, FxBuffer *);
/* take_fetch: 1=request, 0=none, -1=allocation failure. Metadata contains handle,
   method, url, and headers; request body is raw. */
int32_t fx_core_take_fetch(FxCore *, FxBuffer *metadata, FxBuffer *body);
/* Fetch operations: 0=stale, 1=applied, 2=backpressure, -1=allocation failure. */
int32_t fx_core_start_fetch(FxCore *, int32_t handle, uint16_t status);
int32_t fx_core_push_fetch(FxCore *, int32_t handle, const uint8_t *, size_t);
int32_t fx_core_finish_fetch(FxCore *, int32_t handle);
int32_t fx_core_fail_fetch(FxCore *, int32_t handle);
/* disposition: 0=retired, 1=active, 2=consumed. */
int32_t fx_core_fetch_disposition(FxCore *, int32_t handle);
int32_t fx_core_write_attachment(FxCore *, uint32_t id, const uint8_t *, size_t);
int32_t fx_core_take_attachment(FxCore *, uint32_t id, FxBuffer *);
void fx_core_discard_attachments(FxCore *);
void fx_core_abort_fetch(FxCore *);
void fx_core_close(FxCore *);
int32_t fx_core_exited(FxCore *);
int32_t fx_core_exit_code(FxCore *);
void fx_core_destroy(FxCore *);
#ifdef __cplusplus
}
#endif
#endif
