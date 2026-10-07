const std = @import("std");
const vk = @import("vulkan");
const Context = @import("Context.zig");
const Buffer = @import("Buffer.zig");

const ComputePipeline = @This();

const max_bindings = 8;

pub const Desc = struct {
    comp: []const u32,
    storage_buffer_count: u32 = 1,
    push_constant_size: u32 = 0,
};

ctx: *const Context,
set_layout: vk.DescriptorSetLayout,
layout: vk.PipelineLayout,
handle: vk.Pipeline,
pool: vk.DescriptorPool,
set: vk.DescriptorSet,

pub fn init(ctx: *const Context, desc: Desc) !ComputePipeline {
    std.debug.assert(desc.storage_buffer_count > 0 and desc.storage_buffer_count <= max_bindings);
    const n = desc.storage_buffer_count;

    const module = try ctx.device.createShaderModule(&.{
        .code_size = desc.comp.len * @sizeOf(u32),
        .p_code = desc.comp.ptr,
    }, null);
    defer ctx.device.destroyShaderModule(module, null);

    var bindings: [max_bindings]vk.DescriptorSetLayoutBinding = undefined;
    for (bindings[0..n], 0..) |*b, i| {
        b.* = .{
            .binding = @intCast(i),
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .compute = true },
        };
    }
    const set_layout = try ctx.device.createDescriptorSetLayout(&.{
        .binding_count = n,
        .p_bindings = &bindings,
    }, null);
    errdefer ctx.device.destroyDescriptorSetLayout(set_layout, null);

    const push_range: vk.PushConstantRange = .{
        .stage_flags = .{ .compute = true },
        .offset = 0,
        .size = desc.push_constant_size,
    };
    const layout = try ctx.device.createPipelineLayout(&.{
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&set_layout),
        .push_constant_range_count = if (desc.push_constant_size > 0) 1 else 0,
        .p_push_constant_ranges = @ptrCast(&push_range),
    }, null);
    errdefer ctx.device.destroyPipelineLayout(layout, null);

    const create_info: vk.ComputePipelineCreateInfo = .{
        .stage = .{
            .stage = .{ .compute = true },
            .module = module,
            .p_name = "main",
        },
        .layout = layout,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };
    var pipelines: [1]vk.Pipeline = undefined;
    _ = try ctx.device.createComputePipelines(.null_handle, &.{create_info}, null, &pipelines);
    errdefer ctx.device.destroyPipeline(pipelines[0], null);

    const pool_size: vk.DescriptorPoolSize = .{
        .type = .storage_buffer,
        .descriptor_count = n,
    };
    const pool = try ctx.device.createDescriptorPool(&.{
        .max_sets = 1,
        .pool_size_count = 1,
        .p_pool_sizes = @ptrCast(&pool_size),
    }, null);
    errdefer ctx.device.destroyDescriptorPool(pool, null);

    var sets: [1]vk.DescriptorSet = undefined;
    try ctx.device.allocateDescriptorSets(&.{
        .descriptor_pool = pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&set_layout),
    }, &sets);

    return .{
        .ctx = ctx,
        .set_layout = set_layout,
        .layout = layout,
        .handle = pipelines[0],
        .pool = pool,
        .set = sets[0],
    };
}

pub fn deinit(self: *ComputePipeline) void {
    const d = &self.ctx.device;
    d.destroyDescriptorPool(self.pool, null);
    d.destroyPipeline(self.handle, null);
    d.destroyPipelineLayout(self.layout, null);
    d.destroyDescriptorSetLayout(self.set_layout, null);
}

pub fn bindStorageBuffer(self: *ComputePipeline, binding: u32, buffer: *const Buffer) void {
    const info: vk.DescriptorBufferInfo = .{
        .buffer = buffer.handle,
        .offset = 0,
        .range = vk.WHOLE_SIZE,
    };
    const write: vk.WriteDescriptorSet = .{
        .dst_set = self.set,
        .dst_binding = binding,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .storage_buffer,
        .p_image_info = undefined,
        .p_buffer_info = @ptrCast(&info),
        .p_texel_buffer_view = undefined,
    };
    self.ctx.device.updateDescriptorSets(&.{write}, &.{});
}

pub fn bind(self: *const ComputePipeline, cmd: Context.CommandBuffer) void {
    cmd.bindPipeline(.compute, self.handle);
    cmd.bindDescriptorSets(.compute, self.layout, 0, &.{self.set}, &.{});
}

pub fn push(self: *const ComputePipeline, cmd: Context.CommandBuffer, comptime T: type, value: *const T) void {
    cmd.pushConstants(self.layout, .{ .compute = true }, 0, @sizeOf(T), value);
}

pub fn dispatch(self: *const ComputePipeline, cmd: Context.CommandBuffer, x: u32, y: u32, z: u32) void {
    _ = self;
    cmd.dispatch(x, y, z);
}

pub fn groups(items: u32, local_size: u32) u32 {
    return (items + local_size - 1) / local_size;
}

pub fn memoryBarrier(
    cmd: Context.CommandBuffer,
    src_stage: vk.PipelineStageFlags,
    src_access: vk.AccessFlags,
    dst_stage: vk.PipelineStageFlags,
    dst_access: vk.AccessFlags,
) void {
    const b: vk.MemoryBarrier = .{
        .src_access_mask = src_access,
        .dst_access_mask = dst_access,
    };
    cmd.pipelineBarrier(src_stage, dst_stage, .{}, &.{b}, &.{}, &.{});
}

pub fn barrierVertexToCompute(cmd: Context.CommandBuffer) void {
    memoryBarrier(
        cmd,
        .{ .vertex_input = true },
        .{},
        .{ .compute_shader = true },
        .{},
    );
}

pub fn barrierComputeToVertex(cmd: Context.CommandBuffer) void {
    memoryBarrier(
        cmd,
        .{ .compute_shader = true },
        .{ .shader_write = true },
        .{ .vertex_input = true },
        .{ .vertex_attribute_read = true },
    );
}
