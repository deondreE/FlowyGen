const std = @import("std");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;

const Context = @import("Context.zig");
const Pipeline = @import("Pipeline.zig");
const Buffer = @import("Buffer.zig");
const Texture = @import("Texture.zig");
const Font = @import("stb_zig.zig").Font;

const TextRenderer = @This();

pub const Color = [4]u8;

pub const Vertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: Color,
};

/// Match this to the number of frames your Renderer keeps in flight. Each slot
/// has its own vertex buffer so we never overwrite data the GPU is still reading.
pub const frames_in_flight = 2;

const atlas_size = 512;
const first_char = 32;
const last_char = 126;

const Glyph = struct {
    u0: f32 = 0,
    v0: f32 = 0,
    u1: f32 = 0,
    v1: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    x_off: f32 = 0,
    y_off: f32 = 0,
    advance: f32 = 0,
};

ctx: *const Context,
allocator: Allocator,
atlas: Texture,
glyphs: [last_char + 1]Glyph,
/// Distance from the top of a line to its baseline, in pixels.
ascent: f32,
line_height: f32,

set_layout: vk.DescriptorSetLayout,
pool: vk.DescriptorPool,
set: vk.DescriptorSet,
pipeline: Pipeline,

buffers: [frames_in_flight]Buffer,
verts: []Vertex,
count: usize,
slot: usize,

pub fn init(
    ctx: *const Context,
    allocator: Allocator,
    color_format: vk.Format,
    font: *const Font,
    pixel_height: f32,
    max_chars: usize,
) !TextRenderer {
    // ---- bake ASCII into an R8 atlas --------------------------------------
    const scale = font.scaleForPixelHeight(pixel_height);
    const metrics = font.getMetrics();

    const pixels = try allocator.alloc(u8, atlas_size * atlas_size);
    defer allocator.free(pixels);
    @memset(pixels, 0);

    var glyphs: [last_char + 1]Glyph = @splat(.{});
    const atlas_f: f32 = @floatFromInt(atlas_size);

    var x: usize = 1;
    var y: usize = 1;
    var row_h: usize = 0;
    var cp: u21 = first_char;
    while (cp <= last_char) : (cp += 1) {
        const bmp = try font.renderGlyphBitmap(allocator, cp, scale);
        defer bmp.deinit(allocator);

        const w: usize = @intCast(bmp.width);
        const h: usize = @intCast(bmp.height);

        if (x + w + 1 > atlas_size) {
            x = 1;
            y += row_h + 1;
            row_h = 0;
        }
        if (y + h + 1 > atlas_size) return error.AtlasFull;

        for (0..h) |row| {
            const dst = (y + row) * atlas_size + x;
            @memcpy(pixels[dst..][0..w], bmp.pixels[row * w ..][0..w]);
        }

        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        glyphs[cp] = .{
            .u0 = fx / atlas_f,
            .v0 = fy / atlas_f,
            .u1 = (fx + @as(f32, @floatFromInt(w))) / atlas_f,
            .v1 = (fy + @as(f32, @floatFromInt(h))) / atlas_f,
            .width = @floatFromInt(w),
            .height = @floatFromInt(h),
            .x_off = @floatFromInt(bmp.x_offset),
            .y_off = @floatFromInt(bmp.y_offset),
            .advance = @as(f32, @floatFromInt(font.getAdvance(cp))) * scale,
        };

        x += w + 1;
        row_h = @max(row_h, h);
    }

    var atlas = try Texture.initR8(ctx, atlas_size, atlas_size, pixels);
    errdefer atlas.deinit();

    // ---- descriptor set for the atlas -------------------------------------
    const binding = [_]vk.DescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .fragment = true },
    }};
    const set_layout = try ctx.device.createDescriptorSetLayout(&.{
        .binding_count = binding.len,
        .p_bindings = &binding,
    }, null);
    errdefer ctx.device.destroyDescriptorSetLayout(set_layout, null);

    const pool_sizes = [_]vk.DescriptorPoolSize{.{ .type = .combined_image_sampler, .descriptor_count = 1 }};
    const pool = try ctx.device.createDescriptorPool(&.{
        .max_sets = 1,
        .pool_size_count = pool_sizes.len,
        .p_pool_sizes = &pool_sizes,
    }, null);
    errdefer ctx.device.destroyDescriptorPool(pool, null);

    var set: vk.DescriptorSet = undefined;
    try ctx.device.allocateDescriptorSets(&.{
        .descriptor_pool = pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&set_layout),
    }, @ptrCast(&set));

    const image_info: vk.DescriptorImageInfo = .{
        .sampler = atlas.sampler,
        .image_view = atlas.view,
        .image_layout = .shader_read_only_optimal,
    };
    const write: vk.WriteDescriptorSet = .{
        .dst_set = set,
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .p_image_info = @ptrCast(&image_info),
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    };
    ctx.device.updateDescriptorSets(@ptrCast(&write), null);

    // ---- pipeline ---------------------------------------------------------
    const layouts = [_]vk.DescriptorSetLayout{set_layout};
    const push_ranges = [_]vk.PushConstantRange{.{
        .stage_flags = .{ .vertex = true },
        .offset = 0,
        .size = @sizeOf([2]f32), // screen size in pixels
    }};
    var pipeline = try Pipeline.init(
        ctx,
        Pipeline.Desc.ui(
            Pipeline.embedSpirv("shaders/text.vert.spv"),
            Pipeline.embedSpirv("shaders/text.frag.spv"),
            color_format,
        )
            .withVertex(Vertex, &.{ "pos", "uv", "color" })
            .withSetLayouts(&layouts)
            .withPushConstants(&push_ranges),
    );
    errdefer pipeline.deinit();

    // ---- per-frame vertex buffers -----------------------------------------
    const max_vertices = max_chars * 6;
    const verts = try allocator.alloc(Vertex, max_vertices);
    errdefer allocator.free(verts);

    var buffers: [frames_in_flight]Buffer = undefined;
    var made: usize = 0;
    errdefer for (buffers[0..made]) |*b| b.deinit();
    while (made < frames_in_flight) : (made += 1) {
        buffers[made] = try Buffer.init(ctx, max_vertices * @sizeOf(Vertex), .{ .vertex_buffer = true }, .host);
    }

    const ascent_px = @as(f32, @floatFromInt(metrics.ascent)) * scale;
    const descent_px = @as(f32, @floatFromInt(metrics.descent)) * scale;
    const gap_px = @as(f32, @floatFromInt(metrics.line_gap)) * scale;

    return .{
        .ctx = ctx,
        .allocator = allocator,
        .atlas = atlas,
        .glyphs = glyphs,
        .ascent = @round(ascent_px),
        .line_height = @round(ascent_px - descent_px + gap_px),
        .set_layout = set_layout,
        .pool = pool,
        .set = set,
        .pipeline = pipeline,
        .buffers = buffers,
        .verts = verts,
        .count = 0,
        .slot = 0,
    };
}

