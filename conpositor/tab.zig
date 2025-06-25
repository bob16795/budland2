const cairo = @import("cairo");
const wlr = @import("wlroots");
const std = @import("std");

const Config = @import("config.zig");
const Session = @import("session.zig");
const Client = @import("client.zig");

const Tab = @This();

const allocator = Config.allocator;

left_modules: std.ArrayList(Config.LuaModule) = .init(allocator),
center_modules: std.ArrayList(Config.LuaModule) = .init(allocator),
right_modules: std.ArrayList(Config.LuaModule) = .init(allocator),

pub fn getText(
    self: *Tab,
    part: enum { left, center, right },
) ![:0]const u8 {
    const mods = switch (part) {
        .left => self.left_modules,
        .center => self.center_modules,
        .right => self.right_modules,
    };

    var result: std.ArrayList(u8) = .init(allocator);
    defer result.deinit();

    const client: *Client = @fieldParentPtr("tab", self);
    for (mods.items) |*mod| {
        const mod_text = try mod.getText(client);
        defer allocator.free(mod_text);

        if (result.items.len != 0)
            try result.appendSlice(" ");

        try result.appendSlice(mod_text);
    }

    return try allocator.dupeZ(u8, result.items);
}

pub fn draw(
    self: *Tab,
    session: *Session,
    context: *cairo.Context,
    surf_bounds: wlr.Box,
) !void {
    context.save();
    defer context.restore();

    const config = &session.config;

    const font = config.getFont();
    const title_pad = config.getTitlePad();

    const pc_pad = 30.0 / @as(f64, @floatFromInt(surf_bounds.width));

    const client: *Client = @fieldParentPtr("tab", self);

    const active = session.focusedClient() == client;

    const fg = config.getColor(active, .foreground);
    const bg = config.getColor(active, .background);
    const border = config.getColor(active, .border);

    const left_text = try self.getText(.left);
    defer allocator.free(left_text);
    const center_text = try self.getText(.center);
    defer allocator.free(center_text);
    const right_text = try self.getText(.right);
    defer allocator.free(right_text);

    const left_extents = context.textExtents(@ptrCast(left_text));
    const center_extents = context.textExtents(@ptrCast(center_text));
    const right_extents = context.textExtents(@ptrCast(right_text));

    const left_total = left_extents.width / @as(f64, @floatFromInt(surf_bounds.width));
    const center_total = center_extents.width / @as(f64, @floatFromInt(surf_bounds.width));
    const right_total = right_extents.width / @as(f64, @floatFromInt(surf_bounds.width));

    const right_start = @max(1.0 - right_total, 0.0); // right start cant be more than 0
    const left_end = @min(left_total, right_start - pc_pad, 1.0); // no left over right

    const center_start = @max(left_end + pc_pad, 0.5 - center_total * 0.5); // center last
    const center_end = @min(right_start - pc_pad, 0.5 + center_total * 0.5); // center last

    const center_width: i32 = @intFromFloat(center_extents.width);
    const right_width: i32 = @intFromFloat(right_extents.width);

    const left_height: i32 = @intFromFloat(left_extents.height);
    const center_height: i32 = @intFromFloat(center_extents.height);
    const right_height: i32 = @intFromFloat(right_extents.height);

    const left_y_bearing: i32 = @intFromFloat(left_extents.y_bearing);
    const center_y_bearing: i32 = @intFromFloat(center_extents.y_bearing);
    const right_y_bearing: i32 = @intFromFloat(right_extents.y_bearing);

    var left_pattern = try cairo.Pattern.createLinear(
        @floatFromInt(surf_bounds.x + client.border),
        0,
        @floatFromInt(surf_bounds.x + surf_bounds.width - client.border),
        0,
    );
    defer left_pattern.destroy();

    try left_pattern.addColorStopRgba(left_end, fg[2], fg[1], fg[0], fg[3]);
    try left_pattern.addColorStopRgba(left_end + pc_pad, bg[2], bg[1], bg[0], bg[3]);

    var center_pattern = try cairo.Pattern.createLinear(
        @floatFromInt(surf_bounds.x + client.border),
        0,
        @floatFromInt(surf_bounds.x + surf_bounds.width - client.border),
        0,
    );
    defer center_pattern.destroy();

    try center_pattern.addColorStopRgba(center_start - pc_pad, bg[2], bg[1], bg[0], bg[3]);
    try center_pattern.addColorStopRgba(center_start, fg[2], fg[1], fg[0], fg[3]);
    try center_pattern.addColorStopRgba(center_end, fg[2], fg[1], fg[0], fg[3]);
    try center_pattern.addColorStopRgba(center_end + pc_pad, bg[2], bg[1], bg[0], fg[3]);

    var right_pattern = try cairo.Pattern.createLinear(
        @floatFromInt(surf_bounds.x + client.border),
        0,
        @floatFromInt(surf_bounds.x + surf_bounds.width - client.border),
        0,
    );
    defer right_pattern.destroy();

    try right_pattern.addColorStopRgba(right_start - pc_pad, bg[2], bg[1], bg[0], fg[3]);
    try right_pattern.addColorStopRgba(right_start, fg[2], fg[1], fg[0], fg[3]);

    context.setOperator(.source);
    context.setSourceRgba(border[2], border[1], border[0], border[3]);
    context.rectangle(
        @floatFromInt(surf_bounds.x),
        @floatFromInt(surf_bounds.y),
        @floatFromInt(surf_bounds.width),
        @floatFromInt(surf_bounds.height),
    );
    context.fill();

    context.rectangle(
        @floatFromInt(surf_bounds.x + client.border),
        @floatFromInt(surf_bounds.y + client.border),
        @floatFromInt(surf_bounds.width - 2 * client.border),
        @floatFromInt(surf_bounds.height - 2 * client.border),
    );
    context.clip();

    context.setSourceRgba(bg[2], bg[1], bg[0], bg[3]);
    context.paint();

    context.moveTo(
        @floatFromInt(surf_bounds.x + client.border + title_pad),
        @floatFromInt(client.border + title_pad + @divTrunc(font.size - left_height, 2) - left_y_bearing),
    );
    context.setSource(&left_pattern);
    context.textPath(left_text);
    context.fill();

    context.moveTo(
        @floatFromInt(surf_bounds.x + @divTrunc(surf_bounds.width - center_width, 2)),
        @floatFromInt(client.border + title_pad + @divTrunc(font.size - center_height, 2) - center_y_bearing),
    );
    context.setSource(&center_pattern);
    context.textPath(center_text);
    context.fill();

    context.moveTo(
        @floatFromInt(surf_bounds.x + surf_bounds.width - right_width - client.border - title_pad),
        @floatFromInt(client.border + title_pad + @divTrunc(font.size - right_height, 2) - right_y_bearing),
    );
    context.setSource(&right_pattern);
    context.textPath(right_text);
    context.fill();
}
