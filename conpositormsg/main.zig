const std = @import("std");
const wl = @import("wayland").client.wl;
const conpositor = @import("wayland").client.conpositor;

// Inspired by https://github.com/riverwm/river/blob/master/riverctl/main.zig

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
const allocator = gpa.allocator();

pub const Globals = struct {
    manager: ?*conpositor.IpcManagerV1 = null,
    seat: ?*wl.Seat = null,
};

var command: []const u8 = "";

pub fn main() !void {
    var idx: usize = 1;
    if (std.os.argv.len <= 1)
        return error.MissingParams;

    command = std.mem.span(std.os.argv[idx]);
    idx += 1;

    const display = try wl.Display.connect(null);
    const registry = try display.getRegistry();

    var globals = Globals{};

    registry.setListener(*Globals, registryListener, &globals);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const manager = globals.manager orelse return error.ConpositorIpcManagerNotAdvertised;
    const session = try manager.getSession();

    if (std.mem.eql(u8, command, "run")) {
        var run_command: std.ArrayList(u8) = .init(allocator);
        defer run_command.deinit();

        while (idx < std.os.argv.len) : (idx += 1) {
            if (idx != 1)
                try run_command.appendSlice(" ");
            try run_command.appendSlice(std.mem.span(std.os.argv[idx]));
        }
        const new_command = try allocator.dupeZ(u8, run_command.items);

        const handle = try session.runCommand(new_command);
        handle.setListener(?*anyopaque, commandListener, null);
    } else {
        const output = try session.getFocusedOutput();
        output.setListener(?*anyopaque, outputListener, null);
    }

    while (true) {
        if (display.dispatch() != .SUCCESS) return error.FailedToSend;
    }
}

var statusData: struct {
    focus: ?struct {
        label: [*:0]const u8,
        appid: [*:0]const u8,
        icon: [*:0]const u8,
        title: [*:0]const u8,
    } = null,
    tags: [][*:0]const u8 = &.{},
    layout: ?[*:0]const u8 = null,
    activeTag: [*:0]const u8 = "",
    changed: packed struct {
        focus: bool = false,
        tags: bool = false,
        layout: bool = false,
        activeTag: bool = false,
    } = .{},
} = .{};

fn writeOutput() !void {
    const stdout = std.io.getStdOut().writer();
    defer statusData.changed = .{};

    if (std.mem.eql(u8, command, "status")) {
        if (statusData.focus) |focus| {
            try stdout.print("focused:\n", .{});
            try stdout.print("  label: {s}\n", .{focus.label});
            try stdout.print("  appid: {s}\n", .{focus.appid});
            try stdout.print("  icon:  {s}\n", .{focus.icon});
            try stdout.print("  title: {s}\n", .{focus.title});
        }

        try stdout.print("tags:\n", .{});
        try stdout.print("  count: {}\n", .{statusData.tags.len});
        try stdout.print("  active: {s}\n", .{statusData.activeTag});
        for (statusData.tags, 0..) |tag_name, idx| {
            try stdout.print("  names[{}]: {s}\n", .{ idx, tag_name });
        }

        if (statusData.layout) |layout|
            try stdout.print("layout: {s}\n", .{layout});
    } else if (std.mem.eql(u8, command, "layout")) {
        if (!statusData.changed.layout)
            return;

        if (statusData.layout) |layout|
            try stdout.print("{s}\n", .{layout});
    } else if (std.mem.eql(u8, command, "icon")) {
        if (!statusData.changed.focus)
            return;

        if (statusData.focus) |focus| {
            try stdout.print("{s}\n", .{focus.icon});
        } else {
            try stdout.print("\n", .{});
        }
    } else if (std.mem.eql(u8, command, "label")) {
        if (!statusData.changed.focus)
            return;

        if (statusData.focus) |focus| {
            try stdout.print("{s}\n", .{focus.label});
        } else {
            try stdout.print("Desktop\n", .{});
        }
    } else if (std.mem.eql(u8, command, "tag")) {
        if (!statusData.changed.tags and !statusData.changed.activeTag)
            return;

        try stdout.print("{s}\n", .{statusData.activeTag});
    } else {
        const stderr = std.io.getStdErr().writer();

        try stderr.print("missing command\n", .{});
    }
}

fn outputListener(_: *conpositor.IpcOutputV1, event: conpositor.IpcOutputV1.Event, _: ?*anyopaque) void {
    switch (event) {
        .frame => {
            writeOutput() catch @panic("stdout write failed");
        },
        .tags => |tags| {
            statusData.tags = allocator.alloc([*:0]const u8, tags.amount) catch &.{};
        },
        .toggle_visibility => {},
        .active => {},
        .tag => |tag| {
            statusData.tags[@intCast(tag.tag)] = tag.name;
            if (tag.state == .active) {
                statusData.activeTag = tag.name;

                statusData.changed.activeTag = true;
            }

            statusData.changed.tags = true;
        },
        .layout => |layout| {
            statusData.layout = layout.name;

            statusData.changed.layout = true;
        },
        .clear_focus => {
            statusData.focus = null;

            statusData.changed.focus = true;
        },
        .focus => |focus| {
            statusData.focus = .{
                .label = focus.label,
                .appid = focus.appid,
                .icon = focus.icon,
                .title = focus.title,
            };

            statusData.changed.focus = true;
        },
        // else => std.log.info("event {}", .{event}),
    }
}

fn commandListener(_: *conpositor.CommandOutputV1, event: conpositor.CommandOutputV1.Event, _: ?*anyopaque) void {
    switch (event) {
        .success => |req| {
            const stdout = std.io.getStdOut().writer();

            stdout.print("{s}\n", .{req.output}) catch {};

            std.posix.exit(0);
        },
        .fail => |req| {
            const stderr = std.io.getStdErr().writer();

            stderr.print("{s}\n", .{req.reason}) catch {};

            std.posix.exit(1);
        },
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                std.debug.assert(globals.seat == null); // TODO: support multiple seats
                globals.seat = registry.bind(global.name, wl.Seat, 1) catch @panic("out of memory");
            } else if (std.mem.orderZ(u8, global.interface, conpositor.IpcManagerV1.interface.name) == .eq) {
                globals.manager = registry.bind(global.name, conpositor.IpcManagerV1, 1) catch @panic("out of memory");
            }
        },
        .global_remove => {},
    }
}
