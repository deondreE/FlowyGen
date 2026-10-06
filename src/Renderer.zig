const std = @import("std");
const vk = @import("vulkan");
const Context = @import("Context.zig");
const Swapchain = @import("Swapchain.zig");
const Pipeline = @import("Pipeline.zig");
const Buffer = @import("Buffer.zig");
const Window = @import("window.zig");

const Renderer = @This();

pub const max_frames_in_flight = 2;

/// The acquire semaphore is waited on at this stage, and the first layout
/// transition (from .undefined) must cover the same stage.
const aquire_stage: vk.PipelineStageFlags = .{ .color_attachment_output = true, .transfer = true };

const color_range: vk.ImageSubresourceRange = .{
    .aspect_mask = .{ .color = true },
    .base_mip_level = 0,
    .level_count = 1,
    .base_array_layer = 0,
    .layer_count = 1,
};

/// What you get between beginFrame and endFrame. Tracks the image layout so
/// you can say where you want it and the barrier is figured out for you.
pub const Frame = struct {
    cmd: Context.CommandBuffer,
    image: vk.Image,
    view: vk.ImageView,
    extent: vk.Extent2D,
    image_index: u32,
    layout: vk.ImageLayout = .undefined,

    pub fn transition(self: *Frame, new_layout: vk.ImageLayout) void {
        if (self.layout == new_layout) return;
        const src = syncFor(self.layout);
        const dst = syncFor(new_layout);
        const barrier: vk.ImageMemoryBarrier = .{
            .src_access_mask = src.access,
            .dst_access_mask = dst.access,
            .old_layout = self.layout,
            .new_layout = new_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresource_range = color_range,
        };
        self.cmd.pipelineBarrier(src.stage, dst.stage, .{}, &.{}, &.{}, &.{barrier});
        self.layout = new_layout;
    }

    pub fn clear(self: *Frame, color: [4]f32) void {
        self.transition(.transfer_dst_optimal);
        const value: vk.ClearColorValue = .{ .float_32 = color };
        self.cmd.clearColorImage(self.image, .transfer_dst_optimal, &value, &.{color_range});
    }

    /// Start drawing into the swapchain image: moves it to the attachment layout,
    /// clears it, and sets a viewport and scissor covering the whole image.
    /// Pair with endRendering().
    pub fn beginRendering(self: *Frame, clear_color: [4]f32) void {
        self.transition(.color_attachment_optimal);

        const attachment: vk.RenderingAttachmentInfo = .{
            .image_view = self.view,
            .image_layout = .color_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_view = .null_handle,
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .color = .{ .float_32 = clear_color } },
        };
        self.cmd.beginRendering(&.{
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&attachment),
        });

        const viewport: vk.Viewport = .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(self.extent.width),
            .height = @floatFromInt(self.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        };
        const scissor: vk.Rect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent };
        self.cmd.setViewport(0, &.{viewport});
        self.cmd.setScissor(0, &.{scissor});
    }

    pub fn endRendering(self: *Frame) void {
        self.cmd.endRendering();
    }

    pub fn bindPipeline(self: *Frame, pipeline: *const Pipeline) void {
        self.cmd.bindPipeline(.graphics, pipeline.handle);
    }

    pub fn bindVertexBuffer(self: *Frame, buffer: *const Buffer) void {
        self.cmd.bindVertexBuffers(0, &.{buffer.handle}, &.{0});
    }

    pub fn draw(self: *Frame, vertex_count: u32) void {
        self.cmd.draw(vertex_count, 1, 0, 0);
    }
};

const Sync = struct {
    stage: vk.PipelineStageFlags,
    access: vk.AccessFlags,
};

fn syncFor(layout: vk.ImageLayout) Sync {
    return switch (layout) {
        .undefined => .{ .stage = aquire_stage, .access = .{} },
        .transfer_dst_optimal => .{
            .stage = .{ .transfer = true },
            .access = .{ .transfer_write = true },
        },
        .color_attachment_optimal => .{
            .stage = .{ .color_attachment_output = true },
            .access = .{ .color_attachment_write = true },
        },
        .present_src_khr => .{ .stage = .{ .bottom_of_pipe = true }, .access = .{} },
        else => unreachable, // @Todo: Add a case when you start to use a new layout.
    };
}

