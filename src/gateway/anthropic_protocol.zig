//! Messages text/tool transport. Inline tool additions follow pi's
//! packages/ai/src/api/anthropic-messages.ts; definitions stay at discovery time.
const std = @import("std");
const streams = @import("../core/agent/stream_provider.zig");
const cc = @import("chat_completions_protocol.zig");
const sse = @import("sse.zig");
const Allocator = std.mem.Allocator;

pub const headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "accept", .value = "text/event-stream" },
    .{ .name = "anthropic-version", .value = "2023-06-01" },
    .{ .name = "anthropic-beta", .value = "inline-tools-2026-09-15" },
};

fn json(w: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, w);
}

/// Caller owns the request. This first Messages surface accepts text and tools.
pub fn build(alloc: Allocator, request: streams.RequestData) ![]u8 {
    return buildFor(alloc, request, null);
}

pub fn buildFor(alloc: Allocator, input: streams.RequestData, provider: ?@import("../core/config/model_provider.zig").ProviderId) ![]u8 {
    return buildConfigured(alloc, input, provider, .native);
}

pub fn buildConfigured(alloc: Allocator, input: streams.RequestData, provider: ?@import("../core/config/model_provider.zig").ProviderId, mode: @import("../core/config/configured_provider.zig").DeferredToolMode) ![]u8 {
    var request = input;
    const types = @import("../core/shared/types.zig");
    const projected = if (provider) |identity| try types.projectProviderReplay(alloc, input.messages, .{ .provider = identity, .model = input.model }) else null;
    defer if (projected) |messages| alloc.free(messages);
    request.messages = projected orelse input.messages;
    const encoded = try cc.build_request(alloc, request, .{ .provider = if (provider) |*identity| identity else null });
    defer alloc.free(encoded);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded, .{});
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"model\":");
    try json(w, request.model);
    try w.print(",\"stream\":true,\"max_tokens\":{d},\"system\":[", .{request.max_output_tokens orelse 4096});
    for (request.instructions, 0..) |message, index| {
        if (index > 0) try w.writeByte(',');
        try w.writeAll("{\"type\":\"text\",\"text\":");
        try json(w, message.content orelse "");
        try w.writeByte('}');
    }
    try w.writeByte(']');
    if (request.provider_options.reasoning) |effort| {
        if (std.mem.eql(u8, effort.label(), "none")) {
            try w.writeAll(",\"thinking\":{\"type\":\"disabled\"}");
        } else {
            try w.writeAll(",\"thinking\":{\"type\":\"adaptive\"},\"output_config\":{\"effort\":");
            try json(w, effort.label());
            try w.writeByte('}');
        }
    }
    try w.writeAll(",\"tools\":[");
    var count: usize = 0;
    var deferred = false;
    if (parsed.value.object.get("tools")) |tools| for (tools.array.items) |entry| {
        const f = entry.object.get("function").?;
        const name = f.object.get("name").?.string;
        if (std.mem.eql(u8, name, "tool_search")) deferred = true;
        if (count > 0) try w.writeByte(',');
        count += 1;
        try w.writeAll("{\"name\":");
        try json(w, name);
        try w.writeAll(",\"description\":");
        try json(w, f.object.get("description").?);
        try w.writeAll(",\"input_schema\":");
        try json(w, f.object.get("parameters").?);
        try w.writeByte('}');
    };
    if (deferred and mode == .native) {
        if (count > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":\"__fx_deferred_placeholder__\",\"description\":\"Reserved. Never call.\",\"input_schema\":{\"type\":\"object\",\"properties\":{}},\"defer_loading\":true}");
    }
    try w.writeAll("],\"messages\":[");
    count = 0;
    var declarations = @import("deferred_definitions.zig").Declarations.init(alloc);
    defer declarations.deinit();
    for (request.messages, 0..) |message, message_index| {
        if (message.images.len > 0) return error.UnsupportedProviderContent;
        if (message.tool_result_memory) |memory| if (memory.tool_images.len > 0) return error.UnsupportedProviderContent;
        if (count > 0) try w.writeByte(',');
        count += 1;
        try w.writeAll("{\"role\":");
        try json(w, if (message.role == .assistant) "assistant" else "user");
        try w.writeAll(",\"content\":[");
        var blocks: usize = 0;
        if (message.provider_replay) |replay| {
            const saved = try std.json.parseFromSlice(std.json.Value, alloc, replay.parts_json, .{});
            defer saved.deinit();
            if (saved.value.object.get("reasoning_details")) |details| if (details == .array) {
                for (details.array.items) |block| {
                    const kind = block.object.get("type") orelse return error.InvalidProviderState;
                    if (kind != .string or (!std.mem.eql(u8, kind.string, "thinking") and !std.mem.eql(u8, kind.string, "redacted_thinking"))) return error.InvalidProviderState;
                    if (blocks > 0) try w.writeByte(',');
                    try json(w, block);
                    blocks += 1;
                }
            };
        }
        if (message.role == .tool) {
            try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
            try json(w, message.tool_call_id orelse "");
            try w.writeAll(",\"content\":");
            const definitions = if (message.tool_result_memory) |memory| memory.loaded_tools_json else null;
            if (mode == .call_action and definitions != null) {
                const current = try @import("deferred_definitions.zig").snapshot(alloc, definitions.?);
                defer alloc.free(current);
                try json(w, if (std.mem.eql(u8, current, "[]")) message.content orelse current else current);
            } else {
                try json(w, message.content orelse "");
            }
            if (message.tool_result_status == .failure) try w.writeAll(",\"is_error\":true");
            try w.writeByte('}');
            blocks += 1;
        } else if (message.content) |text| if (text.len > 0) {
            if (blocks > 0) try w.writeByte(',');
            try w.writeAll("{\"type\":\"text\",\"text\":");
            try json(w, text);
            try w.writeByte('}');
            blocks += 1;
        };
        for (message.tool_calls) |call| {
            if (blocks > 0) try w.writeByte(',');
            blocks += 1;
            try w.writeAll("{\"type\":\"tool_use\",\"id\":");
            try json(w, call.id);
            try w.writeAll(",\"name\":");
            try json(w, call.name);
            try w.writeAll(",\"input\":");
            const args = try std.json.parseFromSlice(std.json.Value, alloc, call.arguments_json, .{});
            defer args.deinit();
            try json(w, args.value);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
        if (mode == .call_action) continue;
        if (message.role != .tool or (message_index + 1 < request.messages.len and request.messages[message_index + 1].role == .tool)) continue;
        var group_start = message_index;
        while (group_start > 0 and request.messages[group_start - 1].role == .tool) group_start -= 1;
        for (request.messages[group_start .. message_index + 1]) |result| if (result.tool_result_memory) |memory| if (memory.loaded_tools_json) |definitions| {
            const current = try declarations.first(alloc, definitions);
            defer alloc.free(current);
            const loaded = try std.json.parseFromSlice(std.json.Value, alloc, current, .{});
            defer loaded.deinit();
            if (loaded.value.array.items.len == 0) continue;
            try w.writeAll(",{\"role\":\"system\",\"content\":[");
            for (loaded.value.array.items, 0..) |entry, index| {
                if (index > 0) try w.writeByte(',');
                try w.writeAll("{\"type\":\"tool_addition\",\"tool\":{\"type\":\"tool_definition\",\"definition\":{\"name\":");
                try json(w, entry.object.get("name").?);
                try w.writeAll(",\"description\":");
                try json(w, entry.object.get("description").?);
                try w.writeAll(",\"input_schema\":");
                try json(w, entry.object.get("inputSchema").?);
                try w.writeAll("}}}");
            }
            try w.writeAll("]}");
        };
    }
    try w.writeAll("]}");
    return out.toOwnedSlice();
}

