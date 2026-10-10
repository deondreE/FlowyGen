const std = @import("std");

const Math = @This();

fn convert(comptime Dst: type, v: anytype) Dst {
    const Src = @TypeOf(v);
    return switch (@typeInfo(Dst)) {
        .float => switch (@typeInfo(Src)) {
            .float => @floatCast(v),
            .int => @floatCast(v),
            else => @compileError("unsupported vector cast"),
        },
        .int => switch (@typeInfo(Src)) {
            .float => @intFromFloat(v),
            .int => @intCast(v),
            else => @compileError("unsupported vector cast"),
        },
        else => @compileError("unsupported vector cast."),
    };
}

pub fn Vec(comptime N: usize, comptime T: type) type {
    return struct {
        data: @Vector(N, T),

        const Self = @This();

        pub const zero: Self = .{ .data = @splat(0) };
        pub const one: Self = .{ .data = @splat(1) };

        pub fn init(vals: [N]T) Self {
            return .{ .data = vals };
        }

        pub fn splat(val: T) Self {
            return .{ .data = @splat(val) };
        }

        pub fn toArray(self: Self) [N]T {
            return self.data;
        }

        pub fn cast(self: Self, comptime NewT: type) Vec(N, NewT) {
            var out: [N]NewT = undefined;
            inline for (0..N) |i| {
                out[i] = convert(NewT, self.data[i]);
            }
            return Vec(N, NewT).init(out);
        }

        pub fn add(self: Self, other: Self) Self {
            return .{ .data = self.data + other.data };
        }

        pub fn mul(self: Self, other: Self) Self {
            return .{ .data = self.data * other.data };
        }

        pub fn div(self: Self, other: Self) Self {
            return .{ .data = self.data / other.data };
        }

        pub fn neg(self: Self) Self {
            return .{ .data = -self.data };
        }

        pub fn scale(self: Self, scalar: T) Self {
            return .{ .data = self.data * @as(@Vector(N, T), @splat(scalar)) };
        }

        pub fn min(self: Self, other: Self) Self {
            return .{ .data = @min(self.data, other.data) };
        }

        pub fn max(self: Self, other: Self) Self {
            return .{ .data = @max(self.data, other.data) };
        }

        pub fn clamp(self: Self, lo: Self, hi: Self) Self {
            return self.max(lo).min(hi);
        }

        pub fn abs(self: Self) Self {
            return .{ .data = @abs(self.data) };
        }

        pub fn floor(self: Self) Self {
            comptime requireFloat();
            return .{ .data = @floor(self.data) };
        }

        pub fn ceil(self: Self) Self {
            comptime requireFloat();
            return .{ .data = @ceil(self.data) };
        }

        // x - floor(x), the fractional part in [0, 1)
        pub fn fract(self: Self) Self {
            return self.sub(self.floor());
        }

        pub fn dot(self: Self, other: Self) T {
            return @reduce(.Add, self.data * other.data);
        }

        pub fn lerp(self: Self, target: Self, t: T) Self {
            const vt: @Vector(N, T) = @splat(t);
            const one_minus_t: @Vector(N, T) = @splat(@as(T, 1.0) - t);
            return .{ .data = self.data * one_minus_t + target.data * vt };
        }

        pub fn lengthSq(self: Self) T {
            return self.dot(self);
        }

        pub fn length(self: Self) T {
            return @sqrt(self.lengthSq());
        }

        pub fn distance(self: Self, other: Self) T {
            return self.sub(other).length();
        }

        pub fn normalize(self: Self) Self {
            const len = self.length();
            if (len == 0) return self;
            return self.scale(1.0 / len);
        }

        pub fn cross(self: Self, other: Self) Self {
            if (N != 3) @compileError("cross is only defined for 3D vectors");
            const a = self.data;
            const b = other.data;
            return init(.{
                a[1] * b[2] - a[2] * b[1],
                a[2] * b[0] - a[0] * b[2],
                a[0] * b[1] - a[1] * b[0],
            });
        }
        pub fn x(self: Self) T {
            return self.data[0];
        }

        pub fn y(self: Self) T {
            comptime if (N < 2) @compileError("Vector too small for .y()");
            return self.data[1];
        }
        pub fn z(self: Self) T {
            comptime if (N < 3) @compileError("Vector too small for .z()");
            return self.data[2];
        }
        pub fn w(self: Self) T {
            comptime if (N < 4) @compileError("Vector too small for .w()");
            return self.data[3];
        }

        fn requireFloat() void {
            if (@typeInfo(T) != .float) @compileError("this operation needs a float vector");
        }
    };
}

