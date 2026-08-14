const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // serpapi module: zero dependency, std only.
    const mod = b.addModule("serpapi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests: zig build test
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // Integration tests (hit serpapi.com, require SERPAPI_KEY): zig build itest
    const itest_mod = b.createModule(.{
        .root_source_file = b.path("test/integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "serpapi", .module = mod }},
    });
    const itests = b.addTest(.{ .root_module = itest_mod });
    const run_itests = b.addRunArtifact(itests);
    const itest_step = b.step("itest", "Run integration tests against serpapi.com (needs SERPAPI_KEY)");
    itest_step.dependOn(&run_itests.step);

    // Out-of-box testing demo: zig build oobt
    const demo = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("oobt/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "serpapi", .module = mod }},
        }),
    });
    b.installArtifact(demo);
    const run_demo = b.addRunArtifact(demo);
    const oobt_step = b.step("oobt", "Run out-of-box testing demo (needs SERPAPI_KEY)");
    oobt_step.dependOn(&run_demo.step);

    // Benchmark persistent vs non-persistent connections: zig build bench
    const bench = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "serpapi", .module = mod }},
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Benchmark persistent vs non-persistent connections (needs SERPAPI_KEY)");
    bench_step.dependOn(&run_bench.step);

    // Lint: zig build lint (checks formatting)
    const lint = b.addFmt(.{ .paths = &.{ "build.zig", "src", "test", "oobt", "bench" }, .check = true });
    const lint_step = b.step("lint", "Check code formatting (zig fmt --check)");
    lint_step.dependOn(&lint.step);

    // Docs: zig build doc
    const doc_obj = b.addObject(.{ .name = "serpapi", .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = doc_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const doc_step = b.step("doc", "Build documentation");
    doc_step.dependOn(&install_docs.step);
}
