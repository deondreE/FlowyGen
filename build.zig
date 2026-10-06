const std = @import("std");
const builtin = @import("builtin");

const shader_files = [_][]const u8{
    "triangle.vert",
    "triangle.frag",
};

const ShaderCompiler = enum {
    glslc,
    glslangValidator,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("flowygen", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "flowygen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "flowygen", .module = mod },
            },
        }),
    });

    const vulkan_sdk = b.graph.environ_map.get("VULKAN_SDK") orelse
        if (builtin.os.tag == .windows)
            "C:\\VulkanSDK\\1.4.357.0"
        else
            "/usr";
    const registry_path = b.pathJoin(&.{ vulkan_sdk, "share", "vulkan", "registry", "vk.xml" });

    const vulkan = b.dependency("vulkan", .{
        .registry = std.Build.LazyPath{ .cwd_relative = registry_path },
    }).module("vulkan-zig");
    exe.root_module.addImport("vulkan", vulkan);

    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
        .import_vulkan = true,
    });
    exe.root_module.addImport("zglfw", zglfw.module("root"));
    exe.root_module.linkLibrary(zglfw.artifact("glfw"));

    // addShaders(b, exe);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn addShaders(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const compiler = b.option(ShaderCompiler, "shader-compiler", "GLSL to SPIR-V compiler: glslc") orelse .glslc;

    const shaders_step = b.step("shaders", "Compile GLSL shaders to SPIR-V");

    for (shader_files) |shader| {
        const run = b.addSystemCommand(&.{@tagName(compiler)});
        switch (compiler) {
            .glslangValidator => {
                //run.addArg(&.{ "-V", "--target-env", "vulkan1.3" });
                run.stdio = .inherit;
            },
            .glslc => {}, //run.addArg(&.{"--target-env=vulkan1.3"}),
        }
        run.addFileArg(b.path(b.fmt("src/shaders/{s}", .{shader})));
        run.addArg("-o");
        const spv = run.addOutputFileArg(b.fmt("{s}.spv", .{shader}));

        shaders_step.dependOn(&run.step);
        exe.root_module.addImport(b.fmt("{s}.spv", .{shader}), b.createModule(.{ .root_source_file = spv }));
    }
}
