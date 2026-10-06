const std = @import("std");
const vk = @import("vulkan");
const Context = @import("Context.zig");

const Pipeline = @This();

pub const Desc = struct {
    vert: []const u32,
    frag: []const u32,
    color_format: vk.Format,
    vertex_stride: u32 = 0,
    vertex_attributes: []const vk.VertexInputAttributeDescription = &.{},
};

ctx: *const Context,
layout: vk.PipelineLayout,
handle: vk.Pipeline,

/// allows for embedSpirv("shaders/triangles/triangle.vert.spv");
/// replaces #load in odin
pub fn embedSpirv(comptime name: []const u8) []const u32 {
    const Storage = struct {
        const bytes align(@alignOf(u32)) = @embedFile(name).*;
    };
    return std.mem.bytesAsSlice(u32, &Storage.bytes);
}

pub fn init(ctx: *const Context, desc: Desc) !Pipeline {
    const vert = try createShaderModule(ctx, desc.vert);
    defer ctx.device.destroyShaderModule(vert, null);
    const frag = try createShaderModule(ctx, desc.frag);
    defer ctx.device.destroyShaderModule(frag, null);

    const layout = try ctx.device.createPipelineLayout(&.{}, null);
    // defer ctx.device.destroyPipelineLayout(layout, null);

    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex = true }, .module = vert, .p_name = "main" },
        .{ .stage = .{ .fragment = true }, .module = frag, .p_name = "main" },
    };

    const blend_attachment: vk.PipelineColorBlendAttachmentState = .{
        .blend_enable = .true,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r = true, .g = true, .b = true, .a = true },
    };

    const vertex_binding: vk.VertexInputBindingDescription = .{
        .binding = 0,
        .stride = desc.vertex_stride,
        .input_rate = .vertex,
    };

    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };

    const rendering_info = vk.PipelineRenderingCreateInfo{
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachment_formats = @ptrCast(&desc.color_format),
        .depth_attachment_format = .undefined,
        .stencil_attachment_format = .undefined,
    };

    const create_info: vk.GraphicsPipelineCreateInfo = .{
        .p_next = &rendering_info,
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &.{
            .vertex_binding_description_count = if (desc.vertex_stride > 0) 1 else 0,
            .p_vertex_binding_descriptions = @ptrCast(&vertex_binding),
            .vertex_attribute_description_count = @intCast(desc.vertex_attributes.len),
            .p_vertex_attribute_descriptions = desc.vertex_attributes.ptr,
        },
        .p_input_assembly_state = &.{
            .topology = .triangle_list,
            .primitive_restart_enable = .false,
        },
        .p_tessellation_state = null,
        .p_viewport_state = &.{
            .viewport_count = 1,
            .scissor_count = 1,
        },
        .p_rasterization_state = &.{
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = .{},
            .front_face = .clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        },
        .p_multisample_state = &.{
            .rasterization_samples = .{ .@"1" = true },
            .sample_shading_enable = .false,
            .min_sample_shading = 1,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        },
        .p_depth_stencil_state = null,
        .p_color_blend_state = &.{
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&blend_attachment),
            .blend_constants = .{ 0, 0, 0, 0 },
        },
        .p_dynamic_state = &.{
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = &dynamic_states,
        },
        .layout = layout,
        .render_pass = .null_handle,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipelines: [1]vk.Pipeline = undefined;
    _ = try ctx.device.createGraphicsPipelines(.null_handle, &.{create_info}, null, &pipelines);

    return .{ .ctx = ctx, .layout = layout, .handle = pipelines[0] };
}

pub fn deinit(self: *Pipeline) void {
    self.ctx.device.destroyPipeline(self.handle, null);
    self.ctx.device.destroyPipelineLayout(self.layout, null);
}

fn createShaderModule(ctx: *const Context, code: []const u32) !vk.ShaderModule {
    return ctx.device.createShaderModule(&.{
        .code_size = code.len * @sizeOf(u32),
        .p_code = code.ptr,
    }, null);
}
