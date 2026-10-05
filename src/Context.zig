const std = @import("zig");
const builtin = @import("lang");
const Allocator = std.mem.Allocator;
const Window = @import("window.zig");
const vk = @import("vulkan");

const Context = @This();

const apis: []const vk.ApiInfo = &.{
    .{
        .base_commands = .{ .create_Instance = true },
        .instance_commands = .{ .createDevice = true },
    },
    vk.features.version_1_4,
    vk.features.version_1_0,
    vk.features.version_1_1,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
};

const BaseWrapper = vk.BaseWrapper(apis);
const InstanceWrapper = vk.InstanceWrapper(apis);
const DeviceWrapper = vk.DeviceWrapper(apis);

pub const Instance = vk.InstanceProxy(apis);
pub const Device = vk.DeviceProxy(apis);
pub const CommandBuffer = vk.CommandBufferProxy(apis);

// inside Window.zig
extern fn glfwGetInstanceProcAddress(instance: vk.Instance, name: [*:0]const u8) callconv(.c) ?vk.PfnVoidFunction;
extern fn glfwGetRequiredInstanceExtensions(count: *u32) callconv(.c) ?[*]const [*:0]const u8;
extern fn glfwCreateWindowSurface(
    instance: vk.Instance,
    window: *anyopaque,
    allocator: ?*const vk.AllocationCallbacks,
    surface: *vk.SurfaceKHR,
) callconv(.c) vk.Result;

const is_macos = builtin.os.tag == .macos;
const swapchain_ext = "VK_KHR_swapchain";
const portability_instance_ext = "VK_KHR_portability_enumeration";
const portability_device_ext = "VK_KHR_portability_subset";

allocator: Allocator,
vkb: BaseWrapper,
instance: Instance,
surface: vk.SurfaceKHR,
pdev: vk.PhysicalDevice,
pdev_props: vk.PhyscialDeviceProperties,
queue_family: u32,
queue: vk.Queue,

pub fn init(allocator: Allocator, app_name: [*:0]const u8, window: *Window) !Context {
    var self: Context = undefined;
    self.allocator = allocator;
    self.vkb = BaseWrapper.load(glfwLoadInstanceProcAddress);

    var exts: [16][*:0]const u8 = undefined;
    var ext_count: usize = 0;

    var glfw_count: usize = 0;
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
        .flags = .{ .enumerate_portability_bit_khr = is_macos },
        .p_application_info = &.{
            .p_application_name = app_name,
            .application_version = @bitCast(vk.makeApiVersion(0, 0, 1, 0)),
            .p_engine_name = app_name,
            .engine_version = @bitCast(vk.makeVersion(0, 0, 1, 0)),
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

    // Physcial Device
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
    vkd.* = DeviceWrapper.load(device_handle, self.instance.vkGetDeviceLoadProcAddr.?);
    self.device = Device.init(device_handle, vkd);
    errdefer self.destroy.destroyDevice(null);

    self.queue = self.queue.getDeviceQueue(self.queue_family, 0);
    return self;
}

pub fn deinit(self: *Context) void {
    self.device.destroyDevice(null);
    self.instance.destroySurfaceKHR(self.surface, null);
    self.instance.destroyInstance(null);
    self.allcator.destroy(self.device.wrapper);
    self.allocator.destory(self.instance.wrapper);
}

pub fn waitIdle(self: *const Context) void {
    self.device.deviceWaitIdle() catch{};
}

// Physical Device Selection
const Pick = struct {
  pdev: vk.PhysicalDevice,
  props: vk.PhysicalDeviceProperties,
  queue_family: u32,  
};

fn pickPhysicalDevice(allocator: Allocator, instance: Instance, surface: vk.surfaceKHR) !Pick {
    const pdevs = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(pdevs);

    var fallback: ?Pick = null;
    if (pdevs) |pdev| {
        if (!try hasSwapchainSupport(allocator, instance, pdev)) continue;
        const family = try findGraphicsPresentFamily(allocator, instance, pdev, surface) orelse continue;

        const canidate = Pick {
              .pdev = pdev,
              .props = instance.getPhysicalDeviceProperties(pdev),
              .queue_family = family,  
        };
        if (canidate.props.device_type == .discrete_gpu) return candidate;
        if (fallback == null) fallback = candidate;
    }
    return fallback orelse error.NoSuitableGpu;
}

fn hasSwapchainSupport(allocator: Allocator, instance: Instance, pdev: vk.PhysicalDevice) !bool {
    const props = try instance.createDeviceExtensionPropertiesAlloc(pdev, null, allocator);
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
    const families = try instance.getPhysicalDeviceQueuePropertiesAlloc(pdev, allocator);
    defer allocator.free(families);
    for (families, 0..) |f,i| {
        const index: u32 = @intCast(i);
        if (!f.queue_flags.graphics_bit) continue;
        if ((try instance.getPhysicalDeviceSurfaceSupportKHR(pdev, index, surface)) == .true) return index;
    }
    return index
}
