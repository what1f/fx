const std = @import("std");
// The embedding host owns signal stacks, including those installed by sanitizers.
pub const std_options: std.Options = .{ .signal_stack_size = null };
const native = @import("native_core_runtime.zig");
const compactor = @import("core/compactor/compactor.zig");
const io_mod = @import("core/shared/io.zig");
const model_provider = @import("core/config/model_provider.zig");
const configured_provider = @import("core/config/configured_provider.zig");
const streamable_http = @import("core/mcp/streamable_http.zig");
const gateway = @import("builtins/gateway.zig");
const fetch_state = @import("napi_fetch_state.zig");
const Core = native.Runtime;
const Buffer = extern struct { data: ?[*]u8 = null, len: usize = 0 };

fn bytes(data: ?[*]const u8, len: usize) []const u8 {
    return if (len == 0) &.{} else data.?[0..len];
}
fn owned(data: []u8) Buffer {
    return .{ .data = data.ptr, .len = data.len };
}
fn copy(data: []const u8) !Buffer {
    const alloc = std.heap.c_allocator;
    return owned(try alloc.dupe(u8, data));
}
fn string(value: std.json.Value, name: []const u8, max: usize, required: bool) !?[]u8 {
    const alloc = std.heap.c_allocator;
    const v = value.object.get(name) orelse return if (required) error.MissingOption else null;
    if (v == .null and !required) return null;
    if (v != .string or v.string.len == 0 or v.string.len > max or std.mem.findScalar(u8, v.string, 0) != null) return error.InvalidOption;
    return try alloc.dupe(u8, v.string);
}
fn boolean(value: std.json.Value, name: []const u8) !?bool {
    const v = value.object.get(name) orelse return null;
    if (v == .null) return null;
    if (v != .bool) return error.InvalidOption;
    return v.bool;
}
fn autoCompact(value: std.json.Value) !?compactor.Trigger {
    const option = value.object.get("autoCompact") orelse return null;
    if (option == .null) return null;
    if (option != .object or option.object.count() != 1) return error.InvalidAutoCompact;
    if (option.object.get("percent")) |percent| {
        if (percent != .integer or percent.integer < 0 or !compactor.isValidPercent(@intCast(percent.integer))) return error.InvalidAutoCompact;
        return .{ .percent = @intCast(percent.integer) };
    }
    if (option.object.get("tokens")) |tokens| {
        if (tokens != .integer or tokens.integer <= 0) return error.InvalidAutoCompact;
        return .{ .tokens = std.math.cast(usize, tokens.integer) orelse return error.InvalidAutoCompact };
    }
    return error.InvalidAutoCompact;
}

fn create(data: []const u8) !*Core {
    const alloc = std.heap.c_allocator;
    if (data.len > 2 * 1024 * 1024) return error.OptionsTooLarge;
    native.ensureThreadedIo();
    if (!native.claimRuntimeSlot()) return error.TooManyRuntimes;
    errdefer native.releaseRuntimeSlot();
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();
    const value = parsed.value;
    if (value != .object) return error.InvalidOptions;
    const provider_name = try string(value, "provider", configured_provider.max_id_bytes, false);
    defer if (provider_name) |v| alloc.free(v);
    const provider: ?model_provider.ProviderId = if (provider_name) |v| model_provider.parse(v) orelse return error.InvalidProvider else null;
    const providers = try string(value, "configuredProviders", 1024 * 1024, false);
    errdefer if (providers) |v| alloc.free(v);
    const configured = if (provider) |v| v == .configured else false;
    if (configured != (providers != null)) return error.InvalidConfiguredProvider;
    const key = try string(value, "apiKey", native.max_api_key_bytes, false);
    errdefer if (key) |v| alloc.free(v);
    if (key == null and (provider == null or provider.? == .gateway)) return error.InvalidApiKey;
    const model = try string(value, "model", native.max_model_bytes, false);
    errdefer if (model) |v| alloc.free(v);
    const effort = try string(value, "effort", native.max_effort_bytes, false);
    errdefer if (effort) |v| alloc.free(v);
    const home = (try string(value, "home", native.max_path_bytes, true)).?;
    errdefer alloc.free(home);
    const workspace = (try string(value, "workspaceRoot", native.max_path_bytes, true)).?;
    errdefer alloc.free(workspace);
    if (!std.Io.Dir.path.isAbsolute(home) or !std.Io.Dir.path.isAbsolute(workspace)) return error.InvalidPath;
    const url = (try string(value, "gatewayChatUrl", native.max_url_bytes, false)) orelse try alloc.dupe(u8, gateway.default_chat_url);
    errdefer alloc.free(url);
    try streamable_http.validateEndpoint(url);
    if (!std.mem.eql(u8, url, gateway.default_chat_url)) {
        const uri = try std.Uri.parse(url);
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InvalidGatewayUrl;
    }
    return native.createOwned(alloc, .{
        .api_key = key,
        .provider = provider,
        .configured_providers = providers,
        .model = model,
        .effort = effort,
        .auto_compact = try autoCompact(value),
        .fast = try boolean(value, "fast"),
        .ultrafast = try boolean(value, "ultrafast"),
        .home = home,
        .workspace_root = workspace,
        .gateway_chat_url = url,
    });
}
export fn fx_core_abi_version() u32 {
    return 1;
}

