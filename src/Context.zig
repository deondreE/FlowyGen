const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Window = @import("window.zig");
const vk = @import("vulkan");

const Context = @This();

const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;

pub const Instance = vk.InstanceProxy;
pub const Device = vk.DeviceProxy;
pub const CommandBuffer = vk.CommandBufferProxy;

// GLFW's Vulkan entry points, declared directly (GLFW is linked via zglfw).
extern fn glfwGetInstanceProcAddress(instance: ?vk.Instance, name: [*:0]const u8) callconv(.c) vk.PfnVoidFunction;
extern fn glfwGetRequiredInstanceExtensions(count: *u32) callconv(.c) ?[*]const [*:0]const u8;
extern fn glfwCreateWindowSurface(
    instance: vk.Instance,
    window: *anyopaque,
    allocator: ?*const vk.AllocationCallbacks,
    surface: *vk.SurfaceKHR,
) callconv(.c) vk.Result;

const is_macos = builtin.os.tag == .macos;
const instance_flags: vk.InstanceCreateFlags = if (is_macos) @bitCast(@as(u32, 0x1)) else .{};
const swapchain_ext = "VK_KHR_swapchain";
const portability_instance_ext = "VK_KHR_portability_enumeration";
const portability_device_ext = "VK_KHR_portability_subset";

allocator: Allocator,
vkb: BaseWrapper,
instance: Instance,
surface: vk.SurfaceKHR,
device: Device, // the proxy, not the raw vk.Device handle
pdev: vk.PhysicalDevice,
pdev_props: vk.PhysicalDeviceProperties,
queue_family: u32,
queue: vk.Queue,

pub fn init(allocator: Allocator, app_name: [*:0]const u8, window: *Window) !Context {
    var self: Context = undefined;
    self.allocator = allocator;
    self.vkb = BaseWrapper.load(glfwGetInstanceProcAddress);

    var exts: [16][*:0]const u8 = undefined;
    var ext_count: usize = 0;

    var glfw_count: u32 = 0;
    const glfw_exts = glfwGetRequiredInstanceExtensions(&glfw_count) orelse return error.VulkanUnavailable;
    for (glfw_exts[0..glfw_count]) |e| {
        exts[ext_count] = e;
        ext_count += 1;
    }

    if (is_macos) {
        exts[ext_count] = portability_instance_ext;
        ext_count += 1;
    }

    const instance_handle = try self.vkb.createInstance(&.{
        .flags = instance_flags,
        .p_application_info = &.{
            .p_application_name = app_name,
            .application_version = @bitCast(vk.makeApiVersion(0, 0, 1, 0)),
            .p_engine_name = app_name,
            .engine_version = @bitCast(vk.makeApiVersion(0, 0, 1, 0)),
            .api_version = @bitCast(vk.API_VERSION_1_3),
        },
        .enabled_extension_count = @intCast(ext_count),
        .pp_enabled_extension_names = &exts,
    }, null);

    const vki = try allocator.create(InstanceWrapper);
    errdefer allocator.destroy(vki);
    vki.* = InstanceWrapper.load(instance_handle, self.vkb.dispatch.vkGetInstanceProcAddr.?);
    self.instance = Instance.init(instance_handle, vki);
    errdefer self.instance.destroyInstance(null);

    // Surface
    if (glfwCreateWindowSurface(self.instance.handle, window.handle, null, &self.surface) != .success) {
        return error.SurfaceCreationFailed;
    }
    errdefer self.instance.destroySurfaceKHR(self.surface, null);

    // Physical Device
    const pick = try pickPhysicalDevice(allocator, self.instance, self.surface);
    self.pdev = pick.pdev;
    self.pdev_props = pick.props;
    self.queue_family = pick.queue_family;
    std.log.info("GPU: {s}", .{std.mem.sliceTo(&self.pdev_props.device_name, 0)});

    // Logical Device
    var dev_exts: [2][*:0]const u8 = undefined;
    var dev_ext_count: usize = 0;
    dev_exts[dev_ext_count] = swapchain_ext;
    dev_ext_count += 1;
    if (is_macos) {
        dev_exts[dev_ext_count] = portability_device_ext;
        dev_ext_count += 1;
    }

    const priority = [_]f32{1.0};
    const queue_infos = [_]vk.DeviceQueueCreateInfo{
        .{
            .queue_family_index = self.queue_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };

    const device_handle = try self.instance.createDevice(self.pdev, &.{
        .queue_create_info_count = queue_infos.len,
        .p_queue_create_infos = &queue_infos,
        .enabled_extension_count = @intCast(dev_ext_count),
        .pp_enabled_extension_names = &dev_exts,
    }, null);

    const vkd = try allocator.create(DeviceWrapper);
    errdefer allocator.destroy(vkd);
    vkd.* = DeviceWrapper.load(device_handle, self.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
    self.device = Device.init(device_handle, vkd);
    errdefer self.device.destroyDevice(null);

    self.queue = self.device.getDeviceQueue(self.queue_family, 0);
    return self;
}

pub fn deinit(self: *Context) void {
    self.device.destroyDevice(null);
    self.instance.destroySurfaceKHR(self.surface, null);
    self.instance.destroyInstance(null);
    self.allocator.destroy(self.device.wrapper);
    self.allocator.destroy(self.instance.wrapper);
}

pub fn waitIdle(self: *const Context) void {
    self.device.deviceWaitIdle() catch {};
}

// Physical Device Selection
const Pick = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queue_family: u32,
};

fn pickPhysicalDevice(allocator: Allocator, instance: Instance, surface: vk.SurfaceKHR) !Pick {
    const pdevs = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(pdevs);

    var fallback: ?Pick = null;
    for (pdevs) |pdev| {
        if (try evaluate(allocator, instance, pdev, surface)) |candidate| {
            if (candidate.props.device_type == .discrete_gpu) return candidate;
            if (fallback == null) fallback = candidate;
        }
    }
    return fallback orelse error.NoSuitableGpu;
}

fn evaluate(allocator: Allocator, instance: Instance, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !?Pick {
    if (!try hasSwapchainSupport(allocator, instance, pdev)) return null;
    const family = (try findGraphicsPresentFamily(allocator, instance, pdev, surface)) orelse return null;

    return .{
        .pdev = pdev,
        .props = instance.getPhysicalDeviceProperties(pdev),
        .queue_family = family,
    };
}

fn hasSwapchainSupport(allocator: Allocator, instance: Instance, pdev: vk.PhysicalDevice) !bool {
    const props = try instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, allocator);
    defer allocator.free(props);
    for (props) |p| {
        if (std.mem.eql(u8, std.mem.sliceTo(&p.extension_name, 0), swapchain_ext)) return true;
    }
    return false;
}

fn findGraphicsPresentFamily(
    allocator: Allocator,
    instance: Instance,
    pdev: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) !?u32 {
    const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
    defer allocator.free(families);
    for (families, 0..) |f, i| {
        const index: u32 = @intCast(i);
        if (f.queue_flags.graphics) {
            if ((try instance.getPhysicalDeviceSurfaceSupportKHR(pdev, index, surface)) == .true) return index;
        }
    }
    return null;
}