const vk = @import("vulkan");
const std = @import("std");
const Allocator = std.mem.Allocator;

const VkContext = struct {
    instance: vk.Instance,
    pdev: vk.PhysicalDevice,
    device: vk.Device,

    pub fn init(allocator: Allocator, app_name: [*:0]const u8) !VkContext {
        _ = allocator;
        _ = app_name;
    }

    pub fn deinit(self: *VkContext) void {
        _ = self;
    }
};
