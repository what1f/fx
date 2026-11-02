const std = @import("std");
const build_options = @import("build_options");
const jsonrpc = @import("acp/jsonrpc.zig");
const gateway_provider = @import("core/gateway/gateway_provider.zig");
const provider_set = @import("core/gateway/provider_set.zig");
const stream_provider = @import("core/agent/stream_provider.zig");
const agent_steps = @import("core/config/agent_steps.zig");
const context_contract = @import("core/workspace/context_contract.zig");
const host = @import("core/hosts/host.zig");
const host_attachments = @import("core/hosts/host_attachments.zig");
const io_mod = @import("core/shared/io.zig");
const fetch_state = @import("napi_fetch_state.zig");
const streamable_http = @import("core/mcp/streamable_http.zig");
const host_stream_provider = @import("gateway/host_stream_provider.zig");
const host_openai_codex = @import("gateway/host_openai_codex.zig");
const host_xai_grok = @import("gateway/host_xai_grok.zig");
const host_chat_completions = @import("gateway/host_chat_completions.zig");
const configured_provider = @import("core/config/configured_provider.zig");
const provider_catalog = @import("core/auth/provider_catalog.zig");
const model_provider = @import("core/config/model_provider.zig");
const oauth_transport = @import("core/auth/oauth_transport.zig");
const builtin_gateway = @import("builtins/gateway.zig");

const c = @import("node_api");

comptime {
    if (build_options.napi_surface != .core) {
        @compileError("libfx N-API core requires -Dnapi-surface=core");
    }
}

const native = @import("native_core_runtime.zig");
const Allocator = native.Allocator;
const Runtime = native.Runtime;
const max_drain_bytes = native.max_drain_bytes;
const max_api_key_bytes = native.max_api_key_bytes;
const max_model_bytes = native.max_model_bytes;
const max_effort_bytes = native.max_effort_bytes;
const max_path_bytes = native.max_path_bytes;
const max_url_bytes = native.max_url_bytes;
const FetchOperationResult = native.FetchOperationResult;
const claimRuntimeSlot = native.claimRuntimeSlot;
const releaseRuntimeSlot = native.releaseRuntimeSlot;
const ensureThreadedIo = native.ensureThreadedIo;
const runtime_handle_type_tag = c.napi_type_tag{
    .lower = 0x4c4942465852544d,
    .upper = 0xa71d7c52e9314b08,
};

const RuntimeHandle = struct {
    mutex: std.Io.Mutex = .init,
    runtime: ?*Runtime,
    cleanup_hook_registered: bool,

    fn unregisterCleanup(self: *RuntimeHandle, env: c.napi_env) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        const registered = self.cleanup_hook_registered;
        self.cleanup_hook_registered = false;
        self.mutex.unlock(io);
        if (registered) _ = c.napi_remove_env_cleanup_hook(env, cleanupRuntimeHandle, self);
    }

    fn destroy(self: *RuntimeHandle) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        const runtime = self.runtime;
        self.runtime = null;
        self.mutex.unlock(io);
        if (runtime) |value| value.deinit();
    }
};

fn cleanupRuntimeHandle(data: ?*anyopaque) callconv(.c) void {
    const handle: *RuntimeHandle = @ptrCast(@alignCast(data orelse return));
    const io = io_mod.getIo();
    handle.mutex.lockUncancelable(io);
    handle.cleanup_hook_registered = false;
    handle.mutex.unlock(io);
    handle.destroy();
}

fn throw(env: c.napi_env, code: [*:0]const u8, message: [*:0]const u8) c.napi_value {
    _ = c.napi_throw_error(env, code, message);
    return null;
}

fn statusOk(env: c.napi_env, status: c.napi_status, message: [*:0]const u8) bool {
    if (status == c.napi_ok) return true;
    _ = c.napi_throw_error(env, "LIBFX_NAPI", message);
    return false;
}

fn callbackArgs(env: c.napi_env, info: c.napi_callback_info, argv: []c.napi_value) bool {
    var argc = argv.len;
    if (!statusOk(env, c.napi_get_cb_info(env, info, &argc, argv.ptr, null, null), "could not read arguments")) return false;
    if (argc == argv.len) return true;
    _ = c.napi_throw_type_error(env, "LIBFX_INVALID_ARGUMENT", "missing required argument");
    return false;
}

