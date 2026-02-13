const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const phant_dep = b.dependency("phant", .{ .target = target, .optimize = optimize });
    const phant_mod = phant_dep.module("phant");

    // Build evmone from phant's submodule
    const phant_root = phant_dep.path(".");
    _ = phant_root;
    const evmone_cmake_config_step = b.addSystemCommand(&.{
        "cmake", "-S",
    });
    evmone_cmake_config_step.addDirectoryArg(phant_dep.path("evmone"));
    evmone_cmake_config_step.addArgs(&.{ "-B", "zig-out/evmone_build" });

    const evmone_cmake_build_step = b.addSystemCommand(&.{ "cmake", "--build", "zig-out/evmone_build" });
    evmone_cmake_build_step.step.dependOn(&evmone_cmake_config_step.step);

    // Create main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "phant", .module = phant_mod },
        },
    });
    exe_mod.addLibraryPath(.{ .cwd_relative = "zig-out/evmone_build/lib" });
    exe_mod.linkSystemLibrary("evmone", .{});

    const exe = b.addExecutable(.{
        .name = "blocktests",
        .root_module = exe_mod,
    });
    exe.step.dependOn(&evmone_cmake_build_step.step);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the block tests");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "phant", .module = phant_mod },
        },
    });
    test_mod.addLibraryPath(.{ .cwd_relative = "zig-out/evmone_build/lib" });
    test_mod.linkSystemLibrary("evmone", .{});

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    unit_tests.step.dependOn(&evmone_cmake_build_step.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
