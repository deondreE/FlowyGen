const std = @import("std");
const Io = std.Io;

const Window = @import("window.zig");
const flowygen = @import("flowygen");

const App = struct {
    frame: u64 = 0,
};

fn redraw(window: *Window) void {
    if (window.isMinimized()) return;
    const app = window.userData(App) orelse return;

    if (window.takeResized()) {
        const fb = window.framebufferSize();
        std.log.info("Framebuffer resized to {d}x{d}", .{ fb.width, fb.height });
        // @Todo: recreate the swapchain here.
    }

    // @Todo: aquire, record, present
    app.frame += 1;
}

pub fn main(init: std.process.Init) !void {
    _ = init;

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

    while (!window.shouldClose()) {
        window.pollEvents();
        redraw(&window);
    }
}
