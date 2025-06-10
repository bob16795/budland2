const std = @import("std");
const builtin = @import("builtin");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Session = @import("session.zig");
const Config = @import("config.zig");
const Monitor = @import("monitor.zig");
const Client = @import("client.zig");
const Input = @import("input.zig");

const BudlandError = error{
    XdgError,
} || Session.SessionError;

pub const std_options = std.Options{
    // Define logFn to override the std implementation
    .logFn = Config.budlandLogFn,
    .log_level = .debug,
};

pub fn main() BudlandError!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 10 }){};
    const allocator = gpa.allocator();

    defer if (gpa.deinit() == .ok)
        std.log.debug("no leaks! :)", .{});

    if (std.posix.getenv("XDG_RUNTIME_DIR") == null)
        return error.XdgError;

    var config: Config = .{
        .allocator = allocator,
        .tags = std.ArrayList([]const u8).init(allocator),
        .colors = .{
            .{ .{ 1, 0, 0, 1 }, .{ 1, 0, 0, 1 }, .{ 1, 0, 0, 1 } },
            .{ .{ 1, 0, 0, 1 }, .{ 1, 0, 0, 1 }, .{ 1, 0, 0, 1 } },
        },
    };
    try config.sourcePath(".config/budland/budland.conf");

    var session: Session = .{
        .config = &config,
        .monitors = .init(allocator),
        .clients = .init(allocator),
        .fstack = .init(allocator),
        .surfaces = .init(allocator),
    };
    try session.init();

    try session.launch();
}
