const std = @import("std");
const stream_provider = @import("../agent/stream_provider.zig");
const mem_utils = @import("../shared/mem_utils.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_set = @import("tool_set.zig");
const text_utils = @import("../shared/text_utils.zig");

const retrieval = @import("capability_retrieval.zig");
const lexical = @import("../shared/lexical_relevance.zig");

const Allocator = std.mem.Allocator;

pub const max_tools: usize = 64;
pub const max_catalog_tools: usize = 256;
pub const max_name_bytes: usize = 64;
pub const max_description_bytes: usize = 64 * 1024;
pub const max_schema_bytes: usize = 64 * 1024;

pub const ParseError = Allocator.Error || error{
    TooManyHostTools,
    InvalidHostTool,
    InvalidHostToolName,
    DuplicateHostToolName,
    UnsupportedProviderTool,
    HostToolDescriptionTooLarge,
    HostToolSchemaTooLarge,
};

pub const Runtime = struct {
    backing: ?Allocator = null,
    arena: ?*std.heap.ArenaAllocator = null,
    tools: []const tool_dispatch.Tool = &.{},
    order: []const []const u8 = &.{},
    dynamic_tools: []const stream_provider.DynamicFunctionTool = &.{},
    definitions: []const stream_provider.DynamicFunctionTool = &.{},
    descriptors: []const std.json.Value = &.{},
    deferred: []bool = &.{},
    loaded: []bool = &.{},
    search_enabled: bool = false,

    pub fn init(backing: Allocator, value: ?std.json.Value) ParseError!Runtime {
        return initWithProviderRegistry(backing, value, .{});
    }

    pub fn initWithProviderRegistry(
        backing: Allocator,
        value: ?std.json.Value,
        provider_registry: tool_dispatch.Registry,
    ) ParseError!Runtime {
        const tools_value = value orelse return .{};
        if (tools_value != .array) return error.InvalidHostTool;
        if (tools_value.array.items.len > max_catalog_tools) return error.TooManyHostTools;

        var dynamic_count: usize = 0;
        for (tools_value.array.items) |entry| {
            if (entry != .object) return error.InvalidHostTool;
            const provider_executed = if (entry.object.get("providerExecuted")) |value_| switch (value_) {
                .bool => |enabled| enabled,
                else => return error.InvalidHostTool,
            } else false;
            if (!provider_executed) dynamic_count += 1;
        }

        const arena = try backing.create(std.heap.ArenaAllocator);
        errdefer backing.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(backing);
        errdefer mem_utils.deinit_arena(arena.*);
        const alloc = arena.allocator();

        const descriptors = try alloc.alloc(std.json.Value, tools_value.array.items.len);
        for (tools_value.array.items, descriptors) |entry, *owned| {
            var out: std.Io.Writer.Allocating = .init(alloc);
            std.json.Stringify.value(entry, .{}, &out.writer) catch return error.OutOfMemory;
            owned.* = std.json.parseFromSliceLeaky(std.json.Value, alloc, out.written(), .{}) catch return error.InvalidHostTool;
        }
        const tools = try alloc.alloc(tool_dispatch.Tool, tools_value.array.items.len + 2);
        const order = try alloc.alloc([]const u8, tools.len);
        const deferred = try alloc.alloc(bool, tools_value.array.items.len);
        const loaded = try alloc.alloc(bool, tools_value.array.items.len);
        @memset(deferred, false);
        @memset(loaded, false);
        const dynamic_tools = try alloc.alloc(stream_provider.DynamicFunctionTool, dynamic_count);
        var dynamic_index: usize = 0;

        for (descriptors, 0..) |entry, index| {
            const name_value = entry.object.get("name") orelse return error.InvalidHostTool;
            if (name_value != .string) return error.InvalidHostTool;
            if (std.mem.eql(u8, name_value.string, "tool_search") or std.mem.eql(u8, name_value.string, "call_action") or !validName(name_value.string)) return error.InvalidHostToolName;
            for (order[0..index]) |prior| {
                if (std.mem.eql(u8, prior, name_value.string)) {
                    return error.DuplicateHostToolName;
                }
            }

            const provider_executed = if (entry.object.get("providerExecuted")) |value_| value_.bool else false;
            if (provider_executed) {
                const registered = provider_registry.lookup(name_value.string) orelse
                    return error.UnsupportedProviderTool;
                if (!registered.provider_executed or registered.write_provider_advertisement_fn == null) {
                    return error.UnsupportedProviderTool;
                }
                order[index] = registered.name;
                tools[index] = registered.*;
                continue;
            }

            deferred[index] = if (entry.object.get("deferred")) |flag| switch (flag) {
                .bool => flag.bool,
                else => return error.InvalidHostTool,
            } else false;
            const description_value = entry.object.get("description") orelse return error.InvalidHostTool;
            const schema_value = entry.object.get("inputSchema") orelse return error.InvalidHostTool;
            // A tool whose calls are safe to run twice says so. Its calls may
            // run again after a crash, and only its calls run beside others
            // unless it declares otherwise.
            const idempotent = if (entry.object.get("idempotent")) |value_| switch (value_) {
                .bool => |declared| declared,
                else => return error.InvalidHostTool,
            } else false;
            // A tool that writes is a fence: earlier calls finish before it
            // starts, and later calls wait for it. A tool that does not say
            // writes unless it is idempotent.
            const writes = if (entry.object.get("writes")) |value_| switch (value_) {
                .bool => |declared| declared,
                else => return error.InvalidHostTool,
            } else !idempotent;
            if (description_value != .string or schema_value != .object) return error.InvalidHostTool;
            if (description_value.string.len > max_description_bytes) {
                return error.HostToolDescriptionTooLarge;
            }

            const name = try alloc.dupe(u8, name_value.string);
            const description = try alloc.dupe(u8, description_value.string);
            var schema_out: std.Io.Writer.Allocating = .init(alloc);
            defer schema_out.deinit();
            std.json.Stringify.value(schema_value, .{}, &schema_out.writer) catch
                return error.OutOfMemory;
            if (schema_out.written().len > max_schema_bytes) {
                return error.HostToolSchemaTooLarge;
            }
            const schema_json = try schema_out.toOwnedSlice();
            const schema = std.json.parseFromSliceLeaky(
                std.json.Value,
                alloc,
                schema_json,
                .{},
            ) catch return error.InvalidHostTool;

            order[index] = name;
            dynamic_tools[dynamic_index] = .{
                .deferred = deferred[index],
                .name = name,
                .description = description,
                .input_schema = schema,
            };
            dynamic_index += 1;
            tools[index] = .{
                .name = name,
                .description = "",
                .model_schema = .{ .name = name, .description = "" },
                .model_visible = false,
                .host_concurrent = !writes,
                .host_idempotent = idempotent,
                .executor_kind = .host,
                .activity_kind = .command,
                .action_label = "Running",
                .completed_action_label = "Ran",
                .decode = decode,
                .call = call,
                .reads_only_fn = readsOnly,
                .irreversible_fn = irreversible,
            };
        }

        var direct_count: usize = 0;
        for (deferred) |flag| if (!flag) {
            direct_count += 1;
        };
        if (direct_count + @as(usize, if (std.mem.findScalar(bool, deferred, true) != null) 2 else 0) > max_tools) return error.TooManyHostTools;
        tools[tools.len - 2] = call_action_tool;
        tools[tools.len - 1] = search_tool;
        tools[tools.len - 1].model_visible = std.mem.findScalar(bool, deferred, true) != null;
        order[order.len - 2] = call_action_tool.name;
        order[order.len - 1] = search_tool.name;
        var visible: std.ArrayList(stream_provider.DynamicFunctionTool) = .empty;
        for (dynamic_tools) |definition| {
            for (descriptors, 0..) |entry, index| {
                if (std.mem.eql(u8, definition.name, entry.object.get("name").?.string) and !deferred[index])
                    try visible.append(alloc, definition);
            }
        }
        return .{
            .backing = backing,
            .arena = arena,
            .tools = if (tools[tools.len - 1].model_visible) tools else tools[0 .. tools.len - 2],
            .order = if (tools[tools.len - 1].model_visible) order else order[0 .. order.len - 2],
            .search_enabled = tools[tools.len - 1].model_visible,
            .dynamic_tools = try visible.toOwnedSlice(alloc),
            .definitions = dynamic_tools,
            .descriptors = descriptors,
            .deferred = deferred,
            .loaded = loaded,
        };
    }

    pub fn enableSearch(self: *Runtime) void {
        if (self.search_enabled or self.arena == null) return;
        self.tools = self.tools.ptr[0 .. self.tools.len + 2];
        self.order = self.order.ptr[0 .. self.order.len + 2];
        @constCast(&self.tools[self.tools.len - 1]).model_visible = true;
        self.search_enabled = true;
    }

    /// Caller owns the reminder. The catalog is context, never a root instruction.
    pub fn reminder(self: *const Runtime, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll("<system-reminder>\nAvailable actions (current catalog; replaces earlier catalogs):\n");
        for (self.descriptors, 0..) |entry, index| {
            if (!self.deferred[index]) continue;
            const description = entry.object.get("description").?.string;
            const line_end = std.mem.findScalar(u8, description, '\n') orelse description.len;
            try out.writer.print("{s}: {s}\n", .{ entry.object.get("name").?.string, text_utils.utf8PrefixByBytes(description[0..line_end], 160) });
            // Include a version fingerprint so schema-only changes also append a reminder.
            const schema = try std.json.Stringify.valueAlloc(alloc, entry.object.get("inputSchema").?, .{});
            defer alloc.free(schema);
            try out.writer.print("Definition version: {x}\n", .{std.hash.Wyhash.hash(0, schema)});
        }
        try out.writer.writeAll("Fetch current definitions with tool_search(query: select:name or keywords). Use call_action with the current arguments when a definition changes. Removed actions cannot be called.\n</system-reminder>");
        return out.toOwnedSlice();
    }

    pub fn saveState(self: *Runtime, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll("{\"loaded\":[");
        var count: usize = 0;
        for (self.descriptors, 0..) |descriptor, index| {
            if (!self.loaded[index]) continue;
            if (count > 0) try out.writer.writeByte(',');
            try std.json.Stringify.value(descriptor.object.get("name").?.string, .{}, &out.writer);
            count += 1;
        }
        try out.writer.writeAll("]}");
        return out.toOwnedSlice();
    }

    /// Restores matching names only; the host supplies current definitions.
    pub fn loadState(self: *Runtime, alloc: Allocator, json: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidHostState;
        const loaded = parsed.value.object.get("loaded") orelse return error.InvalidHostState;
        if (loaded != .array or loaded.array.items.len > max_catalog_tools) return error.InvalidHostState;
        for (loaded.array.items) |name| if (name != .string or !validName(name.string)) return error.InvalidHostState;
        for (loaded.array.items) |name| {
            for (self.descriptors, 0..) |descriptor, index| if (std.mem.eql(u8, name.string, descriptor.object.get("name").?.string)) {
                self.loaded[index] = true;
            };
        }
    }

    pub fn validateActiveBudget(self: *const Runtime) !void {
        var count: usize = if (self.search_enabled) 2 else 0;
        for (self.deferred) |deferred| if (!deferred) {
            count += 1;
        };
        if (count > max_tools) return error.TooManyHostTools;
    }

    /// Caller owns the flags. Only declarations in retained history count;
    /// activation metadata from a removed prefix is not a native declaration.
    pub fn declaredTools(self: *const Runtime, alloc: Allocator, messages: []const @import("../shared/types.zig").ChatMessage) ![]bool {
        const declared = try alloc.alloc(bool, self.loaded.len);
        errdefer alloc.free(declared);
        @memset(declared, false);
        for (messages) |message| if (message.tool_result_memory) |memory| if (memory.loaded_tools_json) |json| {
            const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
            defer parsed.deinit();
            if (parsed.value != .array) return error.InvalidHostState;
            for (parsed.value.array.items) |entry| {
                if (entry != .object) return error.InvalidHostState;
                const name = entry.object.get("name") orelse return error.InvalidHostState;
                if (name != .string) return error.InvalidHostState;
                for (self.descriptors, 0..) |descriptor, index| {
                    if (std.mem.eql(u8, name.string, descriptor.object.get("name").?.string)) declared[index] = true;
                }
            }
        };
        return declared;
    }

    pub fn initialTools(self: *Runtime, alloc: Allocator) ![]const stream_provider.DynamicFunctionTool {
        try self.validateActiveBudget();
        var result: std.ArrayList(stream_provider.DynamicFunctionTool) = .empty;
        try result.appendSlice(alloc, self.dynamic_tools);
        for (self.descriptors, 0..) |entry, index| {
            if (!self.deferred[index] or !self.loaded[index]) continue;
            for (self.definitions) |definition| {
                if (std.mem.eql(u8, definition.name, entry.object.get("name").?.string)) {
                    try result.append(alloc, definition);
                }
            }
        }
        return result.toOwnedSlice(alloc);
    }

    pub fn search(self: *Runtime, ctx: tool_dispatch.DispatchContext, arguments: []const u8) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
        const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, arguments, .{}) catch return error.InvalidToolArguments;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidToolArguments;
        const query = parsed.value.object.get("query") orelse return error.InvalidToolArguments;
        if (query != .string or query.string.len == 0) return error.InvalidToolArguments;
        const exact = std.mem.startsWith(u8, query.string, "select:");
        const search_query = if (exact) query.string[7..] else query.string;
        var prepared = lexical.prepare(search_query) catch return error.InvalidToolArguments;
        const limit: usize = if (parsed.value.object.get("limit")) |v| if (v == .integer and v.integer >= 1 and v.integer <= 20) @intCast(v.integer) else return error.InvalidToolArguments else 5;
        const docs = try ctx.allocator.alloc(retrieval.Document, self.definitions.len);
        defer ctx.allocator.free(docs);
        for (self.definitions, docs) |definition, *doc| doc.* = .{
            .stable_key = definition.name,
            .identities = .{ definition.name, "" },
            .primary = .{ definition.name, definition.description, "", "" },
        };
        var page = retrieval.retrieve(ctx.allocator, .{ .query = &prepared, .limit = limit, .kind = .mcp }, .mcp, docs) catch return error.InvalidToolArguments;
        defer page.deinit(ctx.allocator);
        var output: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer output.deinit();
        var additions: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer additions.deinit();
        output.writer.writeAll("Definitions (use call_action with name and args for updated definitions):") catch return error.OutOfMemory;
        additions.writer.writeByte('[') catch return error.OutOfMemory;
        var count: usize = 0;
        var result_bytes: usize = 2;
        var matches: usize = 0;
        for (page.matches) |match| {
            const definition = self.definitions[match.document_index];
            if (exact and !std.mem.eql(u8, definition.name, search_query)) continue;
            for (self.descriptors, 0..) |entry, index| {
                if (!std.mem.eql(u8, definition.name, entry.object.get("name").?.string) or !self.deferred[index]) continue;

                var schema: std.Io.Writer.Allocating = .init(ctx.allocator);
                defer schema.deinit();
                std.json.Stringify.value(entry, .{}, &schema.writer) catch return error.OutOfMemory;
                result_bytes += schema.written().len + @as(usize, if (matches > 0) 1 else 0);
                if (result_bytes > 64 * 1024) return .{ .failure = try ctx.allocator.dupe(u8, "Selected tool definitions exceed the 65536 byte limit") };
                matches += 1;
                output.writer.print("\n{s}", .{schema.written()}) catch return error.OutOfMemory;
                if (self.loaded[index]) continue;
                if (count > 0) additions.writer.writeByte(',') catch return error.OutOfMemory;
                additions.writer.writeAll(schema.written()) catch return error.OutOfMemory;
                count += 1;
            }
        }
        additions.writer.writeByte(']') catch return error.OutOfMemory;
        // Validate and allocate the complete result before activating any tool.
        const schemas = try additions.toOwnedSlice();
        const text = try output.toOwnedSlice();
        const values = std.json.parseFromSliceLeaky(std.json.Value, ctx.allocator, schemas, .{}) catch return error.OutOfMemory;
        for (values.array.items) |entry| {
            const name = entry.object.get("name").?.string;
            var schema: std.Io.Writer.Allocating = .init(ctx.allocator);
            defer schema.deinit();
            std.json.Stringify.value(entry, .{}, &schema.writer) catch return error.OutOfMemory;
            try tool_dispatch.reportSelectedDynamicTool(ctx, name, schema.written(), null);
            for (self.descriptors, 0..) |descriptor, index| if (std.mem.eql(u8, name, descriptor.object.get("name").?.string)) {
                self.loaded[index] = true;
            };
        }
        tool_dispatch.reportToolResultMemory(ctx, .{ .loaded_tools_json = schemas });
        return .{ .success = text };
    }

    pub fn deinit(self: *Runtime) void {
        if (self.arena) |arena| {
            const backing = self.backing.?;
            mem_utils.deinit_arena(arena.*);
            backing.destroy(arena);
        }
        self.* = .{};
    }

    pub fn toolSet(self: *const Runtime) tool_set.ToolSet {
        return .{
            .registry = .{ .tools = self.tools },
            .order = self.order,
            .read_only_tool_names = self.order,
        };
    }
};

