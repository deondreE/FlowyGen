const std = @import("std");
const Io = std.Io;

const Window = @import("window.zig");
const Context = @import("Context.zig");
const Swapchain = @import("Swapchain.zig");
const Renderer = @import("Renderer.zig");
const Pipeline = @import("Pipeline.zig");
const flowygen = @import("flowygen");

// We are going to need a true concept of delta.

const App = struct {
    frame: u64 = 0,
    renderer: ?*Renderer = null,
    pipeline: ?*Pipeline = null,
};

fn drawFrame(window: *Window, app: *App) !void {
    const renderer = app.renderer orelse return;
    const pipeline = app.pipeline orelse return;

    var frame = (try renderer.beginFrame(window)) orelse return;

    const t: f32 = @floatFromInt(app.frame);
    const pulse = 0.5 + 0.5 * @sin(t * 0.00015);

    frame.beginRendering(.{ 0.04, 0.06 + 0.06 * pulse, 0.12 + 0.10 * pulse, 1.0 });
    frame.bindPipeline(pipeline);
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

    while (!window.shouldClose()) {
        window.pollEvents();
        redraw(&window);
    }
}
