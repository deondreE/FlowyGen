const std = @import("std");
const Io = std.Io;

const Window = @import("window.zig");
const Context = @import("Context.zig");
const Swapchain = @import("Swapchain.zig");
const Renderer = @import("Renderer.zig");
const Pipeline = @import("Pipeline.zig");
const ComputePipeline = @import("ComputePipeline.zig");
const Buffer = @import("Buffer.zig");
const Time = @import("Time.zig");
const TextRenderer = @import("TextRenderer.zig");
const Font = @import("stb_zig.zig").Font;
const Particles = @import("Particles.zig");
const flowygen = @import("flowygen");

const particle_count = 100_000;
const font_data = @embedFile("fonts/Roboto.ttf");

const Vertex = extern struct {
    pos: [2]f32,
    color: [3]f32,
};

const vertices = [_]Vertex{
    .{ .pos = .{ 0.0, -0.5 }, .color = .{ 1, 0, 0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0, 1, 0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0, 0, 1 } },
};

const UIVertex = extern struct {
    pos: [2]f32,
    color: [4]u8,
};

// @Todo: Remove this later
const panel_color = [4]u8{ 20, 24, 40, 170 };
const ui_vertices = [_]UIVertex{
    .{ .pos = .{ -0.95, -0.95 }, .color = panel_color },
    .{ .pos = .{ -0.45, -0.95 }, .color = panel_color },
    .{ .pos = .{ -0.45, -0.60 }, .color = panel_color },
    .{ .pos = .{ -0.95, -0.95 }, .color = panel_color },
    .{ .pos = .{ -0.45, -0.60 }, .color = panel_color },
    .{ .pos = .{ -0.95, -0.60 }, .color = panel_color },
};

const App = struct {
    time: Time,
    frame: u64 = 0,
    renderer: ?*Renderer = null,
    scene_pipeline: ?*Pipeline = null,
    ui_pipeline: ?*Pipeline = null,
    vertex_buffer: ?*Buffer = null,
    ui_buffer: ?*Buffer = null,
    text: ?*TextRenderer = null,
    particles: ?*Particles = null,
    fps_log_timer: f64 = 0,
};

fn drawFrame(window: *Window, app: *App) !void {
    const renderer = app.renderer orelse return;
    const scene_pipeline = app.scene_pipeline orelse return;
    const ui_pipeline = app.ui_pipeline orelse return;
    const vertex_buffer = app.vertex_buffer orelse return;
    const ui_buffer = app.ui_buffer orelse return;
    const text = app.text orelse return;
    const particles = app.particles orelse return;

    app.time.tick();
    const dt: f32 = @floatCast(app.time.delta);

    app.fps_log_timer += app.time.raw_delta;
    if (app.fps_log_timer >= 1.0) {
        app.fps_log_timer = 0;
        std.log.info("FPS: {d}", .{app.time.fps()});
    }

    var frame = (try renderer.beginFrame(window)) orelse return;

    particles.update(&frame, dt, @floatCast(app.time.elapsed));

    const pulse = 0.5 + 0.5 * @as(f32, @floatCast(app.time.elapsed * 0.5));

    frame.beginRendering(.{ 0.04, 0.06 + 0.06 * pulse, 0.12 + 0.10 * pulse, 1.0 });

    // Scene
    frame.bindPipeline(scene_pipeline);
    frame.bindVertexBuffer(vertex_buffer);
    frame.draw(3);

    // Particles
    particles.draw(&frame);

    // UI
    frame.bindPipeline(ui_pipeline);
    frame.bindVertexBuffer(ui_buffer);
    frame.draw(ui_vertices.len);

    const fb = window.framebufferSize();
    text.begin(app.frame);
    text.draw(24, 22, "FlowyGen", .{ 235, 240, 255, 255 });
    text.print(24, 22 + text.line_height, .{ 150, 170, 210, 255 }, "FPS {d:.0}", .{app.time.fps()});
    try text.record(&frame, @floatFromInt(fb.width), @floatFromInt(fb.height));

    frame.endRendering();

    try renderer.endFrame(&frame);
    app.frame += 1;
}

fn redraw(window: *Window) void {
    if (window.isMinimized()) return;
    const app = window.userData(App) orelse return;

    drawFrame(window, app) catch |err| {
        std.log.err("Failed to draw frame: {}", .{err});
        window.close();
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var app: App = .{
        .time = Time.init(),
    };
    var window: Window = undefined;
    try window.init(.{
        .title = "FlowyGen",
        .width = 800,
        .height = 600,
        .on_redraw = redraw,
        .user_data = &app,
    });
    defer window.deinit();

    var context: Context = try Context.init(gpa, "FlowyGen", &window);
    defer context.deinit();

    var swapchain: Swapchain = try Swapchain.init(&context, gpa, &window);
    defer swapchain.deinit();

    var vertex_buffer: Buffer = try Buffer.fromSlice(&context, Vertex, &vertices, .{ .vertex_buffer = true, .storage_buffer = true });
    defer vertex_buffer.deinit();

    var ui_buffer: Buffer = try Buffer.fromSlice(&context, UIVertex, &ui_vertices, .{ .vertex_buffer = true });
    defer ui_buffer.deinit();

    var scene_pipeline: Pipeline = try Pipeline.init(
        &context,
        (Pipeline.Desc{
            .vert = Pipeline.embedSpirv("shaders/triangle.vert.spv"),
            .frag = Pipeline.embedSpirv("shaders/triangle.frag.spv"),
            .color_format = swapchain.format,
        }).withVertex(Vertex, &.{ "pos", "color" }),
    );
    defer scene_pipeline.deinit();

    var ui_pipeline: Pipeline = try Pipeline.init(
        &context,
        Pipeline.Desc.ui(
            Pipeline.embedSpirv("shaders/ui.vert.spv"),
            Pipeline.embedSpirv("shaders/ui.frag.spv"),
            swapchain.format,
        ).withVertex(UIVertex, &.{ "pos", "color" }),
    );
    defer ui_pipeline.deinit();

    var font: Font = try Font.init(font_data);
    var text: TextRenderer = try TextRenderer.init(&context, gpa, swapchain.format, &font, 24, 4096);
    defer text.deinit();

    var particles: Particles = try Particles.init(&context, swapchain.format, particle_count);
    defer particles.deinit();

    var renderer: Renderer = try Renderer.init(&context, &swapchain);
    defer renderer.deinit();

    app.renderer = &renderer;
    app.scene_pipeline = &scene_pipeline;
    app.vertex_buffer = &vertex_buffer;
    app.ui_pipeline = &ui_pipeline;
    app.ui_buffer = &ui_buffer;
    app.text = &text;
    app.particles = &particles;

    while (!window.shouldClose()) {
        if (window.isMinimized()) {
            window.waitEvents();
            continue;
        }

        window.pollEvents();
        redraw(&window);
    }
}