/// Retains a provider tool's model and Gateway contracts without linking its
/// unreachable local executor into minimal libfx builds.
pub fn providerProjection(tool: tool_dispatch.Tool) tool_dispatch.Tool {
    std.debug.assert(tool.provider_executed);
    std.debug.assert(tool.write_provider_advertisement_fn != null);
    var projected = tool;
    projected.validate = null;
    projected.decode = decode;
    projected.call = call;
    projected.reads_only_fn = readsOnly;
    projected.irreversible_fn = irreversible;
    return projected;
}

const RawInput = struct {
    json: []u8,
};

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    for (name) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return true;
}

fn rawInputDeinit(raw: *anyopaque, alloc: Allocator) void {
    const input: *RawInput = @ptrCast(@alignCast(raw));
    alloc.free(input.json);
    alloc.destroy(input);
}

/// Caller owns the returned model-facing failure.
pub fn unknownToolFailure(alloc: Allocator, name: []const u8) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{ .@"error" = .{
        .type = "tool_not_found",
        .tool_name = name,
        .message = "No tool with this name exists. Use tool_search to find available tools.",
    } }, .{});
}

fn argumentFailure(ctx: tool_dispatch.DispatchContext, message: []const u8) Allocator.Error![]u8 {
    if (ctx.host_tool_catalog) |catalog| {
        for (catalog.definitions) |definition| {
            if (!std.mem.eql(u8, definition.name, ctx.tool_call_name)) continue;
            return std.json.Stringify.valueAlloc(ctx.allocator, .{ .@"error" = .{
                .type = "invalid_tool_arguments",
                .tool_name = definition.name,
                .message = message,
                .definition = .{ .name = definition.name, .description = definition.description, .parameters = definition.input_schema },
            } }, .{});
        }
    }
    return ctx.allocator.dupe(u8, message);
}

