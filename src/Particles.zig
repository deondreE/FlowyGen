const std = @import("std");
const vk = @import("vulkan");
const Context = @import("Context.zig");
const Buffer = @import("Buffer.zig");
const Pipeline = @import("Pipeline.zig");
const ComputePipeline = @import("ComputePipeline.zig");
const Frame = @import("Renderer.zig").Frame;

const Particles = @This();

pub const Particle = extern struct {
    pos: [2]f32,
    vel: [2]f32,

    age: f32,
    lifetime: f32,
};

const SimPush = extern struct {
    dt: f32,
    time: f32,
    count: u32,
    flags: u32,
};

const DrawPush = extern struct {
    half_size: [2]f32,
};

const local_size = 256;
const flag_init: u32 = 1;
const max_dt: f32 = 1.0 / 30.0;

ctx: *const Context,
count: u32,
radius_px: f32 = 2.0,
initialized: bool = false,

buffer: Buffer,
sim: ComputePipeline,

draw_set_layout: vk.DescriptorSetLayout,
draw_pool: vk.DescriptorPool,
draw_set: vk.DescriptorSet,
draw_pipeline: Pipeline,

pub fn init(ctx: *const Context, color_format: vk.Format, count: u32) !Particles {
    var buffer = try Buffer.init(
        ctx,
        @sizeOf(Particle) * @as(vk.DeviceSize, count),
        .{ .storage_buffer = true },
        .device,
    );
    errdefer buffer.deinit();

    var sim = try ComputePipeline.init(ctx, .{
        .comp = Pipeline.embedSpirv("shaders/particles.comp.spv"),
        .storage_buffer_count = 1,
        .push_constant_size = @sizeOf(SimPush),
    });
    errdefer sim.deinit();
    sim.bindStorageBuffer(0, &buffer);

    const binding: vk.DescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .vertex = true },
    };
    const set_layout = try ctx.device.createDescriptorSetLayout(&.{
        .binding_count = 1,
        .p_bindings = @ptrCast(&binding),
    }, null);
    errdefer ctx.device.destroyDescriptorSetLayout(set_layout, null);

    const pool_size: vk.DescriptorPoolSize = .{ .type = .storage_buffer, .descriptor_count = 1 };
    const pool = try ctx.device.createDescriptorPool(&.{
        .max_sets = 1,
        .pool_size_count = 1,
        .p_pool_sizes = @ptrCast(&pool_size),
    }, null);

    var sets: [1]vk.DescriptorSet = undefined;
    try ctx.device.allocateDescriptorSets(&.{
        .descriptor_pool = pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&set_layout),
    }, &sets);

    const info: vk.DescriptorBufferInfo = .{
        .buffer = buffer.handle,
        .offset = 0,
        .range = vk.WHOLE_SIZE,
    };
    const write: vk.WriteDescriptorSet = .{
        .dst_set = sets[0],
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .storage_buffer,
        .p_image_info = undefined,
        .p_buffer_info = @ptrCast(&info),
        .p_texel_buffer_view = undefined,
    };
    ctx.device.updateDescriptorSets(&.{write}, &.{});

    const layouts = [_]vk.DescriptorSetLayout{set_layout};
    const ranges = [_]vk.PushConstantRange{.{
        .stage_flags = .{ .vertex = true },
        .offset = 0,
        .size = @sizeOf(DrawPush),
    }};
    var draw_pipeline = try Pipeline.init(
        ctx,
        Pipeline.Desc.fullscreen(
            Pipeline.embedSpirv("shaders/particles.vert.spv"),
            Pipeline.embedSpirv("shaders/particles.frag.spv"),
            color_format,
        ).withBlend(.additive).withSetLayouts(&layouts).withPushConstants(&ranges),
    );
    errdefer draw_pipeline.deinit();

    return .{
        .ctx = ctx,
        .count = count,
        .buffer = buffer,
        .sim = sim,
        .draw_set_layout = set_layout,
        .draw_pool = pool,
        .draw_set = sets[0],
        .draw_pipeline = draw_pipeline,
    };
}

pub fn deinit(self: *Particles) void {
    self.draw_pipeline.deinit();
    self.ctx.device.destroyDescriptorPool(self.draw_pool, null);
    self.ctx.device.destroyDescriptorSetLayout(self.draw_set_layout, null);
    self.sim.deinit();
    self.buffer.deinit();
}

pub fn update(self: *Particles, frame: *Frame, dt: f32, time: f32) void {
    const cmd = frame.cmd;

    ComputePipeline.memoryBarrier(
        cmd,
        .{ .vertex_shader = true, .compute_shader = true },
        .{ .shader_write = true },
        .{ .compute_shader = true },
        .{ .shader_read = true, .shader_write = true },
    );

    self.sim.bind(cmd);
    const pc: SimPush = .{
        .dt = @min(dt, max_dt),
        .time = time,
        .count = self.count,
        .flags = if (self.initialized) 0 else flag_init,
    };
    self.sim.push(cmd, SimPush, &pc);
    self.sim.dispatch(cmd, ComputePipeline.groups(self.count, local_size), 1, 1);
    self.initialized = true;

    ComputePipeline.memoryBarrier(
        cmd,
        .{ .compute_shader = true },
        .{ .shader_write = true },
        .{ .vertex_shader = true },
        .{ .shader_read = true },
    );
}

pub fn draw(self: *const Particles, frame: *Frame) void {
    frame.bindPipeline(&self.draw_pipeline);
    frame.cmd.bindDescriptorSets(.graphics, self.draw_pipeline.layout, 0, &.{self.draw_set}, &.{});

    const w: f32 = @floatFromInt(frame.extent.width);
    const h: f32 = @floatFromInt(frame.extent.height);
    const push: DrawPush = .{ .half_size = .{ 2.0 / self.radius_px / w, 2.0 * self.radius_px / h } };
    frame.pushConstants(&self.draw_pipeline, .{ .vertex = true }, DrawPush, &push);

    frame.draw(self.count * 6);
}
