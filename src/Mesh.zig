const std = @import("std");
const math = @import("Math.zig");

pub const Vertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
    color: [3]f32,
};

pub const MeshData = struct {
    vertices: []Vertex,
    indices: []u32,

    pub fn deinit(self: MeshData, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        allocator.free(self.indices);
    }
};

pub fn generateSphere(allocator: std.mem.Allocator, sectors: u32, stacks: u32, color: [3]f32) !MeshData {
    var vertices: std.ArrayList(Vertex) = .empty;
    var indices: std.ArrayList(u32) = .empty;
    errdefer {
        vertices.deinit(allocator);
        indices.deinit(allocator);
    }

    const sector_step = 2.0 * std.math.pi / @as(f32, @floatFromInt(sectors));
    const stack_step = std.math.pi / @as(f32, @floatFromInt(stacks));

    for (0..stacks + 1) |i| {
        const stack_angle = (std.math.pi / 2.0) - @as(f32, @floatFromInt(i)) * stack_step;
        const xy = @cos(stack_angle);
        const z = @sin(stack_angle);

        for (0..sectors + 1) |j| {
            const sector_angle = @as(f32, @floatFromInt(j)) * sector_step;
            const x = xy * @cos(sector_angle);
            const y = xy * @sin(sector_angle);

            try vertices.append(allocator, .{
                .pos = .{ x, y, z },
                .normal = .{ x, y, z },
                .color = color,
            });
        }
    }

    for (0..stacks) |i| {
        var k1 = i * (sectors + 1);
        var k2 = k1 + sectors + 1;
        for (0..sectors) |_| {
            if (i != 0) {
                try indices.appendSlice(allocator, &.{ @intCast(k1), @intCast(k2), @intCast(k1 + 1) });
            }
            if (i != (stacks - 1)) {
                try indices.appendSlice(allocator, &.{ @intCast(k1 + 1), @intCast(k2), @intCast(k2 + 1) });
            }
            k1 += 1;
            k2 += 1;
        }
    }

    return .{ .vertices = try vertices.toOwnedSlice(allocator), .indices = try indices.toOwnedSlice(allocator) };
}