fn decode(
    ctx: tool_dispatch.DispatchContext,
    arguments_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, arguments_json, .{}) catch
        return .{ .failure = try argumentFailure(ctx, "Arguments must be a valid JSON object") };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .failure = try argumentFailure(ctx, "Arguments must be an object") };

    const input = try ctx.allocator.create(RawInput);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .json = try ctx.allocator.dupe(u8, arguments_json) };
    return .{ .input = .{ .ptr = input, .deinit_fn = rawInputDeinit } };
}

fn call(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const provider = ctx.host_tool_provider orelse return .{
        .failure = try ctx.allocator.dupe(u8, "Host tool executor is unavailable"),
    };
    if (std.mem.eql(u8, ctx.tool_call_name, "tool_search")) {
        const catalog = ctx.host_tool_catalog orelse return error.InvalidToolArguments;
        return catalog.search(ctx, input.as(RawInput).json);
    }
    if (std.mem.eql(u8, ctx.tool_call_name, "call_action")) {
        const catalog = ctx.host_tool_catalog orelse return error.InvalidToolArguments;
        const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, input.as(RawInput).json, .{}) catch return error.InvalidToolArguments;
        defer parsed.deinit();
        const name = parsed.value.object.get("name") orelse return .{ .failure = try ctx.allocator.dupe(u8, "name is required and must be a tool name") };
        const args = parsed.value.object.get("args") orelse return .{ .failure = try ctx.allocator.dupe(u8, "args is required; supply the tool arguments") };
        if (name != .string) return .{ .failure = try ctx.allocator.dupe(u8, "name must be a tool name string") };
        for (catalog.descriptors, 0..) |entry, index| {
            if (!catalog.deferred[index] or !std.mem.eql(u8, entry.object.get("name").?.string, name.string)) continue;
            const json = std.json.Stringify.valueAlloc(ctx.allocator, args, .{}) catch return error.OutOfMemory;
            defer ctx.allocator.free(json);
            return provider.call(ctx.allocator, name.string, ctx.tool_call_id, json, ctx.max_tool_result_bytes, ctx.cancel_flag);
        }
        return .{ .failure = try unknownToolFailure(ctx.allocator, name.string) };
    }
    return provider.call(
        ctx.allocator,
        ctx.tool_call_name,
        ctx.tool_call_id,
        input.as(RawInput).json,
        ctx.max_tool_result_bytes,
        ctx.cancel_flag,
    );
}

