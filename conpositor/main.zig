const std = @import("std");
const builtin = @import("builtin");

const Session = @import("session.zig");
const Config = @import("config.zig");

pub const std_options = std.Options{
    // I wanna share loggers with wayland
    .logFn = Config.conpositorLogFn,
};

// The only errors this program can return
const ConpositorError = Session.SessionError ||
    Config.ConfigError;

pub fn main() ConpositorError!void {
    defer Config.allocator_data.deinit();

    var session: Session = try .init();
    defer session.deinit();

    try session.attachEvents();

    try session.launch();
}
