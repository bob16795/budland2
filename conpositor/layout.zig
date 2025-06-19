const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const std = @import("std");
const zlua = @import("zlua");

const Config = @import("config.zig");

const allocator = Config.allocator;
const Lua = zlua.Lua;

const Layout = @This();

pub const Container = struct {
    pub const Size = struct {
        x_min: f64,
        y_min: f64,
        x_max: f64,
        y_max: f64,

        pub fn apply(self: Size, other: Size) Size {
            const my_x: f64 = self.x_max - self.x_min;
            const my_y: f64 = self.y_max - self.y_min;

            return .{
                .x_min = self.x_min + my_x * other.x_min,
                .x_max = self.x_min + my_x * other.x_max,
                .y_min = self.y_min + my_y * other.y_min,
                .y_max = self.y_min + my_y * other.y_max,
            };
        }

        pub fn eval(self: Size, bounds: wlr.Box) wlr.Box {
            const screen_x: i32 = @intFromFloat(@as(f64, @floatFromInt(bounds.width)) * self.x_min);
            const screen_y: i32 = @intFromFloat(@as(f64, @floatFromInt(bounds.height)) * self.y_min);
            const screen_x_max: i32 = @intFromFloat(@as(f64, @floatFromInt(bounds.width)) * self.x_max);
            const screen_y_max: i32 = @intFromFloat(@as(f64, @floatFromInt(bounds.height)) * self.y_max);
            const screen_w = screen_x_max - screen_x;
            const screen_h = screen_y_max - screen_y;

            return .{
                .x = screen_x + bounds.x,
                .y = screen_y + bounds.y,
                .width = screen_w,
                .height = screen_h,
            };
        }
    };

    stack: ?u8,

    size: Size,

    children: []Container,

    pub fn has(self: *const Container, idx: u8) bool {
        if (self.stack == idx)
            return true;

        for (self.children) |child| {
            if (child.has(idx))
                return true;
        }

        return false;
    }

    pub fn childrenUsed(self: *const Container, usage: []bool) usize {
        var result: usize = 0;

        if (self.stack) |stack| {
            if (usage[stack])
                result += 1;
        }

        for (self.children) |child| {
            if (child.used(usage) != 0)
                result += 1;
        }

        return result;
    }

    pub fn used(self: *const Container, usage: []bool) usize {
        var result: usize = 0;

        if (self.stack) |stack| {
            if (usage[stack])
                result += 1;
        }

        for (self.children) |child| {
            result += child.used(usage);
        }

        return result;
    }

    pub fn getSize(self: *const Container, idx: u8, usage: []bool) ?Size {
        if (!self.has(idx))
            return null;

        if (self.stack == idx or self.used(usage) == 1) {
            return .{
                .x_min = 0.0,
                .x_max = 1.0,
                .y_min = 0.0,
                .y_max = 1.0,
            };
        } else if (self.childrenUsed(usage) == 1) {
            for (self.children) |child| {
                if (child.getSize(idx, usage)) |new_result|
                    return new_result;
            }

            // TODO: is this the best choice?
            unreachable;
        } else {
            for (self.children) |child| {
                if (child.getSize(idx, usage)) |new_result|
                    return child.size.apply(new_result);
            }

            // TODO: is this the best choice?
            unreachable;
        }
    }

    pub fn fromLua(lua: *Lua, _: ?std.mem.Allocator, index: i32) !Container {
        const result = try lua.toUserdata(Container, index);
        return result.*;
    }

    pub fn toLua(self: Container, lua: *Lua) !void {
        const tmp = lua.newUserdata(Container, 0);
        tmp.* = self;

        lua.setMetatableRegistry("Container");
    }

    pub fn lua_new(x_min: f64, y_min: f64, x_max: f64, y_max: f64) !Container {
        return .{
            .stack = null,
            .size = .{
                .x_min = x_min,
                .x_max = x_max,
                .y_min = y_min,
                .y_max = y_max,
            },
            .children = &.{},
        };
    }

    pub fn lua_set_stack(self: *Container, stack: ?u8) !void {
        self.stack = stack;
    }

    pub fn lua_add_child(self: *Container, child: Container) !void {
        self.children = try allocator.realloc(self.children, self.children.len + 1);
        self.children[self.children.len - 1] = child;

        std.log.info("child: {}", .{child});
    }
};

name: [*:0]const u8,
container: Container,

gaps_inner: i32,
gaps_outer: i32,

pub fn getSize(self: *const Layout, idx: u8, bounds: wlr.Box, border: i32, usage: []bool) wlr.Box {
    const new_bounds: wlr.Box = .{
        .x = bounds.x + self.gaps_outer,
        .y = bounds.y + self.gaps_outer,
        .width = bounds.width - self.gaps_outer * 2 - border,
        .height = bounds.height - self.gaps_outer * 2 - border,
    };

    const result = if (self.container.getSize(idx, usage)) |size|
        size.eval(new_bounds)
    else
        new_bounds;

    return .{
        .x = result.x + self.gaps_inner,
        .y = result.y + self.gaps_inner,
        .width = result.width - self.gaps_inner * 2 + border,
        .height = result.height - self.gaps_inner * 2 + border,
    };
}

pub fn fromLua(lua: *Lua, _: ?std.mem.Allocator, index: i32) !Layout {
    const result = try lua.toUserdata(Layout, index);
    return result.*;
}

pub fn toLua(self: Layout, lua: *Lua) !void {
    const tmp = lua.newUserdata(Layout, 0);
    tmp.* = self;

    lua.setMetatableRegistry("Layout");
}

pub fn lua_new(name: [*:0]const u8, container: Container) !Layout {
    return .{
        .name = name,
        .container = container,
        .gaps_inner = 20,
        .gaps_outer = 20,
    };
}
