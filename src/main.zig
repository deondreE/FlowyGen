const std = @import("std");
const Io = std.Io;

const Window = @import("window.zig");
const Context = @import("Context.zig");
const Swapchain = @import("Swapchain.zig");
const Renderer = @import("Renderer.zig");
const Pipeline = @import("Pipeline.zig");
const Buffer = @import("Buffer.zig");
const flowygen = @import("flowygen");

// We are going to need a true concept of delta.

const Vertex = extern struct {
    pos: [2]f32,
    color: [3]f32,
};

const vertices = [_]Vertex{
    .{ .pos = .{ 0.0, -0.5 }, .color = .{ 1, 0, 0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0, 1, 0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0, 0, 1 } },
};

const App = struct {
    frame: u64 = 0,
    renderer: ?*Renderer = null,
    pipeline: ?*Pipeline = null,
    vertex_buffer: ?*Buffer = null,
};

fn drawFrame(window: *Window, app: *App) !void {
    const renderer = app.renderer orelse return;
    const pipeline = app.pipeline orelse return;
    const vertex_buffer = app.vertex_buffer orelse return;

    var frame = (try renderer.beginFrame(window)) orelse return;

    const t: f32 = @floatFromInt(app.frame);
    const pulse = 0.5 + 0.5 * @sin(t * 0.00015);

    frame.beginRendering(.{ 0.04, 0.06 + 0.06 * pulse, 0.12 + 0.10 * pulse, 1.0 });
    frame.bindPipeline(pipeline);
    frame.bindVertexBuffer(vertex_buffer);
    frame.draw(3);
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

    var app: App = .{};
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

    var vertex_buffer: Buffer = try Buffer.fromSlice(&context, Vertex, &vertices, .{ .vertex_buffer = true });
    defer vertex_buffer.deinit();

    var pipeline: Pipeline = try Pipeline.init(&context, .{
        .vert = Pipeline.embedSpirv("shaders/triangle.vert.spv"),
        .frag = Pipeline.embedSpirv("shaders/triangle.frag.spv"),
        .color_format = swapchain.format,
    });
    defer pipeline.deinit();

    var renderer: Renderer = try Renderer.init(&context, &swapchain);
    defer renderer.deinit();

    app.renderer = &renderer;
    app.pipeline = &pipeline;
    app.vertex_buffer = &vertex_buffer;

    while (!window.shouldClose()) {
        window.pollEvents();
        redraw(&window);
    }
}
