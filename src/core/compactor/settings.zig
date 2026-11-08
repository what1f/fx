//! The `auto_compact_percent` setting and the `FX_AUTO_COMPACT_TOKENS`
//! override: how full a request gets before fx-compactor runs on its own.

const std = @import("std");

/// The point at which automatic compaction starts: a share of the model's
/// usable input, or a token count that never passes the usable input itself.
pub const Trigger = union(enum) {
    percent: u8,
    tokens: usize,

    /// A token count wins over the percent when one is set.
    pub fn of(percent: u8, tokens: ?usize) Trigger {
        return if (tokens) |count| .{ .tokens = count } else .{ .percent = percent };
    }
};

/// Parses `FX_AUTO_COMPACT_TOKENS`, a positive token count. Anything else is
/// ignored.
pub fn parseTokens(raw: ?[]const u8) ?usize {
    const trimmed = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    const value = std.fmt.parseUnsigned(usize, trimmed, 10) catch return null;
    return if (value == 0) null else value;
}

/// Automatic compaction starts once a request reaches this share of the
/// model's usable input window.
pub const default_percent: u8 = 80;
pub const min_percent: u8 = 10;
pub const max_percent: u8 = 80;

pub fn isValidPercent(value: u64) bool {
    return value >= min_percent and value <= max_percent;
}

/// Parses a process override. Invalid or out-of-range values are ignored.
pub fn parsePercent(raw: ?[]const u8) ?u8 {
    const trimmed = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    if (trimmed.len == 0) return null;
    const value = std.fmt.parseUnsigned(u8, trimmed, 10) catch return null;
    return if (isValidPercent(value)) value else null;
}

pub fn resolvePercent(configured: ?u8, process_override: ?[]const u8) u8 {
    return parsePercent(process_override) orelse configured orelse default_percent;
}

test "auto compaction percent accepts only the supported range" {
    try std.testing.expect(!isValidPercent(9));
    try std.testing.expect(isValidPercent(10));
    try std.testing.expect(isValidPercent(80));
    try std.testing.expect(!isValidPercent(81));
    try std.testing.expectEqual(@as(?u8, 50), parsePercent(" 50\n"));
    try std.testing.expectEqual(@as(?u8, null), parsePercent("5"));
    try std.testing.expectEqual(@as(?u8, null), parsePercent("90"));
    try std.testing.expectEqual(@as(?u8, null), parsePercent("half"));
    try std.testing.expectEqual(@as(?u8, null), parsePercent(""));
}

test "auto compaction percent resolves override, then setting, then default" {
    try std.testing.expectEqual(default_percent, resolvePercent(null, null));
    try std.testing.expectEqual(@as(u8, 40), resolvePercent(40, null));
    try std.testing.expectEqual(@as(u8, 25), resolvePercent(40, "25"));
    try std.testing.expectEqual(@as(u8, 40), resolvePercent(40, "95"));
}

test "auto compaction tokens accept only a positive count and win over the percent" {
    try std.testing.expectEqual(@as(?usize, 167_000), parseTokens(" 167000\n"));
    try std.testing.expectEqual(@as(?usize, null), parseTokens("0"));
    try std.testing.expectEqual(@as(?usize, null), parseTokens("-5"));
    try std.testing.expectEqual(@as(?usize, null), parseTokens("lots"));
    try std.testing.expectEqual(@as(?usize, null), parseTokens(""));
    try std.testing.expectEqual(@as(?usize, null), parseTokens(null));
    try std.testing.expectEqual(Trigger{ .percent = 40 }, Trigger.of(40, null));
    try std.testing.expectEqual(Trigger{ .tokens = 9000 }, Trigger.of(40, 9000));
}
