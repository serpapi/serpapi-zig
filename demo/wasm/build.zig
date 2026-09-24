//! Standalone build for the browser wasm demo.
//!
//! This is a self-contained Zig project — it has its own `build.zig.zon`
//! and does not build through the parent serpapi-zig repo's `build.zig`.
//! It exists to show how a downstream project wires the `serpapi` module
//! into its own build, the same way any user project would (see `serve.zig`,
//! the only piece here that imports it — `serpapi_wasm.zig` runs in the
//! browser and has no dependency on the library at all).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const serpapi = b.dependency("serpapi", .{
        .target = target,
        .optimize = optimize,
    });

    // Unit tests: zig build test
    // The wasm demo's compute logic is plain std.heap.page_allocator code,
    // so it is tested natively (fast, no wasm runtime needed).
    const wasm_demo_tests_mod = b.createModule(.{
        .root_source_file = b.path("serpapi_wasm.zig"),
        .target = target,
        .optimize = optimize,
    });
    const wasm_demo_tests = b.addTest(.{ .name = "wasm-demo-tests", .root_module = wasm_demo_tests_mod });
    const run_wasm_demo_tests = b.addRunArtifact(wasm_demo_tests);
    const test_step = b.step("test", "Run unit tests (no wasm runtime or browser required)");
    test_step.dependOn(&run_wasm_demo_tests.step);

    // Browser wasm demo: the module that actually runs inside the page.
    // Freestanding, not wasi: browsers give wasm no sockets/TLS, so this
    // module only builds query strings and parses JSON responses; the
    // network request is made by the page's own fetch() (see index.html)
    // against serve.zig's same-origin proxy.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("serpapi_wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const wasm_exe = b.addExecutable(.{ .name = "serpapi_wasm", .root_module = wasm_mod });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;

    const install_wasm = b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    });
    const install_wasm_html = b.addInstallFileWithDir(
        b.path("index.html"),
        .{ .custom = "web" },
        "index.html",
    );
    const wasm_step = b.step("wasm", "Build the browser wasm demo into zig-out/web/");
    wasm_step.dependOn(&install_wasm.step);
    wasm_step.dependOn(&install_wasm_html.step);

    // Local dev server: static files + a same-origin proxy to serpapi.com
    // (see serve.zig for why the proxy exists).
    const demo_config = b.addOptions();
    demo_config.addOption([]const u8, "web_dir", b.getInstallPath(.prefix, "web"));

    const serve_exe = b.addExecutable(.{
        .name = "serve",
        .root_module = b.createModule(.{
            .root_source_file = b.path("serve.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "serpapi", .module = serpapi.module("serpapi") },
                .{ .name = "demo_config", .module = demo_config.createModule() },
            },
        }),
    });
    const run_serve = b.addRunArtifact(serve_exe);
    run_serve.step.dependOn(wasm_step);
    const serve_step = b.step("serve", "Serve the browser wasm demo at http://127.0.0.1:8080 (needs SERPAPI_KEY)");
    serve_step.dependOn(&run_serve.step);

    b.default_step.dependOn(wasm_step);
}
