const vk = @import("vulkan");
const std = @import("std");
const Allocator = std.mem.Allocator;

/// VkContext represents the Vulkan context, including the instance, physical device, and logical device.
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

/// VkBuffer represents a Vulkan buffer along with its associated memory and usage flags.
const VkBuffer = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,

    pub fn init(allocator: Allocator, size: vk.DeviceSize, usage: vk.BufferUsageFlags) !VkBuffer {
        _ = allocator;
        _ = size;
        _ = usage;
    }

    pub fn deinit(self: *VkBuffer) void {
        _ = self;
    }
};

/// VkImage represents a Vulkan image along with its associated memory and usage flags.
const VkImage = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    size: vk.DeviceSize,
    usage: vk.ImageUsageFlags,

    pub fn init(allocator: Allocator, size: vk.DeviceSize, usage: vk.ImageUsageFlags) !VkImage {
        _ = allocator;
        _ = size;
        _ = usage;
    }

    pub fn deinit(self: *VkImage) void {
        _ = self;
    }
};

/// VkShaderObject represents a Vulkan shader module.
const VkShaderObject = struct {
    shader: vk.ShaderModule,

    pub fn init(allocator: Allocator, shader: vk.ShaderModule) !VkShaderObject {
        _ = allocator;
        _ = shader;
    }

    pub fn deinit(self: *VkShaderObject) void {
        _ = self;
    }
};

/// VkPipeline represents a Vulkan graphics or compute pipeline.
const VkPipeline = struct {
    pipeline: vk.Pipeline,

    pub fn init(allocator: Allocator, pipeline: vk.Pipeline) !VkPipeline {
        _ = allocator;
        _ = pipeline;
    }

    pub fn deinit(self: *VkPipeline) void {
        _ = self;
    }
};

/// VkDescriptorSetLayout represents a Vulkan descriptor set layout.
const VkDescriptorSetLayout = struct {
    layout: vk.DescriptorSetLayout,

    pub fn init(allocator: Allocator, layout: vk.DescriptorSetLayout) !VkDescriptorSetLayout {
        _ = allocator;
        _ = layout;
    }

    pub fn deinit(self: *VkDescriptorSetLayout) void {
        _ = self;
    }
};

/// VkDescriptorSet represents a Vulkan descriptor set.
const VkDescriptorSet = struct {
    set: vk.DescriptorSet,

    pub fn init(allocator: Allocator, set: vk.DescriptorSet) !VkDescriptorSet {
        _ = allocator;
        _ = set;
    }

    pub fn deinit(self: *VkDescriptorSet) void {
        _ = self;
    }
};

/// VkDescriptorPool represents a Vulkan descriptor pool.
const VkDescriptorPool = struct {
    pool: vk.DescriptorPool,

    pub fn init(allocator: Allocator, pool: vk.DescriptorPool) !VkDescriptorPool {
        _ = allocator;
        _ = pool;
    }

    pub fn deinit(self: *VkDescriptorPool) void {
        _ = self;
    }
};

/// VkCommandBuffer represents a Vulkan command buffer.
const VkCommandBuffer = struct {
    commandBuffer: vk.CommandBuffer,

    pub fn init(allocator: Allocator, commandBuffer: vk.CommandBuffer) !VkCommandBuffer {
        _ = allocator;
        _ = commandBuffer;
    }

    pub fn deinit(self: *VkCommandBuffer) void {
        _ = self;
    }
};

/// VkCommandPool represents a Vulkan command pool.
const VkCommandPool = struct {
    commandPool: vk.CommandPool,

    pub fn init(allocator: Allocator, commandPool: vk.CommandPool) !VkCommandPool {
        _ = allocator;
        _ = commandPool;
    }

    pub fn deinit(self: *VkCommandPool) void {
        _ = self;
    }
};

/// VkQueue represents a Vulkan queue.
const VkQueue = struct {
    queue: vk.Queue,

    pub fn init(allocator: Allocator, queue: vk.Queue) !VkQueue {
        _ = allocator;
        _ = queue;
    }

    pub fn deinit(self: *VkQueue) void {
        _ = self;
    }
};