const call_action_tool: tool_dispatch.Tool = .{
    .name = "call_action",
    .description = "Call an action by name with its arguments.",
    .model_schema = .{ .name = "call_action", .description = "Call an action by name with its arguments.", .input_schema = .{ .properties = &.{ .{ .name = "name", .json_type = .string }, .{ .name = "args", .json_type = .object } }, .required = &.{ "name", "args" } } },
    .executor_kind = .host,
    .activity_kind = .command,
    .decode = decode,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = irreversible,
};

const search_tool: tool_dispatch.Tool = .{
    .name = "tool_search",
    .description = "Search deferred host tools. Loaded tools are available on the next call.",
    .model_schema = .{ .name = "tool_search", .description = "Search deferred host tools. Loaded tools are available on the next call.", .input_schema = .{ .properties = &.{ .{ .name = "query", .json_type = .string }, .{ .name = "limit", .json_type = .integer } }, .required = &.{"query"} } },
    .executor_kind = .host,
    .activity_kind = .command,
    .decode = decode,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = irreversible,
};

fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn irreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn writeTestProviderAdvertisement(
    _: Allocator,
    writer: *std.Io.Writer,
) tool_dispatch.ProviderAdvertisementError!void {
    try writer.writeAll("{\"type\":\"provider\",\"id\":\"gateway.test_search\",\"name\":\"test_search\",\"args\":{}}");
}

