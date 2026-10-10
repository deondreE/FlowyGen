const std = @import("std");
const vk = @import("vulkan");
const Context = @import("Context.zig");
const Buffer = @import("Buffer.zig");
const Pipeline = @import("Pipeline.zig");
const ComputePipeline = @import("ComputePipeline.zig");
const Frame = @import("Renderer.zig").Frame;
const Math = @import("Math.zig");

/// 2D FLIP/PIC fluid. Particles carry the water, a MAC grid enforces
/// incompressibility. See fluid.comp for the passes.
const Fluid = @This();

pub const Particle = extern struct {
    pos: [2]f32, // grid cells
    vel: [2]f32, // cells / second
};

pub const Config = struct {
    /// Domain size in cells. The outer ring of cells is solid wall.
    width: u32 = 192,
    height: u32 = 128,
    /// Depth of the resting pool along the floor, in cells.
    pool_depth: u32 = 28,
    /// Diameter of the falling drop, in cells.
    drop_diameter: u32 = 26,
    /// Empty cells between the bottom of the drop and the pool surface.
    drop_gap: u32 = 36,
    /// Initial downward speed of the drop, cells / s (gravity does the rest).
    drop_speed: f32 = 20.0,
    /// cells / s^2. Bigger domain => bigger number for the same look.
    gravity: f32 = 100.0,
    /// 0 = PIC (smooth, damped), 1 = FLIP (lively, noisy).
    flip_ratio: f32 = 0.95,
    /// Density correction strength. Raise if the water compresses/shrinks.
    stiffness: f32 = 1.0,
    /// Red-black sweeps per step. More = more incompressible, slower.
    pressure_iters: u32 = 60,
    /// Particle quad radius in grid cells.
    radius_cells: f32 = 0.9,
};

/// Fixed simulation timestep; real frame time is consumed in these chunks.
const sim_dt: f32 = 1.0 / 120.0;
const max_steps_per_frame = 4;
const particles_per_cell = 4; // must match the 2x2 layout in fluid.comp
const local_size = 64;

const Mode = enum(u32) { init, clear, p2g, normalize, solve, g2p };

// Field order must match the Push block in fluid.comp.
const SimPush = extern struct {
    dt: f32,
    gravity: f32,
    flip_ratio: f32,
    stiffness: f32,
    drop_speed: f32,
    w: u32,
    h: u32,
    mode: u32,
    n: u32,
    np: u32,
    arg: u32,
    pool_count: u32,
    drop_d: u32,
    drop_x: u32,
    drop_y: u32,
};

/// Number of cells in the drop's disc. Must use the same integer predicate as
/// dropCell() in fluid.comp: a cell is inside if its centre is within d/2 of
/// the bounding square's centre.
fn dropCellCount(d: u32) u32 {
    const di: i32 = @intCast(d);
    var n: u32 = 0;
    var cy: i32 = 0;
    while (cy < di) : (cy += 1) {
        var cx: i32 = 0;
        while (cx < di) : (cx += 1) {
            const ex = 2 * cx + 1 - di;
            const ey = 2 * cy + 1 - di;
            if (ex * ex + ey * ey <= di * di) n += 1;
        }
    }
    return n;
}

const DrawPush = extern struct {
    grid: [2]f32,
    fit: [2]f32,
    half_size: [2]f32,
};

ctx: *const Context,
cfg: Config,
particle_count: u32,
pool_count: u32,
drop_x: u32,
drop_y: u32,
initialized: bool = false,
accumulator: f32 = 0,

particles: Buffer,
vel: Buffer,
old_vel: Buffer,
acc: Buffer,
sim: ComputePipeline,

draw_set_layout: vk.DescriptorSetLayout,
draw_pool: vk.DescriptorPool,
draw_set: vk.DescriptorSet,
draw_pipeline: Pipeline,

