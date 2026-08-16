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
    // the name also disambiguates kcov's per-binary report directories
    const mod_tests = b.addTest(.{ .name = "unit-tests", .root_module = mod });
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
    const itests = b.addTest(.{ .name = "integration-tests", .root_module = itest_mod });
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

    // Browser wasm demo: the module that actually runs inside the page.
    // Freestanding, not wasi: browsers give wasm no sockets/TLS, so this
    // module only builds query strings and parses JSON responses; the
    // network request is made by the page's own fetch() (see index.html)
    // against serve.zig's same-origin proxy.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("demo/wasm/serpapi_wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const wasm_exe = b.addExecutable(.{ .name = "serpapi_wasm", .root_module = wasm_mod });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;

    const install_wasm = b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .{ .custom = "demo-wasm" } },
    });
    const install_wasm_html = b.addInstallFileWithDir(
        b.path("demo/wasm/index.html"),
        .{ .custom = "demo-wasm" },
        "index.html",
    );
    const wasm_step = b.step("wasm", "Build the browser wasm demo into zig-out/demo-wasm/");
    wasm_step.dependOn(&install_wasm.step);
    wasm_step.dependOn(&install_wasm_html.step);

    // The wasm demo's compute logic is plain std.heap.page_allocator code,
    // so it is tested natively (fast, no wasm runtime needed) and included
    // in the regular unit test step.
    const wasm_demo_tests_mod = b.createModule(.{
        .root_source_file = b.path("demo/wasm/serpapi_wasm.zig"),
        .target = target,
        .optimize = optimize,
    });
    const wasm_demo_tests = b.addTest(.{ .name = "wasm-demo-tests", .root_module = wasm_demo_tests_mod });
    const run_wasm_demo_tests = b.addRunArtifact(wasm_demo_tests);
    test_step.dependOn(&run_wasm_demo_tests.step);

    // Local dev server: static files + a same-origin proxy to serpapi.com
    // (see demo/wasm/serve.zig for why the proxy exists).
    const demo_config = b.addOptions();
    demo_config.addOption([]const u8, "web_dir", b.getInstallPath(.prefix, "demo-wasm"));

    const serve_exe = b.addExecutable(.{
        .name = "serve",
        .root_module = b.createModule(.{
            .root_source_file = b.path("demo/wasm/serve.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "serpapi", .module = mod },
                .{ .name = "demo_config", .module = demo_config.createModule() },
            },
        }),
    });
    const run_serve = b.addRunArtifact(serve_exe);
    run_serve.step.dependOn(wasm_step);
    const serve_step = b.step("serve", "Serve the browser wasm demo at http://127.0.0.1:8080 (needs SERPAPI_KEY)");
    serve_step.dependOn(&run_serve.step);

    // Code coverage: zig build cov (requires kcov)
    //
    // Zig omits generic (`anytype`) functions that a test binary never
    // instantiates, so a unit-test-only report flatters itself by shrinking
    // the denominator. Both suites are measured and merged to cover the
    // HTTP paths; export SERPAPI_KEY for the full picture.
    const cov_dir = b.pathJoin(&.{ b.install_path, "coverage" });
    // Match on the path fragment rather than an absolute --include-path:
    // the unit-test binary records source paths relative to the build root
    // on Linux, so an absolute include path selects nothing there.
    const include = "--include-pattern=src/";

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

    // Merge the per-run report directories, whose names carry a build hash
    // (`unit-tests.a1b2c3d4`). Handing kcov their parent directory instead
    // silently keeps only one of the two on Linux.
    const cov_merge = b.addSystemCommand(&.{ "sh", "-c", b.fmt(
        "rm -rf {0s}/merged && kcov --merge {0s}/merged {0s}/unit/unit-tests.* {0s}/itest/integration-tests.*",
        .{cov_dir},
    ) });
    cov_merge.has_side_effects = true;
    cov_merge.step.dependOn(&cov_unit.step);
    cov_merge.step.dependOn(&cov_itest.step);

    const cov_step = b.step("cov", "Measure code coverage with kcov (needs kcov; SERPAPI_KEY for full coverage)");
    cov_step.dependOn(&cov_merge.step);

    // Lint: zig build lint (checks formatting)
    const lint = b.addFmt(.{ .paths = &.{ "build.zig", "src", "test", "oobt", "bench", "demo/wasm" }, .check = true });
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
