const cairo = @import("cairo");
const pixman = @import("pixman");
const wlr = @import("wlroots");
const std = @import("std");

const CairoBuffer = @This();

base: wlr.Buffer,

unscaled_width: u16,
unscaled_height: u16,
scale: f32,
surface: cairo.Surface,
context: cairo.Context,
allocator: std.mem.Allocator,

const Impl = struct {
    pub fn destroy(wlr_buffer: *wlr.Buffer) callconv(.C) void {
        const self: *CairoBuffer = @fieldParentPtr("base", wlr_buffer);
        self.destroy();
    }

    pub fn beginDataPtrAccess(wlr_buffer: *wlr.Buffer, _: u32, data: *?*anyopaque, format: *u32, stride: *usize) callconv(.C) bool {
        const self: *CairoBuffer = @fieldParentPtr("base", wlr_buffer);

        data.* = self.surface.getData() catch return false;
        format.* = 875708993;
        stride.* = self.surface.getStride() catch return false;

        return true;
    }

    pub fn endDataPtrAccess(wlr_buffer: *wlr.Buffer) callconv(.C) void {
        const self: *CairoBuffer = @fieldParentPtr("base", wlr_buffer);

        _ = self;
    }

    const VTable: wlr.Buffer.Impl = .{
        .destroy = Impl.destroy,
        .get_dmabuf = null,
        .get_shm = null,
        .begin_data_ptr_access = @ptrCast(&beginDataPtrAccess),
        .end_data_ptr_access = endDataPtrAccess,
    };
};

pub fn create(allocator: std.mem.Allocator, width: u16, height: u16, scale: f32) !*CairoBuffer {
    const scaled_width: u16 = @intFromFloat(scale * @as(f32, @floatFromInt(width)));
    const scaled_height: u16 = @intFromFloat(scale * @as(f32, @floatFromInt(height)));

    const surface = try cairo.Surface.image(scaled_width, scaled_height);

    const result = try allocator.create(CairoBuffer);
    result.* = .{
        .unscaled_width = width,
        .unscaled_height = height,
        .scale = scale,
        .surface = surface,
        .base = undefined,
        .context = try cairo.Context.create(&result.surface),
        .allocator = allocator,
    };
    result.context.scale(@floatCast(scale), @floatCast(scale));

    result.base.init(
        &Impl.VTable,
        @intCast(scaled_width),
        @intCast(scaled_height),
    );

    return result;
}

pub fn deinit(self: *CairoBuffer) void {
    self.base.drop();
}

pub fn destroy(self: *CairoBuffer) void {
    self.context.destroy();
    self.surface.destroy();

    self.allocator.destroy(self);
}

pub fn resize(self: *CairoBuffer, width: u16, height: u16, scale: f32) !*CairoBuffer {
    if (width == self.unscaled_width and
        height == self.unscaled_height and
        scale == self.scale) return self;

    const scaled_width: u16 = @intFromFloat(scale * @as(f32, @floatFromInt(width)));
    const scaled_height: u16 = @intFromFloat(scale * @as(f32, @floatFromInt(height)));

    self.unscaled_width = width;
    self.unscaled_height = height;
    self.scale = scale;

    var old_context = self.surface;
    defer old_context.destroy();
    var old_surface = self.surface;
    defer old_surface.destroy();

    self.surface = try cairo.Surface.image(scaled_width, scaled_height);
    self.context = try cairo.Context.create(&self.surface);
    self.context.scale(@floatCast(scale), @floatCast(scale));

    self.base.width = scaled_width;
    self.base.height = scaled_height;

    return self;
}

pub fn beginContext(
    self: *CairoBuffer,
) !cairo.Context {
    _ = self.base.lock();

    const scaled_width: u16 = @intFromFloat(self.scale * @as(f32, @floatFromInt(self.unscaled_width)));
    const scaled_height: u16 = @intFromFloat(self.scale * @as(f32, @floatFromInt(self.unscaled_height)));
    self.context.setSourceRgba(0, 0, 0, 0);
    self.context.rectangle(
        @floatFromInt(0),
        @floatFromInt(0),
        @floatFromInt(scaled_width),
        @floatFromInt(scaled_height),
    );
    self.context.setOperator(.source);
    self.context.fill();
    self.context.setOperator(.over);
    if (self.context.getTarget()) |surf| {
        var tmp = surf;
        tmp.flush();
    } else |_| {}
    return self.context;
}

pub fn endContext(
    self: *CairoBuffer,
    context: *cairo.Context,
) void {
    self.base.unlock();

    if (context.getTarget()) |surf| {
        var tmp = surf;
        tmp.flush();
    } else |_| {}
}
