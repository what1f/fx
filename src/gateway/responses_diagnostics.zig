const std = @import("std");
const io_mod = @import("../core/shared/io.zig");

// Opt-in metadata only. Do not route SSE payloads or HTTP headers here.
fn enabled() bool {
    if (@import("builtin").is_test) return false;
    return std.mem.eql(u8, io_mod.getenv("FX_RESPONSES_DIAGNOSTICS") orelse "", "1");
}

pub fn record(alloc: std.mem.Allocator, value: anytype) void {
    if (!enabled()) return;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll("[responses-metadata] ") catch return;
    std.json.Stringify.value(value, .{}, &out.writer) catch return;
    out.writer.writeByte('\n') catch return;
    std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), out.written()) catch {};
}

pub fn event(alloc: std.mem.Allocator, stream: usize, sequence: usize, fields: std.json.ObjectMap) void {
    if (!enabled()) return;
    item(alloc, stream, sequence, fields, fields, null, null);
    if (fields.get("item")) |value| if (value == .object) {
        item(alloc, stream, sequence, fields, value.object, null, null);
    };
    if (fields.get("part")) |value| if (value == .object) {
        item(alloc, stream, sequence, fields, value.object, null, null);
    };
    if (fields.get("response")) |response| if (response == .object) {
        if (response.object.get("output")) |output| if (output == .array) {
            for (output.array.items, 0..) |value, output_index| if (value == .object) {
                item(alloc, stream, sequence, fields, value.object, output_index, null);
            };
        };
    };
}

fn string(fields: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = fields.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn index(fields: std.json.ObjectMap, key: []const u8) ?usize {
    const value = fields.get(key) orelse return null;
    return if (value == .integer) std.math.cast(usize, value.integer) else null;
}

fn item(alloc: std.mem.Allocator, stream: usize, sequence: usize, event_fields: std.json.ObjectMap, fields: std.json.ObjectMap, output: ?usize, content: ?usize) void {
    const text = string(fields, "delta") orelse string(fields, "text") orelse string(fields, "refusal");
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    if (text) |bytes| std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    record(alloc, .{
        .stream = stream,
        .sequence = sequence,
        .event = string(event_fields, "type"),
        .output_index = output orelse index(event_fields, "output_index"),
        .content_index = content orelse index(event_fields, "content_index"),
        .item_id = string(fields, "id") orelse string(event_fields, "item_id"),
        .kind = string(fields, "type"),
        .phase = string(fields, "phase"),
        .bytes = if (text) |bytes| @as(?usize, bytes.len) else null,
        .sha256 = if (text != null) std.fmt.bytesToHex(hash, .lower) else null,
    });
    if (fields.get("content")) |parts| if (parts == .array) {
        for (parts.array.items, 0..) |part, part_index| if (part == .object) {
            item(alloc, stream, sequence, event_fields, part.object, output, part_index);
        };
    };
}