const Usage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cache_read_input_tokens: ?u64 = null,
    cache_creation_input_tokens: ?u64 = null,
};
const Event = struct {
    type: []const u8,
    index: ?usize = null,
    content_block: ?struct {
        type: []const u8,
        id: ?[]const u8 = null,
        name: ?[]const u8 = null,
        text: ?[]const u8 = null,
        thinking: ?[]const u8 = null,
        signature: ?[]const u8 = null,
    } = null,
    delta: ?struct {
        type: ?[]const u8 = null,
        text: ?[]const u8 = null,
        partial_json: ?[]const u8 = null,
        thinking: ?[]const u8 = null,
        signature: ?[]const u8 = null,
        stop_reason: ?[]const u8 = null,
    } = null,
    message: ?struct { usage: ?Usage = null } = null,
    usage: ?Usage = null,
};

/// Reuses the bounded function accumulator after translating Messages events.
pub fn consume(alloc: Allocator, source: *std.Io.Reader, request: streams.ModelRequest, progress: ?sse.Progress) !streams.Result {
    var reducer = try cc.Reducer.init(alloc, request.data(), .{});
    defer reducer.deinit();
    var framing: sse.Reader = .{ .max_event_bytes = 1024 * 1024, .max_total_bytes = 16 * 1024 * 1024, .progress = progress };
    defer framing.deinit(alloc);
    var finished = false;
    var thinking_index: ?usize = null;
    var thinking: std.Io.Writer.Allocating = .init(alloc);
    defer thinking.deinit();
    var signature: std.Io.Writer.Allocating = .init(alloc);
    defer signature.deinit();
    var tools: [256]bool = @splat(false);
    var tool_indices: [256]?usize = @splat(null);
    var tool_count: usize = 0;
    var arguments: [256]bool = @splat(false);
    while (try framing.next(alloc, source, request.cancel_flag)) |bytes| {
        const parsed = std.json.parseFromSlice(Event, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidEvent;
        defer parsed.deinit();
        const event = parsed.value;
        const kind = event.type;
        if (std.mem.eql(u8, kind, "error")) return error.ProviderError;
        if (std.mem.eql(u8, kind, "message_stop")) {
            if (!finished or thinking_index != null) return error.IncompleteStream;
            _ = try reducer.accept("[DONE]", request.cancel_flag.load(.seq_cst));
            return reducer.finish(request.cancel_flag.load(.seq_cst));
        }
        if (event.index) |index| if (index >= tools.len) return error.TooManyTools;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"choices\":[{\"index\":0,\"delta\":{");
        var reason: ?[]const u8 = null;
        var usage: ?Usage = null;
        if (std.mem.eql(u8, kind, "content_block_start")) {
            const block = event.content_block orelse return error.InvalidEvent;
            const index = event.index orelse return error.InvalidEvent;
            if (std.mem.eql(u8, block.type, "tool_use")) {
                if (tools[index]) return error.InvalidEvent;
                tools[index] = true;
                tool_indices[index] = tool_count;
                tool_count += 1;
                try w.print("\"tool_calls\":[{{\"index\":{d},\"id\":", .{tool_indices[index].?});
                try json(w, block.id orelse return error.InvalidEvent);
                try w.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                try json(w, block.name orelse return error.InvalidEvent);
                try w.writeAll(",\"arguments\":\"\"}}]");
            } else if (std.mem.eql(u8, block.type, "text")) {
                try w.writeAll("\"content\":");
                try json(w, block.text orelse "");
            } else if (std.mem.eql(u8, block.type, "thinking")) {
                if (thinking_index != null) return error.InvalidEvent;
                thinking_index = index;
                thinking.clearRetainingCapacity();
                signature.clearRetainingCapacity();
                try thinking.writer.writeAll(block.thinking orelse "");
                try signature.writer.writeAll(block.signature orelse "");
                try w.writeAll("\"reasoning_content\":");
                try json(w, block.thinking orelse "");
            } else return error.UnsupportedProviderContent;
        } else if (std.mem.eql(u8, kind, "content_block_delta")) {
            const delta = event.delta orelse return error.InvalidEvent;
            const delta_type = delta.type orelse return error.InvalidEvent;
            const index = event.index orelse return error.InvalidEvent;
            if (std.mem.eql(u8, delta_type, "text_delta")) {
                try w.writeAll("\"content\":");
                try json(w, delta.text orelse return error.InvalidEvent);
            } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                if (!tools[index]) return error.InvalidEvent;
                const partial = delta.partial_json orelse return error.InvalidEvent;
                arguments[index] = arguments[index] or partial.len > 0;
                try w.print("\"tool_calls\":[{{\"index\":{d},\"function\":{{\"arguments\":", .{tool_indices[index].?});
                try json(w, partial);
                try w.writeAll("}}]");
            } else if (std.mem.eql(u8, delta_type, "thinking_delta") or std.mem.eql(u8, delta_type, "signature_delta")) {
                if (thinking_index != index) return error.InvalidEvent;
                if (std.mem.eql(u8, delta_type, "thinking_delta")) {
                    const text = delta.thinking orelse return error.InvalidEvent;
                    if (thinking.written().len + text.len > 1024 * 1024) return error.ProviderStateTooLarge;
                    try thinking.writer.writeAll(text);
                    try w.writeAll("\"reasoning_content\":");
                    try json(w, text);
                } else {
                    const text = delta.signature orelse return error.InvalidEvent;
                    if (signature.written().len + text.len > 1024 * 1024) return error.ProviderStateTooLarge;
                    try signature.writer.writeAll(text);
                }
            } else return error.UnsupportedProviderContent;
        } else if (std.mem.eql(u8, kind, "content_block_stop")) {
            const index = event.index orelse return error.InvalidEvent;
            if (thinking_index == index) {
                try w.writeAll("\"reasoning_details\":[{\"type\":\"thinking\",\"thinking\":");
                try json(w, thinking.written());
                try w.writeAll(",\"signature\":");
                try json(w, signature.written());
                try w.writeAll("}]");
                thinking_index = null;
            }
            if (tools[index] and !arguments[index]) {
                try w.print("\"tool_calls\":[{{\"index\":{d},\"function\":{{\"arguments\":\"{{}}\"}}}}]", .{tool_indices[index].?});
                arguments[index] = true;
            }
        } else if (std.mem.eql(u8, kind, "message_start")) {
            usage = (event.message orelse return error.InvalidEvent).usage;
            // The start output count is provisional; retain the final count only.
            if (usage) |*value| value.output_tokens = null;
        } else if (std.mem.eql(u8, kind, "message_delta")) {
            const stop = (event.delta orelse return error.InvalidEvent).stop_reason orelse return error.InvalidEvent;
            reason = if (std.mem.eql(u8, stop, "tool_use")) "tool_calls" else if (std.mem.eql(u8, stop, "max_tokens")) "length" else if (std.mem.eql(u8, stop, "end_turn") or std.mem.eql(u8, stop, "stop_sequence")) "stop" else return error.InvalidFinishReason;
            usage = event.usage;
            finished = true;
        } else if (std.mem.eql(u8, kind, "ping")) continue else return error.UnsupportedProviderContent;
        try w.writeByte('}');
        if (reason) |value| {
            try w.writeAll(",\"finish_reason\":");
            try json(w, value);
        }
        try w.writeAll("}]");
        if (usage) |value| {
            try w.writeAll(",\"usage\":{");
            if (value.input_tokens) |input| try w.print("\"prompt_tokens\":{d},", .{input +| (value.cache_read_input_tokens orelse 0) +| (value.cache_creation_input_tokens orelse 0)});
            try w.writeAll("\"completion_tokens\":");
            try json(w, value.output_tokens);
            if (value.cache_read_input_tokens != null or value.cache_creation_input_tokens != null) {
                try w.writeAll(",\"prompt_tokens_details\":{");
                if (value.cache_read_input_tokens) |cached| try w.print("\"cached_tokens\":{d}", .{cached});
                if (value.cache_creation_input_tokens) |created| {
                    if (value.cache_read_input_tokens != null) try w.writeByte(',');
                    try w.print("\"cache_write_tokens\":{d}", .{created});
                }
                try w.writeByte('}');
            }
            try w.writeByte('}');
        }
        try w.writeByte('}');
        const deltas = try reducer.accept(out.written(), request.cancel_flag.load(.seq_cst));
        if (deltas.content) |text| request.events.emit(.{ .content_delta = text });
        for (deltas.reasoning) |delta| if (delta) |text| request.events.emit(.{ .reasoning_delta = text });
    }
    return error.IncompleteStream;
}

