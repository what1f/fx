#import <Foundation/Foundation.h>
#include "fx.h"
#include <assert.h>
#include <poll.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

static NSData *json(id value) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:&error];
    assert(data && !error);
    return data;
}

static id decode(NSData *data) {
    NSError *error = nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    assert(value && !error);
    return value;
}

static FxCore *create(NSString *url, BOOL valid, NSString *home, NSString *workspace) {
    NSData *options = json(@{@"apiKey": @"test-only", @"home": home, @"workspaceRoot": workspace,
                             @"model": @"native/test-model", @"gatewayChatUrl": url});
    FxBuffer error = {0};
    FxCore *core = fx_core_create(options.bytes, options.length, &error);
    assert(valid ? (core && !error.len) : (!core && error.len));
    fx_buffer_free(error);
    return core;
}

static void send(FxCore *core, NSNumber *identifier, NSString *method, NSDictionary *params) {
    NSMutableDictionary *message = [@{@"jsonrpc": @"2.0", @"method": method, @"params": params} mutableCopy];
    if (identifier) message[@"id"] = identifier;
    NSMutableData *data = [json(message) mutableCopy];
    [data appendBytes:"\n" length:1];
    assert(fx_core_write(core, data.bytes, data.length) == 0);
}

static void waitReady(FxCore *core) {
    struct pollfd fd = {.fd = fx_core_ready_fd(core), .events = POLLIN};
    assert(poll(&fd, 1, 10) >= 0);
    uint8_t wakes[256];
    while (read(fd.fd, wakes, sizeof(wakes)) > 0) {}
}

static NSDictionary *response(FxCore *core, NSMutableData *pending, NSNumber *identifier) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (deadline.timeIntervalSinceNow > 0) {
        FxBuffer output = {0};
        assert(fx_core_drain(core, &output) == 0);
        if (output.len) [pending appendBytes:output.data length:output.len];
        fx_buffer_free(output);
        while (true) {
            NSRange newline = [pending rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                           options:0 range:NSMakeRange(0, pending.length)];
            if (newline.location == NSNotFound) break;
            NSData *line = [pending subdataWithRange:NSMakeRange(0, newline.location)];
            [pending replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
            if (!line.length) continue;
            NSDictionary *message = decode(line);
            if ([message[@"id"] isEqual:identifier]) return message;
        }
        waitReady(core);
    }
    assert(!"RPC response timed out");
    return nil;
}

static NSDictionary *fetch(FxCore *core, NSData **body) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (deadline.timeIntervalSinceNow > 0) {
        FxBuffer metadata = {0}, raw = {0};
        int result = fx_core_take_fetch(core, &metadata, &raw);
        assert(result >= 0);
        if (result == 1) {
            NSDictionary *request = decode([NSData dataWithBytes:metadata.data length:metadata.len]);
            *body = [NSData dataWithBytes:raw.data length:raw.len];
            fx_buffer_free(metadata); fx_buffer_free(raw);
            assert(!request[@"body"]);
            return request;
        }
        waitReady(core);
    }
    assert(!"Fetch publication timed out");
    return nil;
}

