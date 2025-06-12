const std = @import("std");
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const wl = @import("wayland").server.wl;

const Config = @This();

pub const ConfigError = error{
    OpenFileFailed,
    BadOperationInput,
    UnknownOperation,
    OutOfMemory,
    Unimplemented,
};

fn ConfigLookup(comptime T: type) type {
    return struct {
        const Self = @This();

        default: T,
        overrides: std.StringHashMap(T),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .overrides = .init(allocator),
                .default = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.overrides.deinit();
        }

        pub fn add(self: *Self, in_name: ?[]const u8, value: T) !void {
            if (in_name) |name| {
                if (self.overrides.get(name)) |current| {
                    _ = current;
                    std.log.warn("TODO: override current", .{});

                    return error.Unimplemented;
                } else {
                    const clone = try self.allocator.dupe(u8, name);

                    try self.overrides.put(clone, value);
                }
            } else {
                std.log.warn("TODO: override default", .{});

                return error.Unimplemented;
            }
        }
    };
}

const MonitorRule = struct {
    scale: ?f32 = 1.0,
    transform: ?wl.Output.Transform = .normal,
    x: ?i32 = 0,
    y: ?i32 = 0,
};

const BindData = struct {
    mod: wlr.Keyboard.ModifierMask,
    keysym: xkb.Keysym,
    operation: Operation,

    pub fn deinit(self: *const BindData) void {
        self.operation.deinit();
    }

    pub fn clone(self: *const BindData) !BindData {
        return .{
            .mod = self.mod,
            .keysym = self.keysym,
            .operation = try self.operation.clone(),
        };
    }
};

const MouseBindData = struct {
    mod: wlr.Keyboard.ModifierMask,
    button: i32,
    action: MouseAction,
};

allocator: std.mem.Allocator,
tags: std.ArrayList([]const u8),
colors: [2][3][4]f32,
monitor_rules: ConfigLookup(MonitorRule),
auto_commands: std.EnumArray(AutoCondition, std.ArrayList(Operation)),
binds: std.ArrayList(BindData),
mouse_binds: std.ArrayList(MouseBindData),
wayland_display: []const u8,
xwayland_display: []const u8,

const OperationKind = enum {
    none,
    reload,
    create_tag,
    focus_tag,
    send_tag,
    prev_tag,
    next_tag,
    create_client_container,
    create_multi_container,
    focus_container,
    send_container,
    prev_container,
    next_container,
    create_layout,
    prev_layout,
    next_layout,
    toggle_floating,
    toggle_fullscreen,
    quit_client,
    quit_budland,
    set_color,
    monitor_rule,
    default_rule,
    client_rule,
    exec,
    auto,
    bind,
    mouse,
};

const AutoCondition = enum { startup };
const ColorLayer = enum { border, background, foreground };
const MouseAction = enum { move, resize };
const RuleKind = enum { icon, tag, container, center, floating, fullscreen, label };
const ClientProp = enum { title, class };

const OperationString = struct {
    allocator: std.mem.Allocator,
    value: []const u8,

    pub fn dupe(allocator: std.mem.Allocator, value: []const u8) !OperationString {
        return .{ .allocator = allocator, .value = try allocator.dupe(u8, value) };
    }
};