const test_provider_tool = tool_dispatch.Tool{
    .name = "web_search",
    .description = "Search the web",
    .model_schema = .{ .name = "web_search", .description = "Search the web" },
    .write_provider_advertisement_fn = writeTestProviderAdvertisement,
    .provider_executed = true,
    .decode = decode,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = irreversible,
};

test "host tool runtime validates and preserves raw schemas" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\[{"name":"lookup","description":"Look up a value","inputSchema":{"type":"object","properties":{"key":{"type":"string"}},"required":["key"]}}]
    ,
        .{},
    );
    defer parsed.deinit();
    var runtime = try Runtime.init(alloc, parsed.value);
    defer runtime.deinit();

    try std.testing.expectEqual(@as(usize, 1), runtime.tools.len);
    try std.testing.expect(runtime.toolSet().registry.lookup("lookup") != null);
    try std.testing.expectEqualStrings("lookup", runtime.dynamic_tools[0].name);
    try std.testing.expect(runtime.dynamic_tools[0].input_schema.object.get("properties") != null);
}

test "host tool runtime projects registered provider tools without host executors" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\[{"name":"lookup","description":"Look up a value","inputSchema":{}},{"name":"web_search","providerExecuted":true}]
    ,
        .{},
    );
    defer parsed.deinit();
    var runtime = try Runtime.initWithProviderRegistry(
        alloc,
        parsed.value,
        .{ .tools = &.{test_provider_tool} },
    );
    defer runtime.deinit();

    try std.testing.expectEqual(@as(usize, 2), runtime.tools.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.dynamic_tools.len);
    try std.testing.expectEqualStrings("lookup", runtime.dynamic_tools[0].name);
    const provider = runtime.toolSet().registry.lookup("web_search").?;
    try std.testing.expect(provider.provider_executed);
    try std.testing.expect(provider.write_provider_advertisement_fn != null);
}

