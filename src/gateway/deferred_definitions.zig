//! Native declarations use the first saved definition of each name.
const std = @import("std");

pub const Declarations = struct {
    seen: std.StringHashMap(void),

    pub fn init(alloc: std.mem.Allocator) Declarations {
        return .{ .seen = .init(alloc) };
    }

    pub fn deinit(self: *Declarations) void {
        var keys = self.seen.keyIterator();
        while (keys.next()) |key| self.seen.allocator.free(key.*);
        self.seen.deinit();
    }

    /// Caller owns the array. Never substitutes live schemas into saved history.
    pub fn first(self: *Declarations, alloc: std.mem.Allocator, definitions: []const u8) ![]u8 {
        const saved = try snapshot(alloc, definitions);
        defer alloc.free(saved);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, saved, .{});
        defer parsed.deinit();
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeByte('[');
        var count: usize = 0;
        for (parsed.value.array.items) |entry| {
            const name = entry.object.get("name").?.string;
            if (self.seen.contains(name)) continue;
            const owned = try self.seen.allocator.dupe(u8, name);
            self.seen.put(owned, {}) catch |err| {
                self.seen.allocator.free(owned);
                return err;
            };
            if (count > 0) try out.writer.writeByte(',');
            try std.json.Stringify.value(entry, .{}, &out.writer);
            count += 1;
        }
        try out.writer.writeByte(']');
        return out.toOwnedSlice();
    }
};

/// Execution uses the live catalog; serialization can only read saved definitions.
pub fn snapshot(alloc: std.mem.Allocator, definitions: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, definitions, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidProviderState;
    for (parsed.value.array.items) |entry| {
        if (entry != .object) return error.InvalidProviderState;
        const name = entry.object.get("name") orelse return error.InvalidProviderState;
        if (name != .string) return error.InvalidProviderState;
    }
    return alloc.dupe(u8, definitions);
}

test "deferred snapshots survive catalog replacement removal and later searches" {
    const alloc = std.testing.allocator;
    const old = "[{\"name\":\"action\",\"description\":\"old\"},{\"name\":\"removed\"}]";
    const current = "[{\"name\":\"action\",\"description\":\"new\"}]";
    const first = try snapshot(alloc, old);
    defer alloc.free(first);
    const second = try snapshot(alloc, current);
    defer alloc.free(second);
    const repeated = try snapshot(alloc, old);
    defer alloc.free(repeated);
    try std.testing.expectEqualStrings(old, first);
    try std.testing.expectEqualStrings(current, second);
    try std.testing.expectEqualStrings(old, repeated);
}

test "deferred declarations keep first snapshots across overlap and replacement" {
    const alloc = std.testing.allocator;
    var declarations = Declarations.init(alloc);
    defer declarations.deinit();
    const first = try declarations.first(alloc, "[{\"name\":\"a\",\"description\":\"old\"},{\"name\":\"a\"}]");
    defer alloc.free(first);
    try std.testing.expectEqualStrings("[{\"name\":\"a\",\"description\":\"old\"}]", first);
    const overlap = try declarations.first(alloc, "[{\"name\":\"a\",\"description\":\"new\"},{\"name\":\"b\"}]");
    defer alloc.free(overlap);
    try std.testing.expectEqualStrings("[{\"name\":\"b\"}]", overlap);
    const repeated = try declarations.first(alloc, "[{\"name\":\"b\"},{\"name\":\"a\"}]");
    defer alloc.free(repeated);
    try std.testing.expectEqualStrings("[]", repeated);
}