static void finish(FxCore *core, int32_t handle, NSData *data) {
    assert(fx_core_start_fetch(core, handle, 200) == 1);
    assert(fx_core_push_fetch(core, handle, data.bytes, data.length) == 1);
    assert(fx_core_finish_fetch(core, handle) == 1);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL environmentGrowth = argc == 4 && strcmp(argv[1], "--environment-growth") == 0;
        assert(argc == 1 || environmentGrowth);
        long names = 0;
        NSString *home = @"/tmp", *workspace = @"/tmp";
        if (environmentGrowth) {
            char *end = NULL;
            names = strtol(argv[2], &end, 10);
            assert(end && *end == '\0' && (names == 0 || names == 10 || names == 200));
            // Force libc's environment onto the heap before the first runtime.
            assert(setenv("LIBFX_ENV_GROWTH_BEFORE", "1", 1) == 0);
            NSString *root = [NSString stringWithUTF8String:argv[3]];
            home = [root stringByAppendingPathComponent:@"home"];
            workspace = [root stringByAppendingPathComponent:@"workspace"];
            assert([NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:NULL]);
            assert([NSFileManager.defaultManager createDirectoryAtPath:workspace withIntermediateDirectories:YES attributes:nil error:NULL]);
        }
        if (!environmentGrowth) {
            for (NSString *url in @[@"http://attacker.example/chat", @"https://user:pass@example.com/chat",
                                    @"https://example.com/chat"]) create(url, NO, home, workspace);
        }
        FxCore *core = create(@"http://127.0.0.1:31337/chat", YES, home, workspace);
        // Grow only after the initial core exists. Subsequent native lookups must
        // not retain the environment array that libc can relocate here.
        for (long index = 0; index < names; index++) {
            NSString *name = [NSString stringWithFormat:@"LIBFX_ENV_GROWTH_%ld", index];
            assert(getenv(name.UTF8String) == NULL);
            assert(setenv(name.UTF8String, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", 1) == 0);
        }
        NSMutableData *pending = [NSMutableData data];
        send(core, @1, @"initialize", @{@"protocolVersion": @1, @"clientCapabilities": @{}});
        assert(response(core, pending, @1)[@"result"]);
        send(core, @2, @"session/new", @{});
        NSString *session = response(core, pending, @2)[@"result"][@"sessionId"];
        assert(session);
        NSData *body = nil;
        int32_t previous = 0;
        NSData *wire = [@"data: {\"type\":\"text-delta\",\"delta\":\"ok\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n" dataUsingEncoding:NSUTF8StringEncoding];
        for (int index = 0; index < (environmentGrowth ? 3 : 2); index++) {
            NSNumber *identifier = @(3 + index);
            send(core, identifier, @"session/prompt", @{@"sessionId": session,
                 @"prompt": @[@{@"type": @"text", @"text": @"test fetch identity"}]});
            NSDictionary *request = fetch(core, &body);
            if (index == 0) {
                assert([request[@"method"] isEqual:@"GET"] && body.length == 0);
                assert([request[@"url"] isEqual:@"https://ai-gateway.vercel.sh/coding-agent/v1/models"]);
                finish(core, [request[@"handle"] intValue], json(@{@"object": @"list",
                    @"data": @[@{@"id": @"native/test-model", @"type": @"language"}]}));
                request = fetch(core, &body);
            }
            assert([request[@"method"] isEqual:@"POST"]);
            assert([request[@"url"] isEqual:@"http://127.0.0.1:31337/chat"]);
            assert([decode(body)[@"prompt"] isKindOfClass:NSArray.class]);
            int32_t handle = [request[@"handle"] intValue];
            assert(handle > 0 && handle != previous);
            assert(fx_core_fetch_disposition(core, handle) == 1);
            assert(fx_core_fetch_disposition(core, handle + 1) == 0);
            assert(fx_core_fetch_disposition(core, INT32_MAX) == 0);
            int32_t stale = previous ? previous : handle + 1;
            assert(fx_core_start_fetch(core, stale, 200) == 0);
            assert(fx_core_push_fetch(core, stale, (const uint8_t *)"stale", 5) == 0);
            assert(fx_core_finish_fetch(core, stale) == 0 && fx_core_fail_fetch(core, stale) == 0);
            assert(fx_core_fetch_disposition(core, handle) == 1);
            if (previous) assert(fx_core_fetch_disposition(core, previous) == 2);
            assert(fx_core_start_fetch(core, handle, 200) == 1);
            NSMutableData *large = [NSMutableData dataWithLength:8 * 1024 * 1024 + 1];
            assert(fx_core_push_fetch(core, handle, large.bytes, large.length) == 2);
            assert(fx_core_push_fetch(core, handle, wire.bytes, wire.length) == 1);
            assert(fx_core_finish_fetch(core, handle) == 1);
            assert([response(core, pending, identifier)[@"result"][@"stopReason"] isEqual:@"end_turn"]);
            assert(fx_core_fetch_disposition(core, handle) == 2);
            if (previous) assert(fx_core_fetch_disposition(core, previous) == 0);
            previous = handle;
        }
        fx_core_close(core);
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!fx_core_exited(core) && deadline.timeIntervalSinceNow > 0) waitReady(core);
        assert(fx_core_exited(core) && fx_core_exit_code(core) == 0);
        assert(fx_core_fetch_disposition(core, previous) == 2);
        fx_core_abort_fetch(core);
        assert(fx_core_fetch_disposition(core, previous) == 0);
        fx_core_destroy(core);
    }
    return 0;
}