test "host tool runtime rejects unknown provider tools" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\[{"name":"unknown","providerExecuted":true}]
    ,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(
        error.UnsupportedProviderTool,
        Runtime.initWithProviderRegistry(alloc, parsed.value, .{ .tools = &.{test_provider_tool} }),
    );
}

test "host tool runtime preserves long MCP descriptions" {
    const alloc = std.testing.allocator;
    const description = text_utils.repeat("Tool parameter guidance. ", 100);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "[{\"name\":\"lookup\",\"description\":\"" ++ description ++ "\",\"inputSchema\":{}}]",
        .{},
    );
    defer parsed.deinit();
    var runtime = try Runtime.init(alloc, parsed.value);
    defer runtime.deinit();
    try std.testing.expectEqualStrings(description, runtime.dynamic_tools[0].description);
}

test "host tool runtime bounds descriptions at 64 KiB" {
    const alloc = std.testing.allocator;
    const description = try alloc.alloc(u8, 64 * 1024 + 1);
    defer alloc.free(description);
    @memset(description, 'a');
    for ([_]usize{ 64 * 1024, 64 * 1024 + 1 }) |length| {
        const json = try alloc.print("[{{\"name\":\"lookup\",\"description\":\"{s}\",\"inputSchema\":{{}}}}]", .{description[0..length]});
        defer alloc.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        if (length == 64 * 1024) {
            var runtime = try Runtime.init(alloc, parsed.value);
            defer runtime.deinit();
            try std.testing.expectEqualStrings(description[0..length], runtime.dynamic_tools[0].description);
        } else {
            try std.testing.expectError(error.HostToolDescriptionTooLarge, Runtime.init(alloc, parsed.value));
        }
    }
}

