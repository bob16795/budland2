const std = @import("std");

const Config = @This();

allocator: std.mem.Allocator,
tags: std.ArrayList([]const u8),
colors: [2][3][4]f32,

pub fn sourcePath(self: *Config, path: []const u8) !void {
    _ = self;
    _ = path;
}

pub fn budlandLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@import("builtin").is_test) {
        return;
    }

    const scope_prefix = "(" ++ switch (scope) {
        std.log.default_log_scope => "Budland",
        .SandEEE, .Steam => @tagName(scope),
        else => if (@intFromEnum(level) <= @intFromEnum(std.log.Level.warn))
            @tagName(scope)
        else
            return,
    } ++ "): ";

    const prefix = "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;

    const color = switch (level) {
        .err => "\x1b[1;91m",
        .warn => "\x1b[1;33m",
        .info => "\x1b[1;37m",
        .debug => "\x1b[0;37m",
    };

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    // Print the message to stderr, silently ignoring any errors
    if (@import("builtin").mode == .Debug) {
        const stderr = std.io.getStdErr().writer();
        nosuspend stderr.print(prefix ++ color ++ format ++ "\x1b[m\n", args) catch return;
    }
}