pub fn deinit(self: *TextRenderer) void {
    for (&self.buffers) |*b| b.deinit();
    self.allocator.free(self.verts);
    self.pipeline.deinit();
    self.ctx.device.destroyDescriptorPool(self.pool, null); // frees the set too
    self.ctx.device.destroyDescriptorSetLayout(self.set_layout, null);
    self.atlas.deinit();
}

/// Start a new frame's worth of text. `frame_index` is any increasing counter.
pub fn begin(self: *TextRenderer, frame_index: u64) void {
    self.slot = @intCast(frame_index % frames_in_flight);
    self.count = 0;
}

/// Width in pixels of the widest line of `text`.
pub fn measure(self: *const TextRenderer, text: []const u8) f32 {
    var widest: f32 = 0;
    var line: f32 = 0;
    for (text) |ch| {
        if (ch == '\n') {
            widest = @max(widest, line);
            line = 0;
            continue;
        }
        line += self.glyphFor(ch).advance;
    }
    return @max(widest, line);
}

/// Queue `text` with its top-left corner at (x, y) in framebuffer pixels.
/// ASCII only for now; '\n' starts a new line; unknown bytes draw '?'.
pub fn draw(self: *TextRenderer, x: f32, y: f32, text: []const u8, color: Color) void {
    var pen_x = x;
    var baseline = y + self.ascent;

    for (text) |ch| {
        if (ch == '\n') {
            pen_x = x;
            baseline += self.line_height;
            continue;
        }
        const g = self.glyphFor(ch);

        if (g.width > 0) {
            if (self.count + 6 > self.verts.len) return; // out of room: drop the rest
            const x0 = @round(pen_x + g.x_off);
            const y0 = @round(baseline + g.y_off);
            const x1 = x0 + g.width;
            const y1 = y0 + g.height;

            const tl: Vertex = .{ .pos = .{ x0, y0 }, .uv = .{ g.u0, g.v0 }, .color = color };
            const tr: Vertex = .{ .pos = .{ x1, y0 }, .uv = .{ g.u1, g.v0 }, .color = color };
            const bl: Vertex = .{ .pos = .{ x0, y1 }, .uv = .{ g.u0, g.v1 }, .color = color };
            const br: Vertex = .{ .pos = .{ x1, y1 }, .uv = .{ g.u1, g.v1 }, .color = color };

            const out = self.verts[self.count..][0..6];
            out.* = .{ tl, tr, br, tl, br, bl };
            self.count += 6;
        }
        pen_x += g.advance;
    }
}

/// printf-style helper: `text.print(16, 16, white, "FPS {d:.0}", .{fps})`.
pub fn print(self: *TextRenderer, x: f32, y: f32, color: Color, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    self.draw(x, y, text, color);
}

/// Upload this frame's quads and record the draw. Call inside beginRendering/endRendering.
/// `frame` needs bindPipeline, bindDescriptorSet, pushConstants, bindVertexBuffer and draw.
pub fn record(self: *TextRenderer, frame: anytype, screen_width: f32, screen_height: f32) !void {
    if (self.count == 0) return;
    const buf = &self.buffers[self.slot];
    try buf.write(std.mem.sliceAsBytes(self.verts[0..self.count]));

    const screen = [2]f32{ screen_width, screen_height };
    frame.bindPipeline(&self.pipeline);
    frame.bindDescriptorSets(&self.pipeline, self.set);
    frame.pushConstants(&self.pipeline, .{ .vertex = true }, [2]f32, &screen);
    frame.bindVertexBuffer(buf);
    frame.draw(@intCast(self.count));
}

fn glyphFor(self: *const TextRenderer, ch: u8) Glyph {
    if (ch < first_char or ch > last_char) return self.glyphs['?'];
    return self.glyphs[ch];
}
