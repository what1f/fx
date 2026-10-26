//! Saved discovery results are immutable model-visible snapshots.
const std = @import("std");

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
