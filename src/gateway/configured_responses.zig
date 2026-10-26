//! Public Responses transport for configured endpoints. Shares the existing
//! Responses serializer and bounded stream reducer with the subscription adapter.
const std = @import("std");
const streams = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const model_provider = @import("../core/config/model_provider.zig");
const protocol = @import("responses_protocol.zig");

/// Caller owns the returned request body. Credentials stay at the transport edge.
pub fn build(alloc: std.mem.Allocator, request: streams.RequestData, provider: model_provider.ProviderId) ![]u8 {
    try request.validatePrompt();
    const projected = try types.projectProviderReplay(alloc, request.messages, .{ .provider = provider, .model = request.model });
    defer if (projected) |messages| alloc.free(messages);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, w);
    try w.writeAll(",\"stream\":true,\"store\":false,\"instructions\":");
    var instructions: std.Io.Writer.Allocating = .init(alloc);
    defer instructions.deinit();
    for (request.instructions) |message| {
        if (instructions.written().len > 0) try instructions.writer.writeAll("\n\n");
        try instructions.writer.writeAll(message.content orelse "");
    }
    try std.json.Stringify.value(instructions.written(), .{}, w);
    try w.writeAll(",\"input\":[");
    try protocol.writeInput(w, alloc, projected orelse request.messages, request.verified_images, .{
        .tool_calls = 64,
        .tool_identity_bytes = 1024,
        .tool_arguments_bytes = 1024 * 1024,
        .provider_state_bytes = types.ProviderReplay.max_bytes,
    }, if (request.budget) |budget| .{ .deadline = budget.deadline, .cancel_flag = budget.cancel_flag } else .{});
    try w.writeByte(']');
    _ = try protocol.writeTools(w, alloc, request.tools);
    try w.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(request.tool_choice.label(), .{}, w);
    if (request.max_output_tokens) |limit| try w.print(",\"max_output_tokens\":{d}", .{limit});
    if (request.provider_options.reasoning) |effort| {
        try w.writeAll(",\"reasoning\":{\"effort\":");
        try std.json.Stringify.value(effort.label(), .{}, w);
        try w.writeByte('}');
    }
    if (request.response_format) |format| {
        if (format.schema != .object) return error.InvalidStructuredResponseSchema;
        try w.writeAll(",\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":");
        try std.json.Stringify.value(format.name, .{}, w);
        try w.writeAll(",\"schema\":");
        try std.json.Stringify.value(format.schema, .{}, w);
        try w.writeAll(",\"strict\":true}}");
    }
    try w.writeByte('}');
    return out.toOwnedSlice();
}

pub const consume = @import("openai_codex.zig").completeFromStream;

test "configured protocols serialize effort and omit unset effort" {
    const alloc = std.testing.allocator;
    const cc = @import("chat_completions_protocol.zig");
    const anthropic = @import("anthropic_protocol.zig");
    for ([_]?types.ReasoningEffort{ null, .literal("none"), .literal("low"), .literal("medium"), .literal("high"), .literal("xhigh"), .literal("max") }) |effort| {
        const request: streams.RequestData = .{
            .model = "model",
            .instructions = &.{.{ .role = .system, .content = "Stable instructions" }},
            .messages = &.{.{ .role = .user, .content = "hello" }},
            .tools = .{},
            .tool_choice = .auto,
            .provider_options = .{ .reasoning = effort },
        };
        const bodies = [_][]u8{ try cc.build_request(alloc, request, .{}), try build(alloc, request, .gateway), try anthropic.build(alloc, request) };
        defer for (bodies) |body| alloc.free(body);
        for (bodies, 0..) |body, index| {
            const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
            defer parsed.deinit();
            const fields = parsed.value.object;
            if (effort) |value| {
                if (index == 0) try std.testing.expectEqualStrings(value.label(), fields.get("reasoning_effort").?.string);
                if (index == 1) try std.testing.expectEqualStrings(value.label(), fields.get("reasoning").?.object.get("effort").?.string);
                if (index == 2) {
                    const disabled = std.mem.eql(u8, value.label(), "none");
                    try std.testing.expectEqualStrings(if (disabled) "disabled" else "adaptive", fields.get("thinking").?.object.get("type").?.string);
                    if (disabled) try std.testing.expect(!fields.contains("output_config")) else try std.testing.expectEqualStrings(value.label(), fields.get("output_config").?.object.get("effort").?.string);
                }
            } else {
                for ([_][]const u8{ "reasoning_effort", "reasoning", "thinking", "output_config" }) |key| try std.testing.expect(!fields.contains(key));
            }
        }
    }
}
