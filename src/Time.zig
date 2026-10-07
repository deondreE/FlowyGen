const Time = @This();

extern fn glfwGetTime() callconv(.c) f64;

pub const max_delta: f64 = 0.25;
last: f64,
/// Seconds since the previous tick, clamped to max_delta. Use this for simulation.
delta: f32 = 0,
/// Seconds since the previous tick, unclamped. Use this for profiling / FPS display.
raw_delta: f64 = 0,
/// Sum of all delta times since the start. Useful for tracking total elapsed simulation time.
elapsed: f64 = 0,
ticks: u64 = 0,
fps_avg: f64 = 0,

pub fn init() Time {
    return .{ .last = glfwGetTime() };
}

pub fn tick(self: *Time) void {
    const now = glfwGetTime();
    const raw = now - self.last;
    self.last = now;

    self.raw_delta = raw;
    const clamped = @min(@max(raw, 0.0), max_delta);
    self.delta = @floatCast(clamped);
    self.elapsed += clamped;
    self.ticks += 1;

    const inst = if (raw > 0) 1.0 / raw else 0;
    self.fps_avg = if (self.fps_avg == 0) inst else self.fps_avg * 0.95 + inst * 0.05;
}

pub fn fps(self: *const Time) f64 {
    return if (self.raw_delta > 0) 1.0 / self.raw_delta else 0;
}