test "host tools write unless they are idempotent or say they do not" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\[{"name":"lookup","description":"Look up","inputSchema":{},"idempotent":true},
        \\ {"name":"save","description":"Save","inputSchema":{},"idempotent":true,"writes":true},
        \\ {"name":"send","description":"Send","inputSchema":{}},
        \\ {"name":"read","description":"Read","inputSchema":{},"writes":false}]
    , .{});
    defer parsed.deinit();
    var runtime = try Runtime.init(std.testing.allocator, parsed.value);
    defer runtime.deinit();
    try std.testing.expect(runtime.tools[0].host_concurrent and runtime.tools[0].host_idempotent);
    try std.testing.expect(!runtime.tools[1].host_concurrent and runtime.tools[1].host_idempotent);
    try std.testing.expect(!runtime.tools[2].host_concurrent and !runtime.tools[2].host_idempotent);
    try std.testing.expect(runtime.tools[3].host_concurrent and !runtime.tools[3].host_idempotent);

    for ([_][]const u8{
        \\[{"name":"write","description":"Write","inputSchema":{},"writes":"yes"}]
        ,
        \\[{"name":"lookup","description":"Look up","inputSchema":{},"idempotent":"yes"}]
        ,
    }) |json| {
        const invalid = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer invalid.deinit();
        try std.testing.expectError(error.InvalidHostTool, Runtime.init(std.testing.allocator, invalid.value));
    }
}

test "host tool runtime rejects duplicate and invalid names" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        \\[{"name":"bad name","description":"bad","inputSchema":{}}]
        ,
        \\[{"name":"same","description":"one","inputSchema":{}},{"name":"same","description":"two","inputSchema":{}}]
        ,
    };
    for (cases) |json| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        try std.testing.expectError(
            if (std.mem.find(u8, json, "bad name") != null)
                error.InvalidHostToolName
            else
                error.DuplicateHostToolName,
            Runtime.init(alloc, parsed.value),
        );
    }
}

test "activation state retains names and uses current host definitions" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, "[{\"name\":\"action\",\"description\":\"current\",\"inputSchema\":{\"type\":\"object\"},\"deferred\":true}]", .{});
    defer parsed.deinit();
    var runtime = try Runtime.init(alloc, parsed.value);
    defer runtime.deinit();
    try runtime.loadState(alloc, "{\"loaded\":[\"action\",\"deleted\"]}");
    const state = try runtime.saveState(alloc);
    defer alloc.free(state);
    try std.testing.expectEqualStrings("{\"loaded\":[\"action\"]}", state);
    const tools = try runtime.initialTools(alloc);
    defer alloc.free(tools);
    try std.testing.expectEqualStrings("current", tools[0].description);
    try std.testing.expectError(error.InvalidHostState, runtime.loadState(alloc, "{\"loaded\":[123]}"));
    try std.testing.expect(runtime.loaded[0]);
}

test "search definition budget includes array delimiters and commas" {
    for ([_]usize{ 65536, 65537 }) |target_bytes| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const first = "{\"name\":\"action_a\",\"description\":\"action\",\"inputSchema\":{},\"deferred\":true}";
        const second_prefix = "{\"name\":\"action_b\",\"description\":\"action";
        const second_suffix = "\",\"inputSchema\":{},\"deferred\":true}";
        const padding = try alloc.alloc(u8, target_bytes - first.len - second_prefix.len - second_suffix.len - 3);
        @memset(padding, ' ');
        const json = try alloc.print("[{s},{s}{s}{s}]", .{ first, second_prefix, padding, second_suffix });
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        var runtime = try Runtime.init(alloc, parsed.value);
        defer runtime.deinit();
        var memory: ?@import("../shared/types.zig").ToolResultMemory = null;
        const result = try runtime.search(.{ .allocator = alloc, .tool_result_memory_sink = &memory }, "{\"query\":\"action\"}");
        if (target_bytes == 65536) {
            try std.testing.expect(result == .success);
            try std.testing.expectEqual(target_bytes, memory.?.loaded_tools_json.?.len);
            try std.testing.expect(runtime.loaded[0] and runtime.loaded[1]);
        } else {
            try std.testing.expect(result == .failure);
            try std.testing.expect(!runtime.loaded[0] and !runtime.loaded[1]);
        }
    }
}