pub fn init(ctx: *const Context, color_format: vk.Format, cfg: Config) !Fluid {
    std.debug.assert(cfg.width >= 8 and cfg.height >= 8);
    std.debug.assert(cfg.pool_depth >= 1 and cfg.drop_diameter >= 2);
    // Drop must fit between the side walls and between the ceiling and pool.
    std.debug.assert(cfg.drop_diameter + 2 <= cfg.width);
    std.debug.assert(cfg.pool_depth + cfg.drop_gap + cfg.drop_diameter + 2 <= cfg.height);

    const w: u64 = cfg.width;
    const h: u64 = cfg.height;
    const nu = (w + 1) * h; // u faces
    const nv = w * (h + 1); // v faces
    const nc = w * h; // cells
    const pool_count: u32 = (cfg.width - 2) * cfg.pool_depth * particles_per_cell;
    const particle_count: u32 = pool_count + dropCellCount(cfg.drop_diameter) * particles_per_cell;
    const drop_x: u32 = (cfg.width - cfg.drop_diameter) / 2;
    const drop_y: u32 = cfg.height - 1 - cfg.pool_depth - cfg.drop_gap - cfg.drop_diameter;

    var particles = try Buffer.init(
        ctx,
        @sizeOf(Particle) * @as(vk.DeviceSize, particle_count),
        .{ .storage_buffer = true },
        .device,
    );
    errdefer particles.deinit();

    var vel = try Buffer.init(ctx, 4 * (nu + nv), .{ .storage_buffer = true }, .device);
    errdefer vel.deinit();

    var old_vel = try Buffer.init(ctx, 4 * (nu + nv), .{ .storage_buffer = true }, .device);
    errdefer old_vel.deinit();

    // 2 ints per face (sum, weight) + 1 int per cell (particle count).
    var acc = try Buffer.init(ctx, 4 * (2 * (nu + nv) + nc), .{ .storage_buffer = true }, .device);
    errdefer acc.deinit();

    var sim = try ComputePipeline.init(ctx, .{
        .comp = Pipeline.embedSpirv("shaders/fluid.comp.spv"),
        .storage_buffer_count = 4,
        .push_constant_size = @sizeOf(SimPush),
    });
    errdefer sim.deinit();
    sim.bindStorageBuffer(0, &particles);
    sim.bindStorageBuffer(1, &vel);
    sim.bindStorageBuffer(2, &old_vel);
    sim.bindStorageBuffer(3, &acc);

    // Draw: the vertex shader reads the particle buffer directly.
    const binding: vk.DescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .vertex = true },
    };
    const set_layout = try ctx.device.createDescriptorSetLayout(&.{
        .binding_count = 1,
        .p_bindings = @ptrCast(&binding),
    }, null);
    errdefer ctx.device.destroyDescriptorSetLayout(set_layout, null);

    const pool_size: vk.DescriptorPoolSize = .{ .type = .storage_buffer, .descriptor_count = 1 };
    const pool = try ctx.device.createDescriptorPool(&.{
        .max_sets = 1,
        .pool_size_count = 1,
        .p_pool_sizes = @ptrCast(&pool_size),
    }, null);
    errdefer ctx.device.destroyDescriptorPool(pool, null);

    var sets: [1]vk.DescriptorSet = undefined;
    try ctx.device.allocateDescriptorSets(&.{
        .descriptor_pool = pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&set_layout),
    }, &sets);

    const info: vk.DescriptorBufferInfo = .{
        .buffer = particles.handle,
        .offset = 0,
        .range = vk.WHOLE_SIZE,
    };
    const write: vk.WriteDescriptorSet = .{
        .dst_set = sets[0],
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .storage_buffer,
        .p_image_info = undefined,
        .p_buffer_info = @ptrCast(&info),
        .p_texel_buffer_view = undefined,
    };
    ctx.device.updateDescriptorSets(&.{write}, &.{});

    const layouts = [_]vk.DescriptorSetLayout{set_layout};
    const ranges = [_]vk.PushConstantRange{.{
        .stage_flags = .{ .vertex = true },
        .offset = 0,
        .size = @sizeOf(DrawPush),
    }};
    var draw_pipeline = try Pipeline.init(
        ctx,
        Pipeline.Desc.fullscreen(
            Pipeline.embedSpirv("shaders/fluid.vert.spv"),
            Pipeline.embedSpirv("shaders/particles.frag.spv"),
            color_format,
        ).withBlend(.additive).withSetLayouts(&layouts).withPushConstants(&ranges),
    );
    errdefer draw_pipeline.deinit();

    return .{
        .ctx = ctx,
        .cfg = cfg,
        .particle_count = particle_count,
        .pool_count = pool_count,
        .drop_x = drop_x,
        .drop_y = drop_y,
        .particles = particles,
        .vel = vel,
        .old_vel = old_vel,
        .acc = acc,
        .sim = sim,
        .draw_set_layout = set_layout,
        .draw_pool = pool,
        .draw_set = sets[0],
        .draw_pipeline = draw_pipeline,
    };
}

pub fn deinit(self: *Fluid) void {
    self.draw_pipeline.deinit();
    self.ctx.device.destroyDescriptorPool(self.draw_pool, null);
    self.ctx.device.destroyDescriptorSetLayout(self.draw_set_layout, null);
    self.sim.deinit();
    self.acc.deinit();
    self.old_vel.deinit();
    self.vel.deinit();
    self.particles.deinit();
}

