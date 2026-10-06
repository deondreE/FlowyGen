const std = @import("std");

const Math = @This();

pub fn Vec(comptime N: usize, comptime T: type) type {
    return struct {
        data: @Vector(N, T),

        const Self = @This();

        pub fn init(vals: [N]T) Self {
            return .{ .data = vals };
        }

        /// Handle possible mixed precision scenarios
        pub fn cast(self: Self, comptime NewT: type) Vec(N, NewT) {
            return .{ .data = @as(NewT, self.data) };
        }

        pub fn splat(val: T) Self {
            return .{ .data = @splat(val) };
        }

        pub fn add(self: Self, other: Self) Self {
            return .{ .data = self.data + other.data };
        }

        pub fn mul(self: Self, other: Self) Self {
            return .{ .data = self.data * other.data };
        }

        pub fn scale(self: Self, scalar: T) Self {
            return .{ .data = self.data * @as(@Vector(N, T), @splat(scalar)) };
        }

        /// dot product of two vectors
        ///
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

        pub fn normalize(self: Self) Self {
            return self.scale(1.0 / self.length());
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
    };
}

pub fn Mat(comptime Cols: usize, comptime Rows: usize, comptime T: type) type {
    const ColumnType = Vec(Rows, T);

    return extern struct {
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
    };
}

// all vectors are f32 by default
pub const Vec2 = Vec(2, f32);
pub const Vec3 = Vec(3, f32);
pub const Vec4 = Vec(4, f32);

pub const Vec2f64 = Vec(2, f64);
pub const Vec3f64 = Vec(3, f64);
pub const Vec4f64 = Vec(4, f64);