const Slot = struct {
    cmd: vk.CommandBuffer,
    image_available: vk.Semaphore,
    in_flight: vk.Fence,

    fn init(ctx: *const Context, cmd: vk.CommandBuffer) !Slot {
        const sem = try ctx.device.createSemaphore(&.{}, null);
        errdefer ctx.device.destroySemaphore(sem, null);

        // Start signaled so the very first wait doesn't block forever.
        const fence = try ctx.device.createFence(&.{ .flags = .{ .signaled = true } }, null);
        return .{ .cmd = cmd, .image_available = sem, .in_flight = fence };
    }

    fn deinit(self: Slot, ctx: *const Context) void {
        ctx.device.destroyFence(self.in_flight, null);
        ctx.device.destroySemaphore(self.image_available, null);
    }
};

// Renderer cont...
ctx: *const Context,
swapchain: *Swapchain,
pool: vk.CommandPool,
slots: [max_frames_in_flight]Slot,
current: usize = 0,
needs_recreate: bool = false,

pub fn init(ctx: *const Context, swapchain: *Swapchain) !Renderer {
    const pool = try ctx.device.createCommandPool(&.{
        .flags = .{ .reset_command_buffer = true },
        .queue_family_index = ctx.queue_family,
    }, null);
    errdefer ctx.device.destroyCommandPool(pool, null);

    // Command buffers are freed together with their pool.
    var cmds: [max_frames_in_flight]vk.CommandBuffer = undefined;
    try ctx.device.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = max_frames_in_flight,
    }, &cmds);

    var slots: [max_frames_in_flight]Slot = undefined;
    var made: usize = 0;
    errdefer for (slots[0..made]) |s| s.deinit(ctx);
    while (made < max_frames_in_flight) : (made += 1) {
        slots[made] = try Slot.init(ctx, cmds[made]);
    }

    return Renderer{
        .ctx = ctx,
        .swapchain = swapchain,
        .pool = pool,
        .slots = slots,
    };
}

pub fn deinit(self: *Renderer) void {
    self.ctx.waitIdle();
    for (self.slots) |s| s.deinit(self.ctx);
    self.ctx.device.destroyCommandPool(self.pool, null);
}

pub fn beginFrame(self: *Renderer, window: *Window) !?Frame {
    if (window.isMinimized()) return null;

    if (window.takeResized() or self.needs_recreate) {
        try self.swapchain.rebuild(window);
        self.needs_recreate = false;
    }

    const device = &self.ctx.device;
    const slot = self.slots[self.current];

    // Wait until the GPU is done with the last frame that used this slot.
    _ = try device.waitForFences(&.{slot.in_flight}, .true, std.math.maxInt(u64));

    const aquired = device.acquireNextImageKHR(
        self.swapchain.handle,
        std.math.maxInt(u64),
        slot.image_available,
        .null_handle,
    ) catch |err| switch (err) {
        error.OutOfDateKHR => {
            try self.swapchain.rebuild(window);
            return null;
        },
        else => return err,
    };
    if (aquired.result == .suboptimal_khr) self.needs_recreate = true;

    // Only reset the fence once we know we will submit work that signals it.
    try device.resetFences(&.{slot.in_flight});

    const cmd = Context.CommandBuffer.init(slot.cmd, device.wrapper);
    try cmd.beginCommandBuffer(&.{ .flags = .{ .one_time_submit = true } });

    const i = aquired.image_index;
    return .{
        .cmd = cmd,
        .image = self.swapchain.images[i],
        .view = self.swapchain.views[i],
        .extent = self.swapchain.extent,
        .image_index = i,
    };
}

pub fn endFrame(self: *Renderer, frame: *Frame) !void {
    const device = &self.ctx.device;
    const slot = self.slots[self.current];

    frame.transition(.present_src_khr);
    try frame.cmd.endCommandBuffer();

    const render_done = self.swapchain.render_finished[frame.image_index];
    const submit: vk.SubmitInfo = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&slot.image_available),
        .p_wait_dst_stage_mask = @ptrCast(&aquire_stage),
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&slot.cmd),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast(&render_done),
    };
    try device.queueSubmit(self.ctx.queue, &.{submit}, slot.in_flight);

    const result = device.queuePresentKHR(self.ctx.queue, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&render_done),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&self.swapchain.handle),
        .p_image_indices = @ptrCast(&frame.image_index),
    }) catch |err| switch (err) {
        error.OutOfDateKHR => vk.Result.suboptimal_khr,
        else => return err,
    };
    if (result == .suboptimal_khr) self.needs_recreate = true;

    self.current = (self.current + 1) % max_frames_in_flight;
}
