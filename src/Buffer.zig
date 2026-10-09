const std = @import("std");
const vk = @import("vulkan");
const Context = @import("Context.zig");

const Buffer = @This();

const Location = enum { host, device };

ctx: *const Context,
handle: vk.Buffer,
memory: vk.DeviceMemory,
size: vk.DeviceSize,
mapped: ?[*]u8,

pub fn init(ctx: *const Context, size: vk.DeviceSize, usage: vk.BufferUsageFlags, location: Location) !Buffer {
    std.debug.assert(size > 0);

    const handle = try ctx.device.createBuffer(&.{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
    }, null);
    errdefer ctx.device.destroyBuffer(handle, null);

    const reqs = ctx.device.getBufferMemoryRequirements(handle);
    const wanted: vk.MemoryPropertyFlags = switch (location) {
        .host => .{ .host_visible = true, .host_coherent = true },
        .device => .{ .device_local = true },
    };
    const type_index = try ctx.findMemoryType(reqs.memory_type_bits, wanted);

    const memory = try ctx.device.allocateMemory(&.{
        .allocation_size = reqs.size,
        .memory_type_index = type_index,
    }, null);
    errdefer ctx.device.freeMemory(memory, null);

    try ctx.device.bindBufferMemory(handle, memory, 0);

    var mapped: ?[*]u8 = null;
    if (location == .host) {
        const ptr = try ctx.device.mapMemory(memory, 0, vk.WHOLE_SIZE, .{});
        mapped = @ptrCast(ptr orelse return error.MemoryMapFailed);
    }

    return .{
        .ctx = ctx,
        .handle = handle,
        .memory = memory,
        .size = size,
        .mapped = mapped,
    };
}

pub fn fromSlice(
    ctx: *const Context,
    comptime T: type,
    items: []const T,
    usage: vk.BufferUsageFlags,
) !Buffer {
    var self = try init(ctx, @sizeOf(T) * items.len, usage, .host);
    errdefer self.deinit();
    try self.write(std.mem.sliceAsBytes(items));
    return self;
}

pub fn mappedSlice(self: *const Buffer, comptime T: type) ![]T {
    const base = self.mapped orelse return error.NotVisibleHost;
    const ptr: [*]T = @ptrCast(@alignCast(base));
    return ptr[0 .. self.size / @sizeOf(T)];
}

pub fn deinit(self: *Buffer) void {
    if (self.mapped != null) self.ctx.device.unmapMemory(self.memory);
    self.ctx.device.destroyBuffer(self.handle, null);
    self.ctx.device.freeMemory(self.memory, null);
}

pub fn write(self: *Buffer, bytes: []const u8) !void {
    return self.writeAt(0, bytes);
}

pub fn writeAt(self: *Buffer, offset: usize, bytes: []const u8) !void {
    const dest = self.mapped orelse return error.NotVisibleHost;
    if (offset + bytes.len > self.size) return error.BufferOverflow;
    @memcpy(dest[offset..][0..bytes.len], bytes);
}