fn stringArg(env: c.napi_env, value: c.napi_value, alloc: Allocator, max_len: usize) ![]u8 {
    var len: usize = 0;
    if (c.napi_get_value_string_utf8(env, value, null, 0, &len) != c.napi_ok) return error.InvalidArgument;
    if (len > max_len) return error.ArgumentTooLong;
    const bytes = try alloc.alloc(u8, len + 1);
    errdefer alloc.free(bytes);
    var written: usize = 0;
    if (c.napi_get_value_string_utf8(env, value, bytes.ptr, bytes.len, &written) != c.napi_ok) return error.InvalidArgument;
    return bytes[0..written];
}

fn getNamedString(
    env: c.napi_env,
    object: c.napi_value,
    name: [*:0]const u8,
    alloc: Allocator,
    max_len: usize,
) !?[]u8 {
    var present = false;
    if (c.napi_has_named_property(env, object, name, &present) != c.napi_ok) {
        if (exceptionPending(env)) return error.JavaScriptException;
        return error.InvalidArgument;
    }
    if (!present) return null;
    var value: c.napi_value = undefined;
    if (c.napi_get_named_property(env, object, name, &value) != c.napi_ok) {
        if (exceptionPending(env)) return error.JavaScriptException;
        return error.InvalidArgument;
    }
    var value_type: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, value, &value_type) != c.napi_ok or value_type != c.napi_string) return error.InvalidArgument;
    return try stringArg(env, value, alloc, max_len);
}

fn getNamedBool(
    env: c.napi_env,
    object: c.napi_value,
    name: [*:0]const u8,
) !?bool {
    var present = false;
    if (c.napi_has_named_property(env, object, name, &present) != c.napi_ok) {
        if (exceptionPending(env)) return error.JavaScriptException;
        return error.InvalidArgument;
    }
    if (!present) return null;
    var value: c.napi_value = undefined;
    if (c.napi_get_named_property(env, object, name, &value) != c.napi_ok) {
        if (exceptionPending(env)) return error.JavaScriptException;
        return error.InvalidArgument;
    }
    var value_type: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, value, &value_type) != c.napi_ok or value_type != c.napi_boolean) return error.InvalidArgument;
    var result = false;
    if (c.napi_get_value_bool(env, value, &result) != c.napi_ok) return error.InvalidArgument;
    return result;
}

fn exceptionPending(env: c.napi_env) bool {
    var pending = false;
    return c.napi_is_exception_pending(env, &pending) == c.napi_ok and pending;
}

const CreateError = error{
    JavaScriptException,
    TooManyRuntimes,
    InvalidApiKey,
    InvalidProvider,
    InvalidConfiguredProvider,
    InvalidModel,
    InvalidEffort,
    InvalidFast,
    InvalidUltrafast,
    InvalidHome,
    InvalidWorkspaceRoot,
    InvalidGatewayUrl,
    OutOfMemory,
    ThreadFailed,
    ReadyChannelFailed,
};

const max_provider_bytes = configured_provider.max_id_bytes;
const max_configured_providers_bytes = 1024 * 1024;

/// Reads the optional `provider` option: "gateway", "codex", "grok", or the name
/// of the provider that the `configuredProviders` option defines.
fn getProvider(env: c.napi_env, options: c.napi_value) CreateError!?model_provider.ProviderId {
    const alloc = std.heap.c_allocator;
    const raw = (getNamedString(env, options, "provider", alloc, max_provider_bytes) catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProvider,
    }) orelse return null;
    defer alloc.free(raw);
    if (std.mem.eql(u8, raw, "gateway")) return .gateway;
    if (std.mem.eql(u8, raw, "codex")) return .codex;
    if (std.mem.eql(u8, raw, "grok")) return .grok;
    const configured = model_provider.parse(raw) orelse return error.InvalidProvider;
    if (configured != .configured) return error.InvalidProvider;
    return configured;
}