const Operation = union(OperationKind) {
    none,
    reload,
    create_tag: OperationString,
    focus_tag: OperationString,
    send_tag: OperationString,
    prev_tag,
    next_tag,

    create_client_container: struct {
        allocator: std.mem.Allocator,

        name: []const u8,

        top: f32,
        bottom: f32,
        left: f32,
        right: f32,
    },
    create_multi_container: struct {
        allocator: std.mem.Allocator,

        name: []const u8,

        child_a: []const u8,
        child_b: []const u8,
    },
    focus_container: OperationString,
    send_container: OperationString,
    prev_container,
    next_container,

    create_layout: struct {
        allocator: std.mem.Allocator,

        name: []const u8,

        root: []const u8,
        gaps_inner: u32,
        gaps_outer: u32,
    },
    prev_layout,
    next_layout,

    toggle_floating,
    toggle_fullscreen,
    quit_client,
    quit_budland,

    set_color: struct {
        active: bool,
        layer: ColorLayer,
        color: [4]f32,
    },

    monitor_rule: struct {
        allocator: std.mem.Allocator,

        name: ?[]const u8,
        rule: MonitorRule,
    },
    default_rule: struct {
        allocator: std.mem.Allocator,

        key: RuleKind,
        value: []const u8,
    },
    client_rule: struct {
        allocator: std.mem.Allocator,

        prop: ClientProp,
        prop_value: []const u8,

        key: RuleKind,
        value: []const u8,
    },

    exec: struct {
        allocator: std.mem.Allocator,

        command: []const u8,
    },

    auto: struct {
        allocator: std.mem.Allocator,

        condition: AutoCondition,
        child: *Operation,
    },
    bind: struct {
        allocator: std.mem.Allocator,

        data: *BindData,
    },
    mouse: MouseBindData,

    pub fn clone(self: *const Operation) !Operation {
        switch (self.*) {
            .bind => |bind| {
                const result: Operation = .{ .bind = .{
                    .allocator = bind.allocator,
                    .data = try bind.allocator.create(BindData),
                } };
                result.bind.data.* = bind.data.*;

                return result;
            },
            .exec => |exec| {
                return .{ .exec = .{
                    .allocator = exec.allocator,
                    .command = try exec.allocator.dupe(u8, exec.command),
                } };
            },
            .monitor_rule => |monitor| {
                return .{ .monitor_rule = .{
                    .allocator = monitor.allocator,
                    .rule = monitor.rule,
                    .name = if (monitor.name) |name|
                        try monitor.allocator.dupe(u8, name)
                    else
                        null,
                } };
            },
            .auto => |auto| {
                const child = try auto.allocator.create(Operation);
                child.* = try auto.child.clone();

                return .{ .auto = .{
                    .allocator = auto.allocator,
                    .child = child,

                    .condition = auto.condition,
                } };
            },
            .default_rule => |default_rule| {
                return .{ .default_rule = .{
                    .allocator = default_rule.allocator,
                    .key = default_rule.key,
                    .value = try default_rule.allocator.dupe(u8, default_rule.value),
                } };
            },
            .client_rule => |client_rule| {
                return .{ .client_rule = .{
                    .allocator = client_rule.allocator,
                    .key = client_rule.key,
                    .value = try client_rule.allocator.dupe(u8, client_rule.value),
                    .prop = client_rule.prop,
                    .prop_value = try client_rule.allocator.dupe(u8, client_rule.prop_value),
                } };
            },
            .create_client_container => |create_client_container| {
                return .{ .create_client_container = .{
                    .allocator = create_client_container.allocator,
                    .name = try create_client_container.allocator.dupe(u8, create_client_container.name),
                    .top = create_client_container.top,
                    .bottom = create_client_container.bottom,
                    .left = create_client_container.left,
                    .right = create_client_container.right,
                } };
            },
            .create_multi_container => |create_multi_container| {
                return .{ .create_multi_container = .{
                    .allocator = create_multi_container.allocator,
                    .name = try create_multi_container.allocator.dupe(u8, create_multi_container.name),
                    .child_a = try create_multi_container.allocator.dupe(u8, create_multi_container.child_a),
                    .child_b = try create_multi_container.allocator.dupe(u8, create_multi_container.child_b),
                } };
            },
            .create_layout => |create_layout| {
                return .{ .create_layout = .{
                    .allocator = create_layout.allocator,
                    .name = try create_layout.allocator.dupe(u8, create_layout.name),
                    .root = try create_layout.allocator.dupe(u8, create_layout.root),

                    .gaps_inner = create_layout.gaps_inner,
                    .gaps_outer = create_layout.gaps_outer,
                } };
            },
            // .create_tag, .focus_tag, .send_tag, .focus_container, .send_container => |string_thing| {},
            else => return self.*,
        }
    }

    pub fn deinit(self: *const Operation) void {
        switch (self.*) {
            .bind => |bind| {
                bind.data.deinit();
                bind.allocator.destroy(bind.data);
            },
            .exec => |exec| {
                exec.allocator.free(exec.command);
            },
            .monitor_rule => |monitor| {
                if (monitor.name) |name|
                    monitor.allocator.free(name);
            },
            .auto => |auto| {
                auto.child.deinit();
                auto.allocator.destroy(auto.child);
            },
            .default_rule => |default_rule| {
                default_rule.allocator.free(default_rule.value);
            },
            .client_rule => |client_rule| {
                client_rule.allocator.free(client_rule.prop_value);
                client_rule.allocator.free(client_rule.value);
            },
            .create_client_container => |create_client_container| {
                create_client_container.allocator.free(create_client_container.name);
            },
            .create_multi_container => |create_multi_container| {
                create_multi_container.allocator.free(create_multi_container.name);
                create_multi_container.allocator.free(create_multi_container.child_a);
                create_multi_container.allocator.free(create_multi_container.child_b);
            },
            .create_layout => |create_layout| {
                create_layout.allocator.free(create_layout.name);
                create_layout.allocator.free(create_layout.root);
            },
            .create_tag, .focus_tag, .send_tag, .focus_container, .send_container => |string_thing| {
                string_thing.allocator.free(string_thing.value);
            },
            else => {},
        }
    }

    pub inline fn parseOption(
        comptime T: type,
        input: []const u8,
        table: []const struct { input: []const u8, value: T },
    ) !T {
        for (table) |item|
            if (std.mem.eql(u8, input, item.input))
                return item.value;

        return error.BadOperationInput;
    }

    pub fn parse(self: *Config, input_line: []const u8) ConfigError!Operation {
        if (std.mem.indexOf(u8, input_line, "#")) |hash_idx|
            return parse(self, input_line[0..hash_idx]);

        const line = std.mem.trim(u8, input_line, &std.ascii.whitespace);
        errdefer std.log.err("config line error line: '{s}'", .{line});

        if (line.len == 0)
            return .none;

        var split = std.mem.tokenizeScalar(u8, line, ' ');
        const first = split.next() orelse unreachable;
        if (std.mem.eql(u8, first, "color")) {
            const active_text = split.next() orelse return error.BadOperationInput;
            const item_text = split.next() orelse return error.BadOperationInput;
            const color_text = split.next() orelse return error.BadOperationInput;

            const active = try parseOption(bool, active_text, &.{
                .{ .input = "active", .value = true },
                .{ .input = "inactive", .value = false },
            });

            const layer = try parseOption(ColorLayer, item_text, &.{
                .{ .input = "border", .value = .border },
                .{ .input = "background", .value = .background },
                .{ .input = "foreground", .value = .foreground },
            });

            const color = std.fmt.parseInt(u32, color_text, 16) catch return error.BadOperationInput;
            const r = @as(f32, @floatFromInt((color >> 24) & 0xff)) / 255;
            const g = @as(f32, @floatFromInt((color >> 16) & 0xff)) / 255;
            const b = @as(f32, @floatFromInt((color >> 8) & 0xff)) / 255;
            const a = @as(f32, @floatFromInt((color >> 0) & 0xff)) / 255;

            return .{ .set_color = .{
                .active = active,
                .layer = layer,
                .color = .{ r, g, b, a },
            } };
        } else if (std.mem.eql(u8, first, "monitor")) {
            const name_text = split.next() orelse return error.BadOperationInput;
            // const scale_text = split.next() orelse return error.BadOperationInput;
            // const transform_text = split.next() orelse return error.BadOperationInput;
            const x_text = split.next() orelse return error.BadOperationInput;
            const y_text = split.next() orelse return error.BadOperationInput;

            const name = if (std.mem.eql(u8, name_text, "default"))
                null
            else
                try self.allocator.dupe(u8, name_text);
            errdefer if (name) |name_value|
                self.allocator.free(name_value);

            // const scale = std.fmt.parseFloat(f32, x_text, 0) catch return error.BadOperationInput;
            const scale = 1.0;
            const transform: wl.Output.Transform = .normal;

            const x = std.fmt.parseInt(i32, x_text, 0) catch return error.BadOperationInput;
            const y = std.fmt.parseInt(i32, y_text, 0) catch return error.BadOperationInput;

            return .{ .monitor_rule = .{
                .allocator = self.allocator,
                .name = name,
                .rule = .{
                    .scale = scale,
                    .transform = transform,
                    .x = x,
                    .y = y,
                },
            } };
        } else if (std.mem.eql(u8, first, "auto")) {
            const condition_text = split.next() orelse return error.BadOperationInput;

            const condition = try parseOption(AutoCondition, condition_text, &.{
                .{ .input = "init", .value = .startup },
            });

            const cmd_text = split.rest();

            const operation = try self.allocator.create(Operation);
            errdefer {
                operation.deinit();
                self.allocator.destroy(operation);
            }
            operation.* = try parse(self, cmd_text);

            return .{ .auto = .{
                .allocator = self.allocator,
                .condition = condition,
                .child = operation,
            } };
        } else if (std.mem.eql(u8, first, "exec")) {
            const cmd_text = split.rest();
            const cmd = try self.allocator.dupe(u8, cmd_text);

            return .{ .exec = .{
                .allocator = self.allocator,
                .command = cmd,
            } };
        } else if (std.mem.eql(u8, first, "mouse")) {
            const button_text = split.next();
            const command_text = split.next() orelse return error.BadOperationInput;

            _ = button_text;

            const command = try parseOption(MouseAction, command_text, &.{
                .{ .input = "move", .value = .move },
                .{ .input = "resize", .value = .resize },
            });

            return .{ .mouse = .{
                .mod = .{},
                .button = 0,
                .action = command,
            } };
        } else if (std.mem.eql(u8, first, "rule")) {
            const rule_kind = split.next() orelse return error.BadOperationInput;
            if (std.mem.eql(u8, rule_kind, "default")) {
                const key_text = split.next() orelse return error.BadOperationInput;
                const value_text = split.next() orelse return error.BadOperationInput;

                const key = try parseOption(RuleKind, key_text, &.{
                    .{ .input = "icon", .value = .icon },
                    .{ .input = "tag", .value = .tag },
                    .{ .input = "container", .value = .container },
                    .{ .input = "center", .value = .center },
                    .{ .input = "floating", .value = .floating },
                    .{ .input = "fullscreen", .value = .fullscreen },
                    .{ .input = "label", .value = .label },
                });

                const value = try self.allocator.dupe(u8, value_text);
                errdefer self.allocator.free(value);

                return .{ .default_rule = .{
                    .allocator = self.allocator,

                    .key = key,
                    .value = value,
                } };
            } else if (std.mem.eql(u8, rule_kind, "client")) {
                const prop_text = split.next() orelse return error.BadOperationInput;
                const prop_value_text = split.next() orelse return error.BadOperationInput;
                const key_text = split.next() orelse return error.BadOperationInput;
                const value_text = split.next() orelse return error.BadOperationInput;

                const prop = try parseOption(ClientProp, prop_text, &.{
                    .{ .input = "title", .value = .title },
                    .{ .input = "class", .value = .class },
                });

                const prop_value = try self.allocator.dupe(u8, prop_value_text);
                errdefer self.allocator.free(prop_value);

                const key = try parseOption(RuleKind, key_text, &.{
                    .{ .input = "icon", .value = .icon },
                    .{ .input = "tag", .value = .tag },
                    .{ .input = "container", .value = .container },
                    .{ .input = "center", .value = .center },
                    .{ .input = "floating", .value = .floating },
                    .{ .input = "fullscreen", .value = .fullscreen },
                    .{ .input = "label", .value = .label },
                });

                const value = try self.allocator.dupe(u8, value_text);
                errdefer self.allocator.free(value);

                return .{ .client_rule = .{
                    .allocator = self.allocator,

                    .prop = prop,
                    .prop_value = prop_value,
                    .key = key,
                    .value = value,
                } };
            } else return error.BadOperationInput;
        } else if (std.mem.eql(u8, first, "bind")) {
            const key_text = split.next() orelse return error.BadOperationInput;
            const cmd_text = split.rest();

            var mod: wlr.Keyboard.ModifierMask = .{};
            var keysym: xkb.Keysym = @enumFromInt(xkb.Keysym.Escape);

            var iter = std.mem.splitScalar(u8, key_text, '+');
            while (iter.next()) |key| {
                if (std.mem.eql(u8, key, "LOGO"))
                    mod.alt = true
                        // mod.logo = true
                else if (std.mem.eql(u8, key, "SHIFT"))
                    mod.shift = true
                else if (std.mem.eql(u8, key, "CTRL"))
                    mod.ctrl = true
                else if (std.mem.eql(u8, key, "ALT"))
                    mod.alt = true
                else if (std.mem.eql(u8, key, "Tab"))
                    keysym = @enumFromInt(xkb.Keysym.Tab)
                else if (std.mem.eql(u8, key, "Space"))
                    keysym = @enumFromInt(xkb.Keysym.space)
                else if (std.mem.eql(u8, key, "Return"))
                    keysym = @enumFromInt(xkb.Keysym.Return)
                else if (std.mem.eql(u8, key, "F1"))
                    keysym = @enumFromInt(xkb.Keysym.F1)
                else if (std.mem.eql(u8, key, "F2"))
                    keysym = @enumFromInt(xkb.Keysym.F2)
                else if (std.mem.eql(u8, key, "F3"))
                    keysym = @enumFromInt(xkb.Keysym.F3)
                else if (std.mem.eql(u8, key, "F4"))
                    keysym = @enumFromInt(xkb.Keysym.F4)
                else if (key.len == 1) {
                    if (std.ascii.isAlphabetic(key[0])) {
                        if (mod.shift)
                            keysym = @enumFromInt(xkb.Keysym.A + std.ascii.toLower(key[0]) - 'a')
                        else
                            keysym = @enumFromInt(xkb.Keysym.a + std.ascii.toLower(key[0]) - 'a');
                    } else if (std.ascii.isDigit(key[0])) {
                        if (mod.shift) {
                            const shift = [_]xkb.Keysym{
                                @enumFromInt(xkb.Keysym.topleftparens),
                                @enumFromInt(xkb.Keysym.exclam),
                                @enumFromInt(xkb.Keysym.at),
                                @enumFromInt(xkb.Keysym.numbersign),
                                @enumFromInt(xkb.Keysym.dollar),
                            };
                            keysym = shift[std.ascii.toLower(key[0]) - '0'];
                        } else {
                            keysym = @enumFromInt(xkb.Keysym.@"0" + std.ascii.toLower(key[0]) - '0');
                        }
                    } else {
                        return error.BadOperationInput;
                    }
                } else {
                    return error.BadOperationInput;
                }
            }

            const operation = try parse(self, cmd_text);

            const bind = try self.allocator.create(BindData);
            errdefer {
                bind.deinit();
                self.allocator.destroy(bind);
            }

            bind.* = .{
                .mod = mod,
                .keysym = keysym,
                .operation = operation,
            };

            return .{ .bind = .{
                .data = bind,
                .allocator = self.allocator,
            } };
        } else if (std.mem.eql(u8, first, "create")) {
            const target_text = split.next() orelse return error.BadOperationInput;
            const name_text = split.next() orelse return error.BadOperationInput;

            const name = try self.allocator.dupe(u8, name_text);
            errdefer self.allocator.free(name);

            if (std.mem.eql(u8, target_text, "container")) {
                const container_kind = split.next() orelse return error.BadOperationInput;
                if (std.mem.eql(u8, container_kind, "client")) {
                    const top_text = split.next() orelse return error.BadOperationInput;
                    const left_text = split.next() orelse return error.BadOperationInput;
                    const bottom_text = split.next() orelse return error.BadOperationInput;
                    const right_text = split.next() orelse return error.BadOperationInput;

                    const top = std.fmt.parseFloat(f32, top_text) catch return error.BadOperationInput;
                    const left = std.fmt.parseFloat(f32, left_text) catch return error.BadOperationInput;
                    const bottom = std.fmt.parseFloat(f32, bottom_text) catch return error.BadOperationInput;
                    const right = std.fmt.parseFloat(f32, right_text) catch return error.BadOperationInput;

                    return .{ .create_client_container = .{
                        .allocator = self.allocator,

                        .name = name,
                        .top = top,
                        .left = left,
                        .bottom = bottom,
                        .right = right,
                    } };
                } else if (std.mem.eql(u8, container_kind, "multi")) {
                    const child_a_text = split.next() orelse return error.BadOperationInput;
                    const child_b_text = split.next() orelse return error.BadOperationInput;

                    const child_a = try self.allocator.dupe(u8, child_a_text);
                    errdefer self.allocator.free(child_a);

                    const child_b = try self.allocator.dupe(u8, child_b_text);
                    errdefer self.allocator.free(child_b);

                    return .{ .create_multi_container = .{
                        .allocator = self.allocator,

                        .name = name,

                        .child_a = child_a,
                        .child_b = child_b,
                    } };
                } else return error.BadOperationInput;
            } else if (std.mem.eql(u8, target_text, "layout")) {
                const root_text = split.next() orelse return error.BadOperationInput;
                const gaps_inner_text = split.next() orelse return error.BadOperationInput;
                const gaps_outer_text = split.next() orelse return error.BadOperationInput;

                const root = try self.allocator.dupe(u8, root_text);
                errdefer self.allocator.free(root);

                const gaps_inner = std.fmt.parseInt(u32, gaps_inner_text, 10) catch return error.BadOperationInput;
                const gaps_outer = std.fmt.parseInt(u32, gaps_outer_text, 10) catch return error.BadOperationInput;

                return .{ .create_layout = .{
                    .allocator = self.allocator,

                    .name = name,
                    .root = root,

                    .gaps_inner = gaps_inner,
                    .gaps_outer = gaps_outer,
                } };
            } else return try parseOption(Operation, target_text, &.{
                .{ .input = "tag", .value = .{ .create_tag = .{ .value = name, .allocator = self.allocator } } },
            });
        } else if (std.mem.eql(u8, first, "focus")) {
            const target_text = split.next() orelse return error.BadOperationInput;
            const name_text = split.next() orelse return error.BadOperationInput;

            const name: OperationString = try .dupe(self.allocator, name_text);
            errdefer self.allocator.free(name.value);

            return try parseOption(Operation, target_text, &.{
                .{ .input = "tag", .value = .{ .focus_tag = name } },
                .{ .input = "container", .value = .{ .focus_container = name } },
            });
        } else if (std.mem.eql(u8, first, "send")) {
            const target_text = split.next() orelse return error.BadOperationInput;
            const name_text = split.next() orelse return error.BadOperationInput;

            const name: OperationString = try .dupe(self.allocator, name_text);
            errdefer self.allocator.free(name.value);

            return try parseOption(Operation, target_text, &.{
                .{ .input = "tag", .value = .{ .send_tag = name } },
                .{ .input = "container", .value = .{ .send_container = name } },
            });
        } else if (std.mem.eql(u8, first, "next")) {
            const target_text = split.next() orelse return error.BadOperationInput;

            return try parseOption(Operation, target_text, &.{
                .{ .input = "tag", .value = .next_tag },
                .{ .input = "container", .value = .next_container },
                .{ .input = "layout", .value = .next_layout },
            });
        } else if (std.mem.eql(u8, first, "prev")) {
            const target_text = split.next() orelse return error.BadOperationInput;

            return try parseOption(Operation, target_text, &.{
                .{ .input = "tag", .value = .prev_tag },
                .{ .input = "container", .value = .prev_container },
                .{ .input = "layout", .value = .prev_layout },
            });
        } else if (std.mem.eql(u8, first, "toggle")) {
            const target_text = split.next() orelse return error.BadOperationInput;

            return try parseOption(Operation, target_text, &.{
                .{ .input = "fullscreen", .value = .toggle_fullscreen },
                .{ .input = "floating", .value = .toggle_floating },
            });
        } else if (std.mem.eql(u8, first, "quit")) {
            const target_text = split.next() orelse return error.BadOperationInput;

            return try parseOption(Operation, target_text, &.{
                .{ .input = "client", .value = .quit_client },
                .{ .input = "budland", .value = .quit_budland },
            });
        } else if (std.mem.eql(u8, first, "reload")) {
            return .reload;
        }

        return error.UnknownOperation;
    }
};