pub fn Mat(comptime Cols: usize, comptime Rows: usize, comptime T: type) type {
    const ColumnType = Vec(Rows, T);
    const RowType = Vec(Cols, T);

    return struct {
        cols: [Cols]ColumnType,
        const Self = @This();

        pub fn indentity() Self {
            var res: Self = undefined;
            inline for (0..Cols) |i| {
                var col_data: [Rows]T = @splat(@as(T, 0));
                if (i < Rows) col_data[i] = 1;
                res.cols[i] = ColumnType.init(col_data);
            }
            return res;
        }

        pub fn mulVec(self: Self, v: RowType) ColumnType {
            var r = ColumnType.zero;
            inline for (0..Cols) |i| r = r.add(self.cols[i].scale(v.data[i]));
            return r;
        }
    };
}

// all vectors are f32 by default
pub const Vec2 = Vec(2, f32);
pub const Vec3 = Vec(3, f32);
pub const Vec4 = Vec(4, f32);

pub const Vec2f64 = Vec(2, f64);
pub const Vec3f64 = Vec(3, f64);
pub const Vec4f64 = Vec(4, f64);

pub const Mat2 = Mat(2, 2, f32);
pub const Mat3 = Mat(3, 3, f32);
pub const Mat4 = Mat(4, 4, f32);

pub const Letterbox = struct {
    /// Clip-space scale (<= 1 on each axis) that fits the content inside the
    /// view while keeping its aspect ratio. Multiply NDC positions by this.
    fit: Vec2,
    /// Pixels per content unit after fitting.
    scale: f32,
};

/// fit `content` (any units, e.g. grid cells) inside `view` (pixels), centred;
pub fn letterbox(content: Vec2, view: Vec2) Letterbox {
    const s = @min(view.x() / content.x(), view.y() / content.y());
    return .{ .fit = content.scale(s).div(view), .scale = s };
}

test "vec basics" {
    const a = Vec2.init(.{ 3, 4 });
    try std.testing.expectApproxEqAbs(@as(f32, 5), a.length(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), a.normalize().length(), 1e-6);
    try std.testing.expectEqual(@as(f32, 0), Vec2.zero.normalize().length());

    const l = Vec2.zero.lerp(a, 0.5);
    try std.testing.expectEqual(@as(f32, 1.5), l.x());
    try std.testing.expectEqual(@as(f32, 2), l.y());

    const c = Vec2.init(.{ -1.5, 7 }).clamp(Vec2.zero, Vec2.splat(5));
    try std.testing.expectEqual([2]f32{ 0, 5 }, c.toArray());

    const f = Vec2.init(.{ 2.75, -0.25 }).fract();
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), f.x(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), f.y(), 1e-6);
}

test "cast" {
    const d = Vec2f64.init(.{ 1.5, 2.5 });
    const f = d.cast(f32);
    try std.testing.expectEqual(@as(f32, 2.5), f.y());
    const i = d.cast(i32);
    try std.testing.expectEqual([2]i32{ 1, 2 }, i.toArray());
    const back = Vec(2, u32).init(.{ 256, 128 }).cast(f32);
    try std.testing.expectEqual(@as(f32, 256), back.x());
}

test "cross and mat" {
    const c = Vec3.init(.{ 1, 0, 0 }).cross(Vec3.init(.{ 0, 1, 0 }));
    try std.testing.expectEqual([3]f32{ 0, 0, 1 }, c.toArray());

    const v = Mat4.identity().mulVec(Vec4.init(.{ 1, 2, 3, 4 }));
    try std.testing.expectEqual([4]f32{ 1, 2, 3, 4 }, v.toArray());
}

test "letterbox" {
    // 2:1 domain in a 1000x1000 window: full width, half height.
    const lb = letterbox(Vec2.init(.{ 256, 128 }), Vec2.init(.{ 1000, 1000 }));
    try std.testing.expectApproxEqAbs(@as(f32, 1), lb.fit.x(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), lb.fit.y(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1000.0 / 256.0), lb.scale, 1e-4);
}