fn createRuntime(env: c.napi_env, options: c.napi_value) CreateError!*Runtime {
    if (!claimRuntimeSlot()) return error.TooManyRuntimes;
    errdefer releaseRuntimeSlot();
    const alloc = std.heap.c_allocator;
    const provider = try getProvider(env, options);
    const configured_providers = getNamedString(env, options, "configuredProviders", alloc, max_configured_providers_bytes) catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConfiguredProvider,
    };
    errdefer if (configured_providers) |json| alloc.free(json);
    const configured = if (provider) |value| value == .configured else false;
    if (configured != (configured_providers != null)) return error.InvalidConfiguredProvider;
    const api_key = getNamedString(env, options, "apiKey", alloc, max_api_key_bytes) catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidApiKey,
    };
    errdefer if (api_key) |value| alloc.free(value);
    // The host authorizes every provider but Gateway, which needs its API key.
    const host_authorized = if (provider) |value| value != .gateway else false;
    if (api_key == null and !host_authorized) return error.InvalidApiKey;
    const model = getNamedString(env, options, "model", alloc, max_model_bytes) catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModel,
    };
    errdefer if (model) |value| alloc.free(value);
    const effort = getNamedString(env, options, "effort", alloc, max_effort_bytes) catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEffort,
    };
    errdefer if (effort) |value| alloc.free(value);
    const fast = getNamedBool(env, options, "fast") catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        else => return error.InvalidFast,
    };
    const ultrafast = getNamedBool(env, options, "ultrafast") catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        else => return error.InvalidUltrafast,
    };
    const home = (getNamedString(env, options, "home", alloc, max_path_bytes) catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidHome,
    }) orelse return error.InvalidHome;
    errdefer alloc.free(home);
    const workspace_root = (getNamedString(env, options, "workspaceRoot", alloc, max_path_bytes) catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidWorkspaceRoot,
    }) orelse return error.InvalidWorkspaceRoot;
    errdefer alloc.free(workspace_root);
    const gateway_chat_url = (getNamedString(env, options, "gatewayChatUrl", alloc, max_url_bytes) catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidGatewayUrl,
    }) orelse (alloc.dupe(u8, builtin_gateway.default_chat_url) catch return error.OutOfMemory);
    errdefer alloc.free(gateway_chat_url);
    streamable_http.validateEndpoint(gateway_chat_url) catch return error.InvalidGatewayUrl;
    if (!std.mem.eql(u8, gateway_chat_url, builtin_gateway.default_chat_url)) {
        const uri = std.Uri.parse(gateway_chat_url) catch return error.InvalidGatewayUrl;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InvalidGatewayUrl;
    }

    return native.createOwned(alloc, .{
        .api_key = api_key,
        .provider = provider,
        .configured_providers = configured_providers,
        .model = model,
        .effort = effort,
        .fast = fast,
        .ultrafast = ultrafast,
        .home = home,
        .workspace_root = workspace_root,
        .gateway_chat_url = gateway_chat_url,
    });
}

fn throwCreateError(env: c.napi_env, err: CreateError) c.napi_value {
    return switch (err) {
        error.JavaScriptException => null,
        error.TooManyRuntimes => throw(env, "LIBFX_NATIVE_LIMIT", "too many active native runtimes"),
        error.InvalidApiKey => throw(env, "LIBFX_INVALID_ARGUMENT", "apiKey is required and must be a bounded string"),
        error.InvalidProvider => throw(env, "LIBFX_INVALID_ARGUMENT", "provider must be \"gateway\", \"codex\", \"grok\" or a configured provider's name"),
        error.InvalidConfiguredProvider => throw(env, "LIBFX_INVALID_ARGUMENT", "configuredProviders must validly define the selected provider, without credentials"),
        error.InvalidModel => throw(env, "LIBFX_INVALID_ARGUMENT", "model must be a bounded string"),
        error.InvalidEffort => throw(env, "LIBFX_INVALID_ARGUMENT", "effort must be a bounded string"),
        error.InvalidFast => throw(env, "LIBFX_INVALID_ARGUMENT", "fast must be a boolean"),
        error.InvalidUltrafast => throw(env, "LIBFX_INVALID_ARGUMENT", "ultrafast must be a boolean"),
        error.InvalidHome => throw(env, "LIBFX_INVALID_ARGUMENT", "home is required and must be a bounded string"),
        error.InvalidWorkspaceRoot => throw(env, "LIBFX_INVALID_ARGUMENT", "workspaceRoot is required and must be a bounded string"),
        error.InvalidGatewayUrl => throw(env, "LIBFX_INVALID_ARGUMENT", "gatewayChatUrl must be a bounded string"),
        error.OutOfMemory => throw(env, "LIBFX_NATIVE_OOM", "could not allocate native runtime"),
        error.ThreadFailed => throw(env, "LIBFX_NATIVE_THREAD", "could not start native runtime thread"),
        error.ReadyChannelFailed => throw(env, "LIBFX_NATIVE_IO", "could not create native readiness channel"),
    };
}