test "deferred tools preserve Anthropic prefix and append definitions" {
    const alloc = std.testing.allocator;
    const types = @import("../core/shared/types.zig");
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "Find action" },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "search-1", .name = "tool_search", .arguments_json = "{\"query\":\"action\"}" }} },
        .{ .role = .tool, .tool_call_id = "search-1", .tool_name = "tool_search", .content = "Act", .tool_result_memory = .{ .loaded_tools_json = "[{\"name\":\"action\",\"description\":\"Act\",\"inputSchema\":{\"type\":\"object\"}}]" } },
    };
    var request: streams.RequestData = .{ .model = "claude-test", .instructions = &.{.{ .role = .system, .content = "Stable" }}, .messages = messages[0..1], .tool_choice = .auto, .provider_options = .{}, .tools = .{ .advertised_names = &.{"tool_search"}, .advertised_functions = &.{.{ .name = "tool_search", .description = "Search" }} } };
    const before = try build(alloc, request);
    defer alloc.free(before);
    request.messages = &messages;
    request.tools.selected_dynamic = &.{.{ .name = "action", .description = "Changed", .input_schema = .{ .object = .empty }, .deferred = true }};
    const after = try build(alloc, request);
    defer alloc.free(after);
    // Remove only the closing messages-array bracket and root brace.
    try std.testing.expect(std.mem.startsWith(u8, after, before[0 .. before.len - 2]));
    try std.testing.expect(std.mem.find(u8, after, "\"tool_addition\"") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, after, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("tools").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 4), parsed.value.object.get("messages").?.array.items.len);
    request.messages = messages[0..1];
    request.tools.advertised_names = &.{ "tool_search", "call_action" };
    request.tools.advertised_functions = &.{ .{ .name = "tool_search", .description = "Search" }, .{ .name = "call_action", .description = "Call a discovered action" } };
    const compatible_before = try buildConfigured(alloc, request, null, .call_action);
    defer alloc.free(compatible_before);
    request.messages = &messages;
    const compatible_after = try buildConfigured(alloc, request, null, .call_action);
    defer alloc.free(compatible_after);
    try std.testing.expect(std.mem.startsWith(u8, compatible_after, compatible_before[0 .. compatible_before.len - 2]));
    try std.testing.expect(std.mem.find(u8, compatible_after, "\"call_action\"") != null);
    try std.testing.expect(std.mem.find(u8, compatible_after, "tool_addition") == null);
    const compatible = try std.json.parseFromSlice(std.json.Value, alloc, compatible_after, .{});
    defer compatible.deinit();
    try std.testing.expectEqual(@as(usize, 2), compatible.value.object.get("tools").?.array.items.len);
    const content = compatible.value.object.get("messages").?.array.items[2].object.get("content").?.array.items[0].object.get("content").?.string;
    try std.testing.expect(std.mem.find(u8, content, "Changed") == null);
    try std.testing.expect(std.mem.find(u8, content, "Act\"") != null);
}

