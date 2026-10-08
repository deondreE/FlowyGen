const std = @import("std");
const vk = @import("vulkan");
const Context = @import("Context.zig");
const Buffer = @import("Buffer.zig");

const Texture = @This();

ctx: *const Context,
image: vk.Image,
memory: vk.DeviceMemory,
view: vk.ImageView,
sampler: vk.Sampler,
width: u32,
height: u32,

pub fn initR8(ctx: *const Context, width: u32, height: u32, pixels: []const u8) !Texture {
    std.debug.assert(pixels.len == @as(usize, width) * height);
    const format: vk.Format = .r8_unorm;

    const image = try ctx.device.createImage(&.{
        .image_type = .@"2d",
        .format = format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1" = true },
        .tiling = .optimal,
        .usage = .{ .transfer_dst = true, .sampled = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);
    errdefer ctx.device.destroyImage(image, null);

    const reqs = ctx.device.getImageMemoryRequirements(image);
    const type_index = try ctx.findMemoryType(reqs.memory_type_bits, .{ .device_local = true });
    const memory = try ctx.device.allocateMemory(&.{
        .allocation_size = reqs.size,
        .memory_type_index = type_index,
    }, null);
    errdefer ctx.device.freeMemory(memory, null);
    try ctx.device.bindImageMemory(image, memory, 0);

    var staging = try Buffer.init(ctx, pixels.len, .{ .transfer_src = true }, .host);
    defer staging.deinit();
    try staging.write(pixels);

    try uploadImage(ctx, image, staging.handle, width, height);

    const view = try ctx.device.createImageView(&.{
        .image = image,
        .view_type = .@"2d",
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = color_range,
    }, null);

    const sampler = try ctx.device.createSampler(&.{
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0,
        .anisotropy_enable = .false,
        .max_anisotropy = 1,
        .compare_enable = .false,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .float_transparent_black,
        .unnormalized_coordinates = .false,
    }, null);

    return .{
        .ctx = ctx,
        .image = image,
        .memory = memory,
        .view = view,
        .sampler = sampler,
        .width = width,
        .height = height,
    };
}

pub fn deinit(self: *Texture) void {
    self.ctx.device.destroySampler(self.sampler, null);
    self.ctx.device.destroyImageView(self.view, null);
    self.ctx.device.destroyImage(self.image, null);
    self.ctx.device.freeMemory(self.memory, null);
}

const color_range: vk.ImageSubresourceRange = .{
    .aspect_mask = .{ .color = true },
    .base_mip_level = 0,
    .level_count = 1,
    .base_array_layer = 0,
    .layer_count = 1,
};

/// One-shot: undefined -> transfer_dst, copy, -> shader_read_only. Blocks until done.
fn uploadImage(ctx: *const Context, image: vk.Image, src: vk.Buffer, width: u32, height: u32) !void {
    const dev = ctx.device;

    const pool = try dev.createCommandPool(&.{
        .flags = .{ .transient = true },
        .queue_family_index = ctx.queue_family,
    }, null);
    defer dev.destroyCommandPool(pool, null);

    var cmd: vk.CommandBuffer = undefined;
    try dev.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmd));

    try dev.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit = true } });

    const to_transfer: vk.ImageMemoryBarrier = .{
        .src_access_mask = .{},
        .dst_access_mask = .{ .transfer_write = true },
        .old_layout = .undefined,
        .new_layout = .transfer_dst_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = color_range,
    };
    dev.cmdPipelineBarrier(cmd, .{ .top_of_pipe = true }, .{ .transfer = true }, .{}, null, null, @ptrCast(&to_transfer));

    const region: vk.BufferImageCopy = .{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{ .color = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    };
    dev.cmdCopyBufferToImage(cmd, src, image, .transfer_dst_optimal, @ptrCast(&region));

    const to_shader: vk.ImageMemoryBarrier = .{
        .src_access_mask = .{ .transfer_write = true },
        .dst_access_mask = .{ .shader_read = true },
        .old_layout = .transfer_dst_optimal,
        .new_layout = .shader_read_only_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = color_range,
    };
    dev.cmdPipelineBarrier(cmd, .{ .transfer = true }, .{ .fragment_shader = true }, .{}, null, null, @ptrCast(&to_shader));

    try dev.endCommandBuffer(cmd);

    const submit: vk.SubmitInfo = .{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmd),
    };
    try dev.queueSubmit(ctx.queue, @ptrCast(&submit), .null_handle);
    try dev.queueWaitIdle(ctx.queue);
}