fn finalizeRuntimeHandle(env: c.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const handle: *RuntimeHandle = @ptrCast(@alignCast(data orelse return));
    handle.unregisterCleanup(env);
    handle.destroy();
    std.heap.c_allocator.destroy(handle);
}

fn createCore(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    if (!callbackArgs(env, info, &argv)) return null;
    const runtime = createRuntime(env, argv[0]) catch |err| return throwCreateError(env, err);
    var runtime_owned = true;
    defer if (runtime_owned) runtime.deinit();
    const handle = std.heap.c_allocator.create(RuntimeHandle) catch
        return throw(env, "LIBFX_NATIVE_OOM", "could not allocate runtime handle");
    var handle_owned = true;
    defer if (handle_owned) {
        handle.unregisterCleanup(env);
        std.heap.c_allocator.destroy(handle);
    };
    handle.* = .{ .runtime = runtime, .cleanup_hook_registered = false };

    if (!statusOk(
        env,
        c.napi_add_env_cleanup_hook(env, cleanupRuntimeHandle, handle),
        "could not register native runtime cleanup",
    )) return null;
    handle.cleanup_hook_registered = true;

    var result: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_object(env, &result), "could not create runtime handle")) return null;
    if (!statusOk(
        env,
        c.napi_type_tag_object(env, result, &runtime_handle_type_tag),
        "could not brand runtime handle",
    )) return null;
    if (!statusOk(
        env,
        c.napi_wrap(env, result, handle, finalizeRuntimeHandle, null, null),
        "could not attach native runtime",
    )) return null;
    runtime_owned = false;
    handle_owned = false;
    return result;
}

fn runtimeHandleArg(env: c.napi_env, info: c.napi_callback_info, argv: []c.napi_value) ?*RuntimeHandle {
    if (!callbackArgs(env, info, argv)) return null;
    var branded = false;
    if (!statusOk(
        env,
        c.napi_check_object_type_tag(env, argv[0], &runtime_handle_type_tag, &branded),
        "could not validate runtime handle",
    )) return null;
    if (!branded) {
        _ = c.napi_throw_type_error(env, "LIBFX_INVALID_ARGUMENT", "invalid runtime handle");
        return null;
    }
    var context: ?*anyopaque = null;
    if (!statusOk(env, c.napi_unwrap(env, argv[0], &context), "invalid runtime handle")) return null;
    return @ptrCast(@alignCast(context orelse return null));
}

fn lockRuntime(env: c.napi_env, handle: *RuntimeHandle) ?*Runtime {
    handle.mutex.lockUncancelable(io_mod.getIo());
    const runtime = handle.runtime orelse {
        handle.mutex.unlock(io_mod.getIo());
        _ = c.napi_throw_error(env, "LIBFX_NATIVE_CLOSED", "native runtime is closed");
        return null;
    };
    return runtime;
}

fn unlockRuntime(handle: *RuntimeHandle) void {
    handle.mutex.unlock(io_mod.getIo());
}

fn takeCoreReadyFd(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    const reader = runtime.ready.reader orelse
        return throw(env, "LIBFX_INVALID_ARGUMENT", "readiness descriptor already transferred");
    var value: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_int32(env, reader, &value), "could not transfer readiness descriptor")) return null;
    runtime.ready.reader = null;
    return value;
}

fn fetch_handle_arg(env: c.napi_env, value: c.napi_value) ?fetch_state.Handle {
    var number: f64 = 0;
    if (c.napi_get_value_double(env, value, &number) != c.napi_ok or
        !std.math.isFinite(number) or
        number < 1 or
        number > @as(f64, @floatFromInt(std.math.maxInt(fetch_state.Handle))) or
        @floor(number) != number)
    {
        _ = c.napi_throw_type_error(env, "LIBFX_INVALID_ARGUMENT", "fetch handle must be a positive int32");
        return null;
    }
    return @intFromFloat(number);
}

