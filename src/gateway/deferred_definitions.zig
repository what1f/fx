//! Request-local projection of saved discovery results onto the current catalog.
const std = @import("std");
const streams = @import("../core/agent/stream_provider.zig");

pub const Projection = struct {
    seen: std.StringHashMap(void),

    pub fn init(alloc: std.mem.Allocator) Projection {
        return .{ .seen = .init(alloc) };
    }

    pub fn deinit(self: *Projection) void {
        var keys = self.seen.keyIterator();
        while (keys.next()) |key| self.seen.allocator.free(key.*);
        self.seen.deinit();
    }

    /// Caller owns the JSON array. A null catalog preserves low-level replay;
    /// production callers supply the current catalog, including an empty one.
    pub fn project(self: *Projection, alloc: std.mem.Allocator, definitions: []const u8, current: ?[]const streams.DynamicFunctionTool) ![]u8 {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, definitions, .{});
        defer parsed.deinit();
        if (parsed.value != .array) return error.InvalidProviderState;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeByte('[');
        var count: usize = 0;
        for (parsed.value.array.items) |entry| {
            if (entry != .object) return error.InvalidProviderState;
            const name_value = entry.object.get("name") orelse return error.InvalidProviderState;
            if (name_value != .string) return error.InvalidProviderState;
            const name = name_value.string;
            var selected: ?streams.DynamicFunctionTool = null;
            if (current) |tools| {
                // Catalog updates replace earlier entries by name.
                for (tools) |tool| if (std.mem.eql(u8, tool.name, name)) {
                    selected = tool;
                };
                if (selected == null or !selected.?.deferred) continue;
            }
            if (self.seen.contains(name)) continue;
            const owned_name = try self.seen.allocator.dupe(u8, name);
            self.seen.put(owned_name, {}) catch |err| {
                self.seen.allocator.free(owned_name);
                return err;
            };
            if (count > 0) try out.writer.writeByte(',');
            count += 1;
            if (selected) |tool| {
                try std.json.Stringify.value(.{ .name = tool.name, .description = tool.description, .inputSchema = tool.input_schema, .deferred = true }, .{}, &out.writer);
            } else {
                try std.json.Stringify.value(entry, .{}, &out.writer);
            }
        }
        try out.writer.writeByte(']');
        return out.toOwnedSlice();
    }
};

test "deferred projection uses current schemas once and drops removed definitions" {
    const alloc = std.testing.allocator;
    var projection = Projection.init(alloc);
    defer projection.deinit();
    const old = "[{\"name\":\"action\",\"description\":\"old\"},{\"name\":\"removed\"},{\"name\":\"action\"}]";
    const tools = [_]streams.DynamicFunctionTool{.{ .name = "action", .description = "current", .input_schema = .{ .object = .empty }, .deferred = true }};
    const first = try projection.project(alloc, old, &tools);
    defer alloc.free(first);
    const second = try projection.project(alloc, old, &tools);
    defer alloc.free(second);
    try std.testing.expectEqualStrings("[{\"name\":\"action\",\"description\":\"current\",\"inputSchema\":{},\"deferred\":true}]", first);
    try std.testing.expectEqualStrings("[]", second);
}
