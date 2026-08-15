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

    // Code coverage: zig build cov (requires kcov)
    //
    // Zig omits generic (`anytype`) functions that a test binary never
    // instantiates, so a unit-test-only report flatters itself by shrinking
    // the denominator. Both suites are measured and merged to cover the
    // HTTP paths; export SERPAPI_KEY for the full picture.
    const cov_dir = b.pathJoin(&.{ b.install_path, "coverage" });
    const include = b.fmt("--include-path={s}", .{b.pathFromRoot("src")});

    // kcov does not create missing parent directories
    const cov_mkdir = b.addSystemCommand(&.{ "mkdir", "-p", cov_dir });
    cov_mkdir.has_side_effects = true;

    const cov_unit = b.addSystemCommand(&.{ "kcov", include, b.pathJoin(&.{ cov_dir, "unit" }) });
    cov_unit.addArtifactArg(mod_tests);
    cov_unit.has_side_effects = true;
    cov_unit.step.dependOn(&cov_mkdir.step);

    const cov_itest = b.addSystemCommand(&.{ "kcov", include, b.pathJoin(&.{ cov_dir, "itest" }) });
    cov_itest.addArtifactArg(itests);
    cov_itest.has_side_effects = true;
    cov_itest.step.dependOn(&cov_mkdir.step);

    const cov_merge = b.addSystemCommand(&.{
        "kcov",                              "--merge",
        b.pathJoin(&.{ cov_dir, "merged" }), b.pathJoin(&.{ cov_dir, "unit" }),
        b.pathJoin(&.{ cov_dir, "itest" }),
    });
    cov_merge.has_side_effects = true;
    cov_merge.step.dependOn(&cov_unit.step);
    cov_merge.step.dependOn(&cov_itest.step);

    const cov_step = b.step("cov", "Measure code coverage with kcov (needs kcov; SERPAPI_KEY for full coverage)");
    cov_step.dependOn(&cov_merge.step);

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