pub fn apply(self: *Config, operation: Operation) !void {
    switch (operation) {
        .none => {},
        .monitor_rule => |monitor_rule| {
            try self.monitor_rules.add(monitor_rule.name, monitor_rule.rule);
        },
        .auto => |auto| {
            const clone = try auto.child.clone();
            errdefer clone.deinit();

            try self.auto_commands.getPtr(auto.condition).append(clone);
        },
        .bind => |bind| {
            try self.binds.append(try bind.data.clone());
        },
        .exec => |exec| {
            const required = std.mem.count(u8, exec.command, " ") + 1;
            const data = try self.allocator.alloc([]const u8, required);

            var iter = std.mem.splitScalar(u8, exec.command, ' ');
            var idx: usize = 0;
            while (iter.next()) |item| : (idx += 1) {
                data[idx] = try self.allocator.dupe(u8, item);
            }

            var env = try std.process.getEnvMap(self.allocator);
            try env.put("WAYLAND_DISPLAY", self.wayland_display);
            try env.put("DISPLAY", self.xwayland_display);

            var child = std.process.Child.init(data, self.allocator);
            child.env_map = &env;

            try child.spawn();
        },
        else => {
            std.log.warn("TODO: apply setting {}", .{operation});

            return error.Unimplemented;
        },
    }
}

