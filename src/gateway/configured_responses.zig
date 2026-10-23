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