fn fetch_operation_value(env: c.napi_env, result: FetchOperationResult) c.napi_value {
    var value: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_uint32(env, @backingInt(result), &value), "could not create fetch operation result")) return null;
    return value;
}

fn writeCore(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [2]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    var data: ?*anyopaque = null;
    var len: usize = 0;
    if (!statusOk(env, c.napi_get_buffer_info(env, argv[1], &data, &len), "write() requires a Buffer")) return null;
    const bytes = if (len == 0) &.{} else @as([*]const u8, @ptrCast(data orelse return throw(env, "LIBFX_NATIVE_IO", "Buffer data is unavailable")))[0..len];
    runtime.input.write(runtime.alloc, bytes) catch |err| return switch (err) {
        error.InputClosed => throw(env, "LIBFX_NATIVE_CLOSED", "native runtime input is closed"),
        error.InputQueueFull => throw(env, "LIBFX_NATIVE_BACKPRESSURE", "native runtime input queue is full"),
        error.OutOfMemory => throw(env, "LIBFX_NATIVE_OOM", "could not queue native input"),
    };
    var value: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &value);
    return value;
}

fn closeCore(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    runtime.closeInput();
    var value: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &value);
    return value;
}

fn drainCore(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    const available = runtime.output.available() catch
        return throw(env, "LIBFX_NATIVE_IO", "native output delivery failed");
    const len = @min(available, max_drain_bytes);
    var value: c.napi_value = undefined;
    var data: ?*anyopaque = null;
    if (!statusOk(env, c.napi_create_buffer(env, len, &data, &value), "could not allocate output Buffer")) return null;
    if (len == 0) return value;
    const written = runtime.output.drain(@as([*]u8, @ptrCast(data.?))[0..len]);
    if (written != len) return throw(env, "LIBFX_NATIVE_IO", "native output changed while draining");
    return value;
}

fn takeCoreFetch(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    const io = io_mod.getIo();
    runtime.fetch.mutex.lockUncancelable(io);
    defer runtime.fetch.mutex.unlock(io);
    const decision = fetch_state.decide(runtime.fetch.phase, .take_request);
    if (decision.action != .applied) return nullValue(env);
    // `request` is the JSON metadata record; `body` is the raw request body.
    var value: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_object(env, &value), "could not allocate fetch request")) return null;
    const request = bufferFromBytes(env, runtime.fetch.request.items, "could not allocate fetch request Buffer") orelse return null;
    const body = bufferFromBytes(env, runtime.fetch.request_body.items, "could not allocate fetch body Buffer") orelse return null;
    if (!statusOk(env, c.napi_set_named_property(env, value, "request", request), "could not publish fetch request")) return null;
    if (!statusOk(env, c.napi_set_named_property(env, value, "body", body), "could not publish fetch body")) return null;
    runtime.fetch.clearPendingRequest();
    runtime.fetch.phase = decision.phase;
    return value;
}

fn nullValue(env: c.napi_env) c.napi_value {
    var value: c.napi_value = undefined;
    _ = c.napi_get_null(env, &value);
    return value;
}

fn undefinedValue(env: c.napi_env) c.napi_value {
    var value: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &value);
    return value;
}

/// Copies `bytes` into a new Node Buffer. Returns null after throwing.
fn bufferFromBytes(env: c.napi_env, bytes: []const u8, message: [*:0]const u8) c.napi_value {
    var value: c.napi_value = undefined;
    var data: ?*anyopaque = null;
    if (!statusOk(env, c.napi_create_buffer(env, bytes.len, &data, &value), message)) return null;
    if (bytes.len > 0) @memcpy(@as([*]u8, @ptrCast(data.?))[0..bytes.len], bytes);
    return value;
}

fn attachmentIdArg(env: c.napi_env, value: c.napi_value) ?host_attachments.Id {
    var number: f64 = 0;
    if (c.napi_get_value_double(env, value, &number) != c.napi_ok or
        !std.math.isFinite(number) or
        number < 1 or
        number > @as(f64, @floatFromInt(std.math.maxInt(host_attachments.Id))) or
        @floor(number) != number)
    {
        _ = c.napi_throw_type_error(env, "LIBFX_INVALID_ARGUMENT", "attachment id must be a positive uint32");
        return null;
    }
    return @intFromFloat(number);
}