pub fn init(allocator: std.mem.Allocator) Config {
    return .{
        .allocator = allocator,
        .tags = .init(allocator),
        .colors = .{
            .{ .{ 1, 0, 0, 1 }, .{ 1, 0, 0, 1 }, .{ 1, 0, 0, 1 } },
            .{ .{ 1, 0, 0, 1 }, .{ 1, 0, 0, 1 }, .{ 1, 0, 0, 1 } },
        },
        .monitor_rules = .init(allocator),
        .auto_commands = .initFill(.init(allocator)),
        .binds = .init(allocator),
        .mouse_binds = .init(allocator),
        .wayland_display = &.{},
        .xwayland_display = &.{},
    };
}

pub fn deinit(self: *Config) void {
    self.binds.deinit();

    var iter = self.auto_commands.iterator();
    while (iter.next()) |item|
        item.value.deinit();

    self.monitor_rules.deinit();
}

pub fn sourcePath(self: *Config, path: []const u8) ConfigError!void {
    const file = std.fs.openFileAbsolute(path, .{}) catch {
        std.log.err("failed to open config file {s}", .{path});
        return;
    };
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    while (in_stream.readUntilDelimiterOrEofAlloc(self.allocator, '\n', 2048) catch null) |line| {
        defer self.allocator.free(line);

        if (Operation.parse(self, line)) |operation| {
            defer operation.deinit();
            self.apply(operation) catch |err| {
                std.log.warn("TODO: config command {s} {!}", .{ line, err });
            };
        } else |err| {
            std.log.warn("Can't parse config command {s} {!}", .{ line, err });

            continue;
        }
    }
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
        else => if (@intFromEnum(level) <= @intFromEnum(std.log.Level.err))
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
