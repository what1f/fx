//! Session-owned Messages negotiation. A failed retry never changes the saved mode.
pub const Mode = enum {
    native,
    reference,
    call_tool,

    pub fn next(self: Mode) ?Mode {
        return switch (self) {
            .native => .reference,
            .reference => .call_tool,
            .call_tool => null,
        };
    }
};

/// Session-owned persistence, called only after a successful mode change.
pub const Commit = struct {
    context: *anyopaque,
    save_fn: *const fn (*anyopaque, Mode) anyerror!void,

    pub fn save(self: Commit, mode: Mode) !void {
        try self.save_fn(self.context, mode);
    }
};