fn writeCoreAttachment(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [3]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const id = attachmentIdArg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    var data: ?*anyopaque = null;
    var len: usize = 0;
    if (!statusOk(env, c.napi_get_buffer_info(env, argv[2], &data, &len), "writeCoreAttachment() requires a Buffer")) return null;
    const bytes = if (len == 0) &.{} else @as([*]const u8, @ptrCast(data orelse return throw(env, "LIBFX_NATIVE_IO", "Buffer data is unavailable")))[0..len];
    runtime.attachments.write(id, bytes) catch |err| return switch (err) {
        error.AttachmentExists => throw(env, "LIBFX_INVALID_ARGUMENT", "attachment id is already pending"),
        error.AttachmentTooLarge => throw(env, "LIBFX_INVALID_ARGUMENT", "attachment exceeds the native attachment limit"),
        error.AttachmentTableFull => throw(env, "LIBFX_NATIVE_BACKPRESSURE", "native attachment table is full"),
        error.OutOfMemory => throw(env, "LIBFX_NATIVE_OOM", "could not store native attachment"),
    };
    return undefinedValue(env);
}

fn takeCoreAttachment(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [2]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const id = attachmentIdArg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    const bytes = runtime.attachments.takeOutbound(id) orelse return nullValue(env);
    defer std.heap.c_allocator.free(bytes);
    return bufferFromBytes(env, bytes, "could not allocate attachment Buffer");
}

fn discardCoreAttachments(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    runtime.attachments.discardInbound();
    return undefinedValue(env);
}

fn coreFetchActive(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [2]c.napi_value = undefined;
    const runtime_handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const fetch_handle = fetch_handle_arg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, runtime_handle) orelse return null;
    defer unlockRuntime(runtime_handle);
    var value: c.napi_value = undefined;
    _ = c.napi_get_boolean(env, runtime.fetch.is_active(fetch_handle), &value);
    return value;
}

fn coreFetchDisposition(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [2]c.napi_value = undefined;
    const runtime_handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const fetch_handle = fetch_handle_arg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, runtime_handle) orelse return null;
    defer unlockRuntime(runtime_handle);
    const disposition = runtime.fetch.disposition(fetch_handle);
    var value: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_int32(env, @backingInt(disposition), &value), "could not query fetch disposition")) return null;
    return value;
}

fn startCoreFetchResponse(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [3]c.napi_value = undefined;
    const runtime_handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const fetch_handle = fetch_handle_arg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, runtime_handle) orelse return null;
    defer unlockRuntime(runtime_handle);
    var status: u32 = 0;
    if (c.napi_get_value_uint32(env, argv[2], &status) != c.napi_ok or status > std.math.maxInt(u16))
        return throw(env, "LIBFX_INVALID_ARGUMENT", "fetch response status must be a uint16");
    return fetch_operation_value(env, runtime.fetch.startResponse(fetch_handle, @intCast(status)));
}

fn pushCoreFetchResponse(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [3]c.napi_value = undefined;
    const runtime_handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const fetch_handle = fetch_handle_arg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, runtime_handle) orelse return null;
    defer unlockRuntime(runtime_handle);
    var data: ?*anyopaque = null;
    var len: usize = 0;
    if (!statusOk(env, c.napi_get_buffer_info(env, argv[2], &data, &len), "fetch response chunk requires a Buffer")) return null;
    const bytes = if (len == 0) &.{} else @as([*]const u8, @ptrCast(data.?))[0..len];
    const result = runtime.fetch.pushResponse(fetch_handle, bytes) catch
        return throw(env, "LIBFX_NATIVE_OOM", "could not queue fetch response");
    return fetch_operation_value(env, result);
}

fn finishCoreFetch(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [2]c.napi_value = undefined;
    const runtime_handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const fetch_handle = fetch_handle_arg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, runtime_handle) orelse return null;
    defer unlockRuntime(runtime_handle);
    return fetch_operation_value(env, runtime.fetch.finishResponse(fetch_handle));
}

fn failCoreFetch(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [2]c.napi_value = undefined;
    const runtime_handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const fetch_handle = fetch_handle_arg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, runtime_handle) orelse return null;
    defer unlockRuntime(runtime_handle);
    return fetch_operation_value(env, runtime.fetch.failResponse(fetch_handle));
}