test "Anthropic stream rejects malformed and incomplete events" {
    const Fake = @import("host_transport_testing.zig").FakeTransport;
    var fake: Fake = .{ .responses = &.{} };
    defer fake.deinit();
    const cases = [_]struct { body: []const u8, expected: anyerror }{
        .{ .body = "data: {\"type\":\"content_block_start\",\"index\":0}\n\n", .expected = error.InvalidEvent },
        .{ .body = "data: {\"type\":\"message_stop\"}\n\n", .expected = error.IncompleteStream },
        .{ .body = "data: {\"type\":\"content_block_start\",\"index\":256}\n\n", .expected = error.TooManyTools },
        .{ .body = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"unknown\"}}\n\n", .expected = error.UnsupportedProviderContent },
        .{ .body = "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n", .expected = error.IncompleteStream },
    };
    for (cases) |case| {
        var reader: std.Io.Reader = .fixed(case.body);
        try std.testing.expectError(case.expected, consume(std.testing.allocator, &reader, fake.request(.host_managed), null));
    }
}

test "Anthropic thinking signatures replay and cache usage survives message delta" {
    const alloc = std.testing.allocator;
    const Fake = @import("host_transport_testing.zig").FakeTransport;
    const types = @import("../core/shared/types.zig");
    var fake = Fake{ .responses = &.{} };
    defer fake.deinit();
    const body =
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":64,\"output_tokens\":0,\"cache_read_input_tokens\":128,\"cache_creation_input_tokens\":32}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Inspect carefully\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"opaque-signed\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"reply\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    var reader: std.Io.Reader = .fixed(body);
    var result = try consume(alloc, &reader, fake.request(.host_managed), null);
    defer result.deinit(alloc);
    const completion = result.completed.completion;
    try std.testing.expectEqual(@as(?u64, 224), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 7), completion.usage.output_tokens);
    try std.testing.expectEqual(@as(?u64, 128), completion.usage.cache_read_tokens);
    try std.testing.expectEqual(@as(?u64, 32), completion.usage.cache_write_tokens);
    const messages = [_]types.ChatMessage{.{ .role = .assistant, .content = "reply", .provider_replay = .{
        .source = .{ .provider = .codex, .model = "test" },
        .parts_json = completion.provider_state_json.?,
    } }};
    const next = try buildFor(alloc, .{ .model = "test", .messages = &messages, .instructions = &.{}, .provider_options = .{}, .tool_choice = .auto }, .codex);
    defer alloc.free(next);
    const valid = try std.json.parseFromSlice(std.json.Value, alloc, next, .{});
    defer valid.deinit();
    try std.testing.expect(std.mem.find(u8, next, "\"thinking\":\"Inspect carefully\",\"signature\":\"opaque-signed\"") != null);
}

