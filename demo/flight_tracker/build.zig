//! Standalone build for the flight tracker demo.
//!
//! This is a self-contained Zig project — it has its own `build.zig.zon`
//! and does not build through the parent serpapi-zig repo's `build.zig`.
//! It exists to show how a downstream project wires the `serpapi` module
//! into its own build, the same way any user project would.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const serpapi = b.dependency("serpapi", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "flight_tracker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "serpapi", .module = serpapi.module("serpapi") }},
        }),
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_exe.addArgs(args);

    const run_step = b.step("run", "Run the flight tracker demo (needs SERPAPI_KEY)");
    run_step.dependOn(&run_exe.step);
}
