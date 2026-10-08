const std = @import("std");
const vk = @import("vulkan");
const Context = @import("Context.zig");

const Pipeline = @This();

pub const Blend = enum {
    /// Overwrite the destination.
    disabled,
    /// Straight alpha: src.rgb * src.a + dst.rgb * (1 - src.a)
    alpha,
    /// premultiplied alpha: src.rgb + dst.rgb * (1 - src.a)
    premultiplied,
    /// Glows, particles.
    additive,
};

pub const Depth = struct {
    test_enable: bool = false,
    write: bool = false,
    compare: vk.CompareOp = .less,

    pub const off: Depth = .{};
    pub const standard: Depth = .{ .test_enable = true, .write = true, .compare = .less };
    /// Test but don't write
    pub const read_only: Depth = .{ .test_enable = true, .write = false, .compare = .less };
};

pub const Desc = struct {
    vert: []const u32,
    frag: []const u32,
    color_format: vk.Format,
    /// `null` = no depth attachment: (UI, fullscreen passes).
    depth_format: ?vk.Format = null,
    vertex_stride: u32 = 0,
    vertex_attributes: []const vk.VertexInputAttributeDescription = &.{},
    topology: vk.PrimitiveTopology = .triangle_list,
    cull_mode: vk.CullModeFlags = .{},
    front_face: vk.FrontFace = .clockwise,
    polygon_mode: vk.PolygonMode = .fill,
    depth: Depth = .off,
    blend: Blend = .disabled,
    samples: vk.SampleCountFlags = .{ .@"1" = true },

    push_constants: []const vk.PushConstantRange = &.{},
    set_layouts: []const vk.DescriptorSetLayout = &.{},

    /// 3D viewport: depth tested + back-face culled, opaque.
    pub fn viewport(vert: []const u32, frag: []const u32, color_format: vk.Format, depth_format: vk.Format) Desc {
        return .{
            .vert = vert,
            .frag = frag,
            .color_format = color_format,
            .depth_format = depth_format,
            .depth = .standard,
            .cull_mode = .{ .back_bit = true },
            .front_face = .counter_clockwise,
            .blend = .disabled,
        };
    }

    /// UI / 2D overlay: no depth, no culling, alpha blending.
    pub fn ui(vert: []const u32, frag: []const u32, color_format: vk.Format) Desc {
        return .{
            .vert = vert,
            .frag = frag,
            .color_format = color_format,
            .depth_format = null,
            .depth = .off,
            .cull_mode = .{},
            .blend = .alpha,
        };
    }

    /// fullscreen / post-process: no-depth, no vertex buffer, opaque.
    pub fn fullscreen(vert: []const u32, frag: []const u32, color_format: vk.Format) Desc {
        return .{
            .vert = vert,
            .frag = frag,
            .color_format = color_format,
        };
    }

    /// Derive stride + attributes from extern struct e.g `.withVertex(Vertex)`.
    pub fn withVertex(self: Desc, comptime T: type, comptime fields: []const []const u8) Desc {
        const L = VertexLayout(T, fields);
        var d = self;
        d.vertex_stride = L.stride;
        d.vertex_attributes = &L.attributes;
        return d;
    }

    pub fn withPushConstants(self: Desc, ranges: []const vk.PushConstantRange) Desc {
        var d = self;
        d.push_constants = ranges;
        return d;
    }

    pub fn withSetLayouts(self: Desc, layouts: []const vk.DescriptorSetLayout) Desc {
        var d = self;
        d.set_layouts = layouts;
        return d;
    }

    pub fn withBlend(self: Desc, blend: Blend) Desc {
        var d = self;
        d.blend = blend;
        return d;
    }

    pub fn withWireframe(self: Desc) Desc {
        var d = self;
        d.polygon_mode = .line;
        return d;
    }
};