test "Anthropic content block indices map to contiguous tool ordinals" {
    const alloc = std.testing.allocator;
    const Fake = @import("host_transport_testing.zig").FakeTransport;
    var fake = Fake{ .responses = &.{} };
    defer fake.deinit();
    var request = fake.request(.host_managed);
    request.tools = .{ .advertised_names = &.{"lookup"}, .advertised_functions = &.{.{ .name = "lookup", .description = "Lookup" }} };
    const body =
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"Checking\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_lookup\",\"name\":\"lookup\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":7}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    var reader: std.Io.Reader = .fixed(body);
    var result = try consume(alloc, &reader, request, null);
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), result.completed.completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_lookup", result.completed.completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("{}", result.completed.completion.tool_calls[0].arguments_json);
}

test "deferred Messages native and callAction preserve saved schemas after repeated search" {
    const alloc = std.testing.allocator;
    const types = @import("../core/shared/types.zig");
    const saved = "[{\"name\":\"action\",\"description\":\"old\",\"inputSchema\":{}},{\"name\":\"removed\",\"description\":\"removed\",\"inputSchema\":{}}]";
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "s1", .name = "tool_search", .arguments_json = "{}" }} },
        .{ .role = .tool, .tool_call_id = "s1", .tool_name = "tool_search", .content = "Search results", .tool_result_memory = .{ .loaded_tools_json = saved } },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "s2", .name = "tool_search", .arguments_json = "{}" }} },
        .{ .role = .tool, .tool_call_id = "s2", .tool_name = "tool_search", .content = "Search results", .tool_result_memory = .{ .loaded_tools_json = saved } },
    };
    const schema = try std.json.parseFromSlice(std.json.Value, alloc, "{\"type\":\"object\",\"required\":[\"updated\"]}", .{});
    defer schema.deinit();
    var request: streams.RequestData = .{ .model = "claude-test", .instructions = &.{}, .messages = &messages, .tool_choice = .auto, .provider_options = .{}, .tools = .{ .selected_dynamic = &.{.{ .name = "action", .description = "current", .input_schema = schema.value, .deferred = true }} } };
    for ([_]@import("../core/config/configured_provider.zig").DeferredToolMode{ .native, .call_action }) |mode| {
        const body = try buildConfigured(alloc, request, null, mode);
        defer alloc.free(body);
        try std.testing.expect(std.mem.find(u8, body, "updated") == null);
        try std.testing.expect(std.mem.find(u8, body, "removed") != null);
        try std.testing.expect(std.mem.find(u8, body, "old") != null);
        if (mode == .native) try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "\"type\":\"tool_addition\""));
    }
    request.tools.selected_dynamic = &.{};
    for ([_]@import("../core/config/configured_provider.zig").DeferredToolMode{ .native, .call_action }) |mode| {
        const body = try buildConfigured(alloc, request, null, mode);
        defer alloc.free(body);
        try std.testing.expect(std.mem.find(u8, body, "action") != null);
        try std.testing.expect(std.mem.find(u8, body, "removed") != null);
    }
}