test "repeated broad search retains one active tool per name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\[{"name":"notes_read","description":"Read notes","inputSchema":{},"deferred":true},
        \\ {"name":"notes_write","description":"Write notes","inputSchema":{},"deferred":true}]
    , .{});
    var runtime = try Runtime.init(alloc, parsed.value);
    defer runtime.deinit();
    var first: ?@import("../shared/types.zig").ToolResultMemory = null;
    _ = try runtime.search(.{ .allocator = alloc, .tool_result_memory_sink = &first }, "{\"query\":\"notes\"}");
    const loaded = try std.json.parseFromSlice(std.json.Value, alloc, first.?.loaded_tools_json.?, .{});
    try std.testing.expectEqual(@as(usize, 2), loaded.value.array.items.len);
    var second: ?@import("../shared/types.zig").ToolResultMemory = null;
    const result = try runtime.search(.{ .allocator = alloc, .tool_result_memory_sink = &second }, "{\"query\":\"notes\"}");
    try std.testing.expectEqualStrings("[]", second.?.loaded_tools_json.?);
    const active = try runtime.initialTools(alloc);
    var read_count: usize = 0;
    for (active) |tool| if (std.mem.eql(u8, tool.name, "notes_read")) {
        read_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), read_count);
    try std.testing.expect(std.mem.find(u8, result.success, "notes_read") != null);
    try std.testing.expect(std.mem.find(u8, result.success, "notes_write") != null);
}

test "deferred declarations rebuild from retained history rather than activation state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\[{"name":"notes_read","description":"Read notes","inputSchema":{},"deferred":true},
        \\ {"name":"notes_write","description":"Write notes","inputSchema":{},"deferred":true}]
    , .{});
    var runtime = try Runtime.init(alloc, parsed.value);
    defer runtime.deinit();
    try runtime.loadState(alloc, "{\"loaded\":[\"notes_read\",\"notes_write\"]}");
    const retained = try runtime.declaredTools(alloc, &.{.{ .role = .tool, .tool_result_memory = .{
        .loaded_tools_json = "[{\"name\":\"notes_write\"},{\"name\":\"removed\"}]",
    } }});
    try std.testing.expect(!retained[0] and retained[1]);
    @memcpy(runtime.loaded, retained);
    var memory: ?@import("../shared/types.zig").ToolResultMemory = null;
    _ = try runtime.search(.{ .allocator = alloc, .tool_result_memory_sink = &memory }, "{\"query\":\"notes\"}");
    const declarations = try std.json.parseFromSlice(std.json.Value, alloc, memory.?.loaded_tools_json.?, .{});
    try std.testing.expectEqual(@as(usize, 1), declarations.value.array.items.len);
    try std.testing.expectEqualStrings("notes_read", declarations.value.array.items[0].object.get("name").?.string);
    const compacted = try runtime.declaredTools(alloc, &.{});
    try std.testing.expect(!compacted[0] and !compacted[1]);
}

test "unloaded host calls execute without activation and report invalid or missing tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\[{"name":"action","description":"Current action","inputSchema":{"type":"object"},"deferred":true}]
    , .{});
    var runtime = try Runtime.init(alloc, parsed.value);
    defer runtime.deinit();
    const Fixture = struct {
        fn execute(_: *anyopaque, a: Allocator, name: []const u8, _: []const u8, json: []const u8, _: usize, _: ?*std.atomic.Value(bool)) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
            if (!std.mem.eql(u8, "action", name) or !std.mem.eql(u8, "{}", json)) return error.InvalidToolArguments;
            return .{ .success = try a.dupe(u8, "executed") };
        }
    };
    const ctx: tool_dispatch.DispatchContext = .{
        .allocator = alloc,
        .tool_call_name = "action",
        .host_tool_catalog = &runtime,
        .host_tool_provider = .{ .context = &runtime, .call_fn = Fixture.execute },
    };
    const input = try decode(ctx, "{}");
    const result = try call(ctx, input.input);
    try std.testing.expectEqualStrings("executed", result.success);
    try std.testing.expect(!runtime.loaded[0]);
    const invalid = try decode(ctx, "[]");
    try std.testing.expect(std.mem.find(u8, invalid.failure, "Arguments must be an object") != null);
    try std.testing.expect(std.mem.find(u8, invalid.failure, "\"definition\"") != null);
    var action_ctx = ctx;
    action_ctx.tool_call_name = "call_action";
    const action = try decode(action_ctx, "{\"name\":\"action\",\"args\":{}}");
    try std.testing.expectEqualStrings("executed", (try call(action_ctx, action.input)).success);
    const missing = try decode(action_ctx, "{\"name\":\"removed\",\"args\":{}}");
    const failure = (try call(action_ctx, missing.input)).failure;
    try std.testing.expect(std.mem.find(u8, failure, "tool_not_found") != null);
    try std.testing.expect(std.mem.find(u8, failure, "tool_search") != null);
    try std.testing.expect(!runtime.loaded[0]);
}
