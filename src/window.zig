const std = @import("std");
const glfw = @import("zglfw");
const builtin = @import("builtin");

// @Todo: threadlocal???
const is_linux = builtin.os.tag == .linux;

/// GLFW_FEATURE_UNAVAILABLE. zglfw's `ErrorCode` is a plain c_int, so there is no enum member for it.
const glfw_feature_unavailable: glfw.ErrorCode = 0x0001000C;

const Window = @This();

pub const Size = struct { width: u32, height: u32 };

pub const Platform = enum {
    auto,
    wayland,
    x11,
};

pub const Options = struct {
    title: [:0]const u8 = "Window",
    width: c_int = 1280,
    height: c_int = 720,
    min_width: c_int = 320,
    min_height: c_int = 240,
    resizable: bool = true,
    /// Center on the primary monitor (no-op on Wayland, which controls placement).
    center: bool = true,
    close_on_escape: bool = true,
    /// F11 toggles borderless-style fullscreen on the primary monitor.
    fullscreen_hotkey: bool = true,
    /// Linux only: force a backend. `.auto` lets GLFW pick Wayland or X11 automatically.
    platform: Platform = .auto,
    /// Linux only: Wayland app_id / X11 class. Should match your .desktop file name
    /// so compositors can pick the right icon and group windows.
    app_id: [:0]const u8 = "flowygen",
    on_redraw: ?*const fn (*Window) void = null,
    /// Anything you want to reach from callbacks; read it back with `userData`.
    user_data: ?*anyopaque = null,
};

const Rect = struct { x: c_int, y: c_int, w: c_int, h: c_int };

handle: *glfw.Window,
resized: bool = false,
/// Wayland forbids clients from reading or setting window position.
is_wayland: bool = false,
on_redraw: ?*const fn (*Window) void,
user_data: ?*anyopaque,
close_on_escape: bool,
fullscreen_hotkey: bool,
/// Set while fullscreen; remembers where to go back to.
windowed_rect: ?Rect = null,

pub fn init(self: *Window, options: Options) !void {
    _ = glfw.setErrorCallback(errorCallback);

    // Init hints must be set before glfw.init(). The value has to be a typed enum:
    // zglfw's cIntCast can't convert a bare `.wayland` literal.
    if (is_linux) {
        switch (options.platform) {
            .auto => {},
            .wayland => try glfw.initHint(.platform, glfw.Platform.wayland),
            .x11 => try glfw.initHint(.platform, glfw.Platform.x11),
        }
    }

    try glfw.init();
    errdefer glfw.terminate();

    // Ask GLFW what it actually picked; `.auto` can resolve to either backend.
    const wayland = is_linux and glfw.getPlatform() == glfw.Platform.wayland;
    if (is_linux) {
        std.log.info("Running on Linux with platform: {s}", .{if (wayland) "wayland" else "x11"});
    }

    if (!glfw.isVulkanSupported()) {
        std.log.warn("GLFW can't find a Vulkan loader. On macOS install the Vulkan SDK (MoltenVK).", .{});
    }

    // Vulkan draws to the window itself, so GLFW must not create an OpenGL context.
    glfw.windowHint(.client_api, .no_api);
    glfw.windowHint(.resizable, options.resizable);
    // Create hidden, position, then show: avoids a flash at a default position.
    glfw.windowHint(.visible, false);

    if (is_linux) {
        glfw.windowHintString(.wayland_app_id, options.app_id);
        glfw.windowHintString(.x11_class_name, options.app_id);
        glfw.windowHintString(.x11_instance_name, options.app_id);
    }

    const handle = try glfw.createWindow(options.width, options.height, options.title, null, null);
    errdefer handle.destroy();

    self.* = .{
        .handle = handle,
        .is_wayland = wayland,
        .on_redraw = options.on_redraw,
        .user_data = options.user_data,
        .close_on_escape = options.close_on_escape,
        .fullscreen_hotkey = options.fullscreen_hotkey,
    };

    handle.setUserPointer(self);
    _ = handle.setKeyCallback(keyCallback);
    _ = handle.setFramebufferSizeCallback(framebufferSizeCallback);
    // Moving between a Retina and a non-Retina display changes scale without changing size.
    _ = handle.setContentScaleCallback(contentScaleCallback);
    handle.setSizeLimits(options.min_width, options.min_height, -1, -1); // -1 == GLFW_DONT_CARE

    // Wayland: the compositor owns placement; setPos would raise FEATURE_UNAVAILABLE.
    if (options.center and !self.is_wayland) self.centerOnPrimaryMonitor();
    handle.show();
}

pub fn deinit(self: *Window) void {
    self.handle.destroy();
    glfw.terminate();
}