/// Comptime vertex layout: one attribute per field, location = field index.
pub fn VertexLayout(comptime T: type, comptime fields: []const []const u8) type {
    return struct {
        pub const stride: u32 = @sizeOf(T);
        pub const attributes: [fields.len]vk.VertexInputAttributeDescription = blk: {
            var out: [fields.len]vk.VertexInputAttributeDescription = undefined;
            for (fields, 0..) |f, i| {
                out[i] = .{
                    .location = @intCast(i),
                    .binding = 0,
                    .format = formatOf(@FieldType(T, f)),
                    .offset = @offsetOf(T, f),
                };
            }
            break :blk out;
        };
    };
}

fn formatOf(comptime T: type) vk.Format {
    return switch (T) {
        f32 => .r32_sfloat,
        [2]f32 => .r32g32_sfloat,
        [3]f32 => .r32g32b32_sfloat,
        [4]f32 => .r32g32b32a32_sfloat,
        u32 => .r32_uint,
        [4]u8 => .r8g8b8a8_unorm, // packed colors
        else => @compileError("No vertex format for " ++ @typeName(T)),
    };
}

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

    const layout = try ctx.device.createPipelineLayout(&.{
        .set_layout_count = @intCast(desc.set_layouts.len),
        .p_set_layouts = desc.set_layouts.ptr,
        .push_constant_range_count = @intCast(desc.push_constants.len),
        .p_push_constant_ranges = desc.push_constants.ptr,
    }, null);
    errdefer ctx.device.destroyPipelineLayout(layout, null);

    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex = true }, .module = vert, .p_name = "main" },
        .{ .stage = .{ .fragment = true }, .module = frag, .p_name = "main" },
    };

    const blend_attachment = blendState(desc.blend);

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
        .depth_attachment_format = desc.depth_format orelse .undefined,
        .stencil_attachment_format = .undefined,
    };

    const no_stencil: vk.StencilOpState = .{
        .fail_op = .keep,
        .pass_op = .keep,
        .depth_fail_op = .keep,
        .compare_op = .always,
        .compare_mask = 0,
        .write_mask = 0,
        .reference = 0,
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
            .topology = desc.topology,
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
            .polygon_mode = desc.polygon_mode,
            .cull_mode = desc.cull_mode,
            .front_face = desc.front_face,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        },
        .p_multisample_state = &.{
            .rasterization_samples = desc.samples,
            .sample_shading_enable = .false,
            .min_sample_shading = 1,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        },
        .p_depth_stencil_state = if (desc.depth_format != null) &.{
            .depth_test_enable = vk.Bool32.fromBool(desc.depth.test_enable),
            .depth_write_enable = vk.Bool32.fromBool(desc.depth.write),
            .depth_compare_op = desc.depth.compare,
            .depth_bounds_test_enable = .false,
            .stencil_test_enable = .false,
            .front = no_stencil,
            .back = no_stencil,
            .min_depth_bounds = 0,
            .max_depth_bounds = 1,
        } else null,
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

pub fn blendState(mode: Blend) vk.PipelineColorBlendAttachmentState {
    const all: vk.ColorComponentFlags = .{ .r = true, .g = true, .b = true, .a = true };
    return switch (mode) {
        .disabled => .{
            .blend_enable = .false,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = all,
        },
        .alpha => .{
            .blend_enable = .true,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one_minus_src_alpha,
            .alpha_blend_op = .add,
            .color_write_mask = all,
        },
        .premultiplied => .{
            .blend_enable = .true,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one_minus_src_alpha,
            .alpha_blend_op = .add,
            .color_write_mask = all,
        },
        .additive => .{
            .blend_enable = .true,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one,
            .alpha_blend_op = .add,
            .color_write_mask = all,
        },
    };
}

fn createShaderModule(ctx: *const Context, code: []const u32) !vk.ShaderModule {
    return ctx.device.createShaderModule(&.{
        .code_size = code.len * @sizeOf(u32),
        .p_code = code.ptr,
    }, null);
}
