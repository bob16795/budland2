const std = @import("std");
const builtin = @import("builtin");

const Session = @import("session.zig");
const Config = @import("config.zig");

pub const std_options = std.Options{
    // Define logFn to override the std implementation
    .logFn = Config.budlandLogFn,
    .log_level = .debug,
};

// allocator time bay-bee
var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
const allocator = gpa.allocator();

// The only errors this program can return
const BudlandError = Session.SessionError || Config.ConfigError;

pub fn main() BudlandError!void {
    // just a leak check for debugging
    defer if (gpa.deinit() == .ok)
        std.log.debug("no leaks! :)", .{});

    var config: Config = .init(allocator);
    defer config.deinit();

    var session: Session = .init(&config);
    defer session.deinit();

    try session.launch();
}