pub fn shouldClose(self: *const Window) bool {
    return self.handle.shouldClose();
}

pub fn close(self: *Window) void {
    self.handle.setShouldClose(true);
}

/// Process pending events without blocking. While the window is minimized this
/// sleeps instead of spinning, so a minimized app costs ~0% CPU.
pub fn pollEvents(self: *Window) void {
    glfw.pollEvents();
    while (self.isMinimized() and !self.shouldClose()) glfw.waitEvents();
}

/// Block until at least one event arrives. Use while you have nothing to animate.
pub fn waitEvents(self: *Window) void {
    _ = self;
    glfw.waitEvents();
}

/// Size in pixels (what the swapchain should match), not in screen points.
pub fn framebufferSize(self: *const Window) Size {
    const fb = self.handle.getFramebufferSize();
    return .{ .width = @intCast(fb[0]), .height = @intCast(fb[1]) };
}

/// True when there is nothing to draw to (iconified, or a zero-sized framebuffer).
pub fn isMinimized(self: *const Window) bool {
    const fb = self.framebufferSize();
    return fb.width == 0 or fb.height == 0 or self.handle.getAttribute(.iconified);
}

/// Returns true once per resize/scale change. Use it to decide when to rebuild the swapchain.
pub fn takeResized(self: *Window) bool {
    const was = self.resized;
    self.resized = false;
    return was;
}

pub fn keyDown(self: *const Window, key: glfw.Key) bool {
    return self.handle.getKey(key) == .press;
}

pub fn userData(self: *const Window, comptime T: type) ?*T {
    const ptr = self.user_data orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn setTitle(self: *Window, title: [:0]const u8) void {
    self.handle.setTitle(title);
}

pub fn toggleFullscreen(self: *Window) void {
    if (self.windowed_rect) |r| {
        // On Wayland x/y are ignored; the compositor restores the previous placement.
        self.handle.setMonitor(null, r.x, r.y, r.w, r.h, -1);
        self.windowed_rect = null;
        return;
    }
    const monitor = glfw.getPrimaryMonitor() orelse return;
    const mode = monitor.getVideoMode() catch return;
    // Wayland: getPos raises FEATURE_UNAVAILABLE, so don't ask.
    const pos: [2]c_int = if (self.is_wayland) .{ 0, 0 } else self.handle.getPos();
    const size = self.handle.getSize();
    self.windowed_rect = .{ .x = pos[0], .y = pos[1], .w = size[0], .h = size[1] };
    self.handle.setMonitor(monitor, 0, 0, mode.width, mode.height, mode.refresh_rate);
}

fn centerOnPrimaryMonitor(self: *Window) void {
    const monitor = glfw.getPrimaryMonitor() orelse return;
    const mode = monitor.getVideoMode() catch return;
    const origin = monitor.getPos();
    const size = self.handle.getSize();
    self.handle.setPos(
        origin[0] + @divTrunc(mode.width - size[0], 2),
        origin[1] + @divTrunc(mode.height - size[1], 2),
    );
}

fn notifyResized(self: *Window) void {
    self.resized = true;
    if (self.on_redraw) |redraw| redraw(self);
}

fn errorCallback(code: glfw.ErrorCode, desc: ?[*:0]const u8) callconv(.c) void {
    // Wayland deliberately lacks some features (window position, focus stealing, ...).
    // That's expected, not a failure.
    if (code == glfw_feature_unavailable) {
        std.log.warn("GLFW feature unavailable: {s}", .{desc orelse "unknown"});
        return;
    }
    std.log.err("GLFW error {d}: {s}", .{ code, desc orelse "unknown" });
}

fn keyCallback(
    handle: *glfw.Window,
    key: glfw.Key,
    scancode: c_int,
    action: glfw.Action,
    mods: glfw.Mods,
) callconv(.c) void {
    _ = scancode;
    _ = mods;
    const self = handle.getUserPointer(Window) orelse return;
    if (action != .press) return;
    switch (key) {
        .escape => if (self.close_on_escape) self.close(),
        .F11 => if (self.fullscreen_hotkey) self.toggleFullscreen(),
        else => {},
    }
}

fn framebufferSizeCallback(handle: *glfw.Window, width: c_int, height: c_int) callconv(.c) void {
    _ = width;
    _ = height;
    if (handle.getUserPointer(Window)) |self| self.notifyResized();
}

fn contentScaleCallback(handle: *glfw.Window, xscale: f32, yscale: f32) callconv(.c) void {
    _ = xscale;
    _ = yscale;
    if (handle.getUserPointer(Window)) |self| self.notifyResized();
}