/// Record the simulation for this frame. Call after beginFrame and BEFORE
/// beginRendering (compute can't run inside a rendering scope).
pub fn update(self: *Fluid, frame: *Frame, dt: f32) void {
    self.accumulator = @min(self.accumulator + dt, sim_dt * max_steps_per_frame);

    var steps: u32 = 0;
    while (self.accumulator >= sim_dt) : (self.accumulator -= sim_dt) steps += 1;
    if (steps == 0 and self.initialized) return;

    const cmd = frame.cmd;

    // Last frame's vertex shader was still reading the particles; wait for it.
    ComputePipeline.memoryBarrier(
        cmd,
        .{ .vertex_shader = true, .compute_shader = true },
        .{ .shader_write = true },
        .{ .compute_shader = true },
        .{ .shader_read = true, .shader_write = true },
    );

    self.sim.bind(cmd);

    if (!self.initialized) {
        self.run(cmd, .init, self.particle_count, self.cfg.pool_depth);
        self.initialized = true;
    }

    const cells = self.cfg.width * self.cfg.height;
    const faces = (self.cfg.width + 1) * self.cfg.height + self.cfg.width * (self.cfg.height + 1);
    const acc_len = 2 * faces + cells;

    var s: u32 = 0;
    while (s < steps) : (s += 1) {
        self.run(cmd, .clear, acc_len, 0);
        self.run(cmd, .p2g, self.particle_count, 0);
        self.run(cmd, .normalize, faces, 0);

        var it: u32 = 0;
        while (it < self.cfg.pressure_iters) : (it += 1) {
            self.run(cmd, .solve, cells, 0); // red
            self.run(cmd, .solve, cells, 1); // black
        }

        self.run(cmd, .g2p, self.particle_count, 0);
    }

    // Particles are final: make them visible to the vertex shader.
    ComputePipeline.memoryBarrier(
        cmd,
        .{ .compute_shader = true },
        .{ .shader_write = true },
        .{ .vertex_shader = true },
        .{ .shader_read = true },
    );
}

/// One dispatch followed by a compute -> compute barrier.
fn run(self: *const Fluid, cmd: Context.CommandBuffer, mode: Mode, n: u32, arg: u32) void {
    const pc: SimPush = .{
        .dt = sim_dt,
        .gravity = self.cfg.gravity,
        .flip_ratio = self.cfg.flip_ratio,
        .stiffness = self.cfg.stiffness,
        .drop_speed = self.cfg.drop_speed,
        .w = self.cfg.width,
        .h = self.cfg.height,
        .mode = @backingInt(mode),
        .n = n,
        .np = self.particle_count,
        .arg = arg,
        .pool_count = self.pool_count,
        .drop_d = self.cfg.drop_diameter,
        .drop_x = self.drop_x,
        .drop_y = self.drop_y,
    };
    self.sim.push(cmd, SimPush, &pc);
    self.sim.dispatch(cmd, ComputePipeline.groups(n, local_size), 1, 1);
    ComputePipeline.memoryBarrier(
        cmd,
        .{ .compute_shader = true },
        .{ .shader_write = true },
        .{ .compute_shader = true },
        .{ .shader_read = true, .shader_write = true },
    );
}

/// Call between beginRendering and endRendering. The domain is letterboxed
/// to keep its aspect ratio whatever the window shape.
pub fn draw(self: *const Fluid, frame: *Frame) void {
    frame.bindPipeline(&self.draw_pipeline);
    frame.cmd.bindDescriptorSets(.graphics, self.draw_pipeline.layout, 0, &.{self.draw_set}, &.{});

    const view = Math.Vec2.init(.{ @floatFromInt(frame.extent.width), @floatFromInt(frame.extent.height) });
    const grid = Math.Vec2.init(.{ @floatFromInt(self.cfg.width), @floatFromInt(self.cfg.height) });

    const lb = Math.letterbox(grid, view);
    const radius_px = lb.scale * self.cfg.radius_cells;
    // Pixels -> clip space is 2 / view_size.
    const half_size = Math.Vec2.splat(2.0 * radius_px).div(view);

    const push: DrawPush = .{
        .grid = grid.toArray(),
        .fit = lb.fit.toArray(),
        .half_size = half_size.toArray(),
    };
    frame.pushConstants(&self.draw_pipeline, .{ .vertex = true }, DrawPush, &push);
    frame.draw(self.particle_count * 6);
}