export fn fx_core_create(data: ?[*]const u8, len: usize, failure: *Buffer) ?*Core {
    failure.* = .{};
    if (data == null and len != 0) {
        failure.* = copy("InvalidArgument") catch .{};
        return null;
    }
    return create(bytes(data, len)) catch |err| {
        failure.* = copy(@errorName(err)) catch .{};
        return null;
    };
}
export fn fx_buffer_free(buffer: Buffer) void {
    const alloc = std.heap.c_allocator;
    if (buffer.data) |data| alloc.free(data[0..buffer.len]);
}
export fn fx_core_ready_fd(core: *Core) i32 {
    return core.ready.reader orelse -1;
}
export fn fx_core_write(core: *Core, data: ?[*]const u8, len: usize) i32 {
    if (data == null and len != 0) return -1;
    core.input.write(core.alloc, bytes(data, len)) catch return -1;
    return 0;
}
export fn fx_core_drain(core: *Core, output: *Buffer) i32 {
    const alloc = std.heap.c_allocator;
    output.* = .{};
    const available = core.output.available() catch return -1;
    const data = alloc.alloc(u8, @min(available, native.max_drain_bytes)) catch return -1;
    const written = core.output.drain(data);
    if (written != data.len) {
        alloc.free(data);
        return -1;
    }
    output.* = owned(data);
    return 0;
}
export fn fx_core_take_fetch(core: *Core, metadata: *Buffer, body: *Buffer) i32 {
    metadata.* = .{};
    body.* = .{};
    const io = io_mod.getIo();
    core.fetch.mutex.lockUncancelable(io);
    defer core.fetch.mutex.unlock(io);
    const decision = fetch_state.decide(core.fetch.phase, .take_request);
    if (decision.action != .applied) return 0;
    const m = copy(core.fetch.request.items) catch return -1;
    const b = copy(core.fetch.request_body.items) catch {
        fx_buffer_free(m);
        return -1;
    };
    metadata.* = m;
    body.* = b;
    core.fetch.clearPendingRequest();
    core.fetch.phase = decision.phase;
    return 1;
}
export fn fx_core_start_fetch(core: *Core, handle: i32, status: u16) i32 {
    return @backingInt(core.fetch.startResponse(handle, status));
}
export fn fx_core_push_fetch(core: *Core, handle: i32, data: ?[*]const u8, len: usize) i32 {
    if (data == null and len != 0) return -1;
    return @backingInt(core.fetch.pushResponse(handle, bytes(data, len)) catch return -1);
}
export fn fx_core_finish_fetch(core: *Core, handle: i32) i32 {
    return @backingInt(core.fetch.finishResponse(handle));
}
export fn fx_core_fail_fetch(core: *Core, handle: i32) i32 {
    return @backingInt(core.fetch.failResponse(handle));
}
export fn fx_core_fetch_disposition(core: *Core, handle: i32) i32 {
    return @backingInt(core.fetch.disposition(handle));
}
export fn fx_core_write_attachment(core: *Core, id: u32, data: ?[*]const u8, len: usize) i32 {
    if (id == 0) return -1;
    if (data == null and len != 0) return -1;
    core.attachments.write(id, bytes(data, len)) catch return -1;
    return 0;
}
export fn fx_core_take_attachment(core: *Core, id: u32, output: *Buffer) i32 {
    output.* = .{};
    output.* = owned(core.attachments.takeOutbound(id) orelse return 0);
    return 1;
}
export fn fx_core_discard_attachments(core: *Core) void {
    core.attachments.discardInbound();
}
export fn fx_core_abort_fetch(core: *Core) void {
    core.abortHostEffects();
}
export fn fx_core_close(core: *Core) void {
    core.closeInput();
}
export fn fx_core_exited(core: *Core) i32 {
    return @intFromBool(core.exited.load(.seq_cst));
}
export fn fx_core_exit_code(core: *Core) i32 {
    return core.exit_code.load(.seq_cst);
}
export fn fx_core_destroy(core: *Core) void {
    core.deinit();
}