fn abortCoreFetch(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    runtime.abortHostEffects();
    var value: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &value);
    return value;
}

fn coreExited(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    var value: c.napi_value = undefined;
    _ = c.napi_get_boolean(env, runtime.exited.load(.seq_cst), &value);
    return value;
}

fn coreExitCode(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    var value: c.napi_value = undefined;
    _ = c.napi_create_uint32(env, runtime.exit_code.load(.seq_cst), &value);
    return value;
}

fn destroyCore(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    handle.unregisterCleanup(env);
    handle.destroy();
    var value: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &value);
    return value;
}

fn exportFunction(env: c.napi_env, exports: c.napi_value, name: [*:0]const u8, callback: c.napi_callback) bool {
    var function: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_function(env, name, c.NAPI_AUTO_LENGTH, callback, null, &function), "could not create addon function")) return false;
    return statusOk(env, c.napi_set_named_property(env, exports, name, function), "could not export addon function");
}

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) callconv(.c) c.napi_value {
    ensureThreadedIo();
    var api_version: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_uint32(env, 4, &api_version), "could not create API version")) return null;
    if (!statusOk(env, c.napi_set_named_property(env, exports, "libfxApiVersion", api_version), "could not export API version")) return null;
    var supports_ultrafast: c.napi_value = undefined;
    if (!statusOk(env, c.napi_get_boolean(env, true, &supports_ultrafast), "could not create ultrafast capability")) return null;
    if (!statusOk(env, c.napi_set_named_property(env, exports, "supportsUltrafast", supports_ultrafast), "could not export ultrafast capability")) return null;
    var supports_codex: c.napi_value = undefined;
    if (!statusOk(env, c.napi_get_boolean(env, true, &supports_codex), "could not create Codex capability")) return null;
    if (!statusOk(env, c.napi_set_named_property(env, exports, "supportsCodex", supports_codex), "could not export Codex capability")) return null;
    var supports_grok: c.napi_value = undefined;
    if (!statusOk(env, c.napi_get_boolean(env, true, &supports_grok), "could not create Grok capability")) return null;
    if (!statusOk(env, c.napi_set_named_property(env, exports, "supportsGrok", supports_grok), "could not export Grok capability")) return null;
    var supports_configured: c.napi_value = undefined;
    if (!statusOk(env, c.napi_get_boolean(env, true, &supports_configured), "could not create configured provider capability")) return null;
    if (!statusOk(env, c.napi_set_named_property(env, exports, "supportsConfiguredProvider", supports_configured), "could not export configured provider capability")) return null;
    if (!exportFunction(env, exports, "createCore", createCore)) return null;
    if (!exportFunction(env, exports, "takeCoreReadyFd", takeCoreReadyFd)) return null;
    if (!exportFunction(env, exports, "writeCore", writeCore)) return null;
    if (!exportFunction(env, exports, "closeCore", closeCore)) return null;
    if (!exportFunction(env, exports, "drainCore", drainCore)) return null;
    if (!exportFunction(env, exports, "writeCoreAttachment", writeCoreAttachment)) return null;
    if (!exportFunction(env, exports, "takeCoreAttachment", takeCoreAttachment)) return null;
    if (!exportFunction(env, exports, "discardCoreAttachments", discardCoreAttachments)) return null;
    if (!exportFunction(env, exports, "takeCoreFetch", takeCoreFetch)) return null;
    if (!exportFunction(env, exports, "coreFetchActive", coreFetchActive)) return null;
    if (!exportFunction(env, exports, "coreFetchDisposition", coreFetchDisposition)) return null;
    if (!exportFunction(env, exports, "startCoreFetchResponse", startCoreFetchResponse)) return null;
    if (!exportFunction(env, exports, "pushCoreFetchResponse", pushCoreFetchResponse)) return null;
    if (!exportFunction(env, exports, "finishCoreFetch", finishCoreFetch)) return null;
    if (!exportFunction(env, exports, "failCoreFetch", failCoreFetch)) return null;
    if (!exportFunction(env, exports, "abortCoreFetch", abortCoreFetch)) return null;
    if (!exportFunction(env, exports, "coreExited", coreExited)) return null;
    if (!exportFunction(env, exports, "coreExitCode", coreExitCode)) return null;
    if (!exportFunction(env, exports, "destroyCore", destroyCore)) return null;
    return exports;
}
