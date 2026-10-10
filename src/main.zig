const std = @import("std");

const Window = @import("window.zig");
const Context = @import("Context.zig");
const Swapchain = @import("Swapchain.zig");
const Renderer = @import("Renderer.zig");
const Pipeline = @import("Pipeline.zig");
const Buffer = @import("Buffer.zig");
const Time = @import("Time.zig");
const TextRenderer = @import("TextRenderer.zig");
const Font = @import("stb_zig.zig").Font;
const Fluid = @import("Fluid.zig");

const font_data = @embedFile("fonts/Roboto.ttf");

const UIVertex = extern struct {
    pos: [2]f32,
    color: [4]u8,
};

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
    ui_pipeline: ?*Pipeline = null,
    ui_buffer: ?*Buffer = null,
    text: ?*TextRenderer = null,
    fluid: ?*Fluid = null,
    fps_log_timer: f64 = 0,
};

fn drawFrame(window: *Window, app: *App) !void {
    const renderer = app.renderer orelse return;
    const ui_pipeline = app.ui_pipeline orelse return;
    const ui_buffer = app.ui_buffer orelse return;
    const text = app.text orelse return;
    const fluid = app.fluid orelse return;

    app.time.tick();
    const dt: f32 = @floatCast(app.time.delta);

    app.fps_log_timer += app.time.raw_delta;
    if (app.fps_log_timer >= 1.0) {
        app.fps_log_timer = 0;
        std.log.info("FPS: {d:.1}", .{app.time.fps()});
    }

    var frame = (try renderer.beginFrame(window)) orelse return;

    fluid.update(&frame, dt);

    const pulse = 0.5 + 0.5 * @as(f32, @floatCast(@sin(app.time.elapsed * 2.0)));

    frame.beginRendering(.{ 0.04, 0.06 + 0.06 * pulse, 0.12 + 0.10 * pulse, 1.0 });

    // Render fluid simulation
    fluid.draw(&frame);

    // Render UI
    frame.bindPipeline(ui_pipeline);
    frame.bindVertexBuffer(ui_buffer);
    frame.draw(ui_vertices.len);

    // Render text
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
        .title = "FlowyGen - 3D Sphere Renderer",
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

    var ui_buffer = try Buffer.fromSlice(&context, UIVertex, &ui_vertices, .{ .vertex_buffer = true });
    defer ui_buffer.deinit();

    // Create UI pipeline with alpha blending
    var ui_pipeline = try Pipeline.init(
        &context,
        Pipeline.Desc.ui(
            Pipeline.embedSpirv("shaders/ui.vert.spv"),
            Pipeline.embedSpirv("shaders/ui.frag.spv"),
            swapchain.format,
        ).withVertex(UIVertex, &.{ "pos", "color" }),
    );
    defer ui_pipeline.deinit();

    var font = try Font.init(font_data);
    var text = try TextRenderer.init(&context, gpa, swapchain.format, &font, 24, 4096);
    defer text.deinit();

    var fluid = try Fluid.init(&context, swapchain.format, .{});
    defer fluid.deinit();

    var renderer = try Renderer.init(&context, &swapchain);
    defer renderer.deinit();

    // Set up app state
    app.renderer = &renderer;
    app.ui_pipeline = &ui_pipeline;
    app.ui_buffer = &ui_buffer;
    app.text = &text;
    app.fluid = &fluid;

    // Main loop
    while (!window.shouldClose()) {
        if (window.isMinimized()) {
            window.waitEvents();
            continue;
        }

        window.pollEvents();
        redraw(&window);
    }
}
