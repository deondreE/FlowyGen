const std = @import("std");
const vk = @import("vulkan");
const Context = @import("Context.zig");
const Window = @import("window.zig");
const Allocator = std.mem.Allocator;

const Swapchain = @This();

ctx: *const Context,
