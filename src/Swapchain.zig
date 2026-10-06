const std = @import("std");
const vk = @import("vulkan");
const Context = @import("Context.zig");
const Window = @import("window.zig");
const Allocator = std.mem.Allocator;

const Swapchain = @This();

ctx: *const Context,
allocator: Allocator,
handle: vk.SwapchainKHR,
format: vk.Format,
extent: vk.Extent2D,
images: []vk.Image,
views: []vk.ImageView,

pub fn init(ctx: *const Context, allocator: *const Allocator, window: *const Window) !Swapchain {
    return build(ctx, allocator, window, .null_handle);
}

pub fn deinit(self: *Swapchain) void {
    for (self.views) |v| {
        self.ctx.device.destroyImageView(v, null);
    }
    self.allocator.free(self.images);
    self.allocator.free(self.views);
    self.ctx.device.destroySwapchainKHR(self.handle, null);
}

pub fn rebuild(self: *Swapchain, window: *const Window) !Swapchain {
    self.ctx.waitIdle();

    const fresh = try build(self.ctx, self.allocator, window, self.handle);
    var old = self.*;
    self.* = fresh;
    old.deinit();
}

pub fn imageCount(self: *const Swapchain) u32 {
    return @intCast(self.images.len);
}

fn build(ctx: *const Context, allocator: Allocator, window: *const Window, old_handle: vk.SwapchainKHR) !Swapchain {
    const caps = try ctx.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical_device, ctx.surface);

    const extent = chooseExtent(caps, window.framebufferSize());
    if (extent.width == 0 or extent.height == 0) return error.ZeroSizedSwapchain;

    const surface_format = try chooseSurfaceFormat(ctx, ctx.surface);
    const present_mode = try choosePresentMode(allocator, ctx);

    var min_images = caps.min_image_count + 1;
    if (caps.max_image_count > 0) {
        min_images = @min(min_images, caps.max_image_count);
    }

    const handle = try ctx.device.createSwapchainKHR(&.{
        .surface = ctx.surface,
        .min_image_count = min_images,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true },
        .image_sharing_mode = .exclusive,
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = true,
        .old_swapchain = old_handle,
    }, null);
    errdefer ctx.device.destroySwapchainKHR(handle, null);

    const images = try ctx.device.getSwapchainImagesAllocKHR(handle, allocator);
    errdefer allocator.free(images);

    const views = try allocator.alloc(vk.ImageView, images.len);
    errdefer allocator.free(views);

    var made: usize = 0;
    for (images, 0..) |image, i| {
        views[i] = try ctx.device.createImageView(&.{
            .image = image,
            .view_type = "2d",
            .format = surface_format.format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        made += 1;
    }

    return .{
        .ctx = ctx,
        .allocator = allocator,
        .handle = handle,
        .format = surface_format.format,
        .extent = extent,
        .images = images,
        .views = views,
    };
}

/// Chooses the most suitable surface format based on the capabilities of the surface.
fn chooseExtent(caps: vk.SurfaceCapabilitiesKHR, fb: Window.Size) vk.Extent2D {
    if (caps.current_extent.width != std.math.maxInt(u32)) return caps.current_extent;
    return .{
        .width = std.math.clamp(fb.width, caps.min_image_extent.width, caps.max_image_extent.width),
        .height = std.math.clamp(fb.height, caps.min_image_extent.height, caps.max_image_extent.height),
    };
}

fn chooseSurfaceFormat(allocator: Allocator, ctx: *const Context) vk.SurfaceFormatKHR {
    const formats = try ctx.instance.getPhysicalDeviceSurfaceFormatsKHR(ctx.physical_device, ctx.surface, allocator);
    defer allocator.free(formats);
    if (formats.len == 0) return error.NoSurfaceFormats;

    for (formats) |f| {
        if (f.format == .b8g8r8a8_srgb and f.color_space == .srgb_nonlinear_khr) return f;
    }
    return formats[0];
}

/// Mailbox (low-latency, no tearing) if available, otherwise FIFO (always supported, vsync).
fn choosePresentMode(allocator: Allocator, ctx: *const Context) vk.PresentModeKHR {
    const modes = try ctx.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(ctx.pdev, ctx.surface, allocator);
    defer allocator.free(modes);

    for (modes) |m| {
        if (m == .mailbox_khr) return m;
    }
    return .fifo_khr;
}
