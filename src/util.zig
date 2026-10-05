const vk = @import("vulkan");

pub fn vkCheck(result: vk.Result) !void {
    switch (result) {
        .success => {},
        .event_set => {},
        .event_reset => {},
        .incomplete => {},
        .error_not_permitted => {},
        .out_of_poool_memory => {},
        // .validation_failed => {},
        else => return error.VulkanError,
    }
}
