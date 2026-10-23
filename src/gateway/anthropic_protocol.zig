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
    const encoded = try cc.build_request(alloc, request, .{});
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
    try w.writeAll("],\"tools\":[");
    var count: usize = 0;
    var deferred = false;
    if (parsed.value.object.get("tools")) |tools| for (tools.array.items) |entry| {
        const f = entry.object.get("function").?;
        const name = f.object.get("name").?.string;
        if (std.mem.eql(u8, name, "call_action")) continue;
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
    if (deferred) {
        if (count > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":\"__fx_deferred_placeholder__\",\"description\":\"Reserved. Never call.\",\"input_schema\":{\"type\":\"object\",\"properties\":{}},\"defer_loading\":true}");
    }
    try w.writeAll("],\"messages\":[");
    count = 0;
    for (request.messages, 0..) |message, message_index| {
        if (message.images.len > 0 or message.provider_replay != null) return error.UnsupportedProviderContent;
        if (message.tool_result_memory) |memory| if (memory.tool_images.len > 0) return error.UnsupportedProviderContent;
        if (count > 0) try w.writeByte(',');
        count += 1;
        try w.writeAll("{\"role\":");
        try json(w, if (message.role == .assistant) "assistant" else "user");
        try w.writeAll(",\"content\":[");
        var blocks: usize = 0;
        if (message.role == .tool) {
            try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
            try json(w, message.tool_call_id orelse "");
            try w.writeAll(",\"content\":");
            try json(w, message.content orelse "");
            if (message.tool_result_status == .failure) try w.writeAll(",\"is_error\":true");
            try w.writeByte('}');
            blocks += 1;
        } else if (message.content) |text| if (text.len > 0) {
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
        if (message.role != .tool or (message_index + 1 < request.messages.len and request.messages[message_index + 1].role == .tool)) continue;
        var group_start = message_index;
        while (group_start > 0 and request.messages[group_start - 1].role == .tool) group_start -= 1;
        for (request.messages[group_start .. message_index + 1]) |result| if (result.tool_result_memory) |memory| if (memory.loaded_tools_json) |definitions| {
            const loaded = try std.json.parseFromSlice(std.json.Value, alloc, definitions, .{});
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
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
};
const Event = struct {
    type: []const u8,
    index: ?usize = null,
    content_block: ?struct {
        type: []const u8,
        id: ?[]const u8 = null,
        name: ?[]const u8 = null,
        text: ?[]const u8 = null,
    } = null,
    delta: ?struct {
        type: ?[]const u8 = null,
        text: ?[]const u8 = null,
        partial_json: ?[]const u8 = null,
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
    var tools: [256]bool = @splat(false);
    var arguments: [256]bool = @splat(false);
    while (try framing.next(alloc, source, request.cancel_flag)) |bytes| {
        const parsed = std.json.parseFromSlice(Event, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidEvent;
        defer parsed.deinit();
        const event = parsed.value;
        const kind = event.type;
        if (std.mem.eql(u8, kind, "error")) return error.ProviderError;
        if (std.mem.eql(u8, kind, "message_stop")) {
            if (!finished) return error.IncompleteStream;
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
                try w.print("\"tool_calls\":[{{\"index\":{d},\"id\":", .{index});
                try json(w, block.id orelse return error.InvalidEvent);
                try w.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                try json(w, block.name orelse return error.InvalidEvent);
                try w.writeAll(",\"arguments\":\"\"}}]");
            } else if (std.mem.eql(u8, block.type, "text")) {
                try w.writeAll("\"content\":");
                try json(w, block.text orelse "");
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
                try w.print("\"tool_calls\":[{{\"index\":{d},\"function\":{{\"arguments\":", .{index});
                try json(w, partial);
                try w.writeAll("}}]");
            } else return error.UnsupportedProviderContent;
        } else if (std.mem.eql(u8, kind, "content_block_stop")) {
            const index = event.index orelse return error.InvalidEvent;
            if (tools[index] and !arguments[index]) {
                try w.print("\"tool_calls\":[{{\"index\":{d},\"function\":{{\"arguments\":\"{{}}\"}}}}]", .{index});
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
            if (value.input_tokens) |input| try w.print("\"prompt_tokens\":{d},", .{input +| value.cache_read_input_tokens +| value.cache_creation_input_tokens});
            try w.writeAll("\"completion_tokens\":");
            try json(w, value.output_tokens);
            try w.writeByte('}');
        }
        try w.writeByte('}');
        const deltas = try reducer.accept(out.written(), request.cancel_flag.load(.seq_cst));
        if (deltas.content) |text| request.events.emit(.{ .content_delta = text });
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
}
