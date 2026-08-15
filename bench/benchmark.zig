//! Benchmark: SerpApi client with and without persistent connection.
//!
//! Demonstrates that persistent (keep-alive) connections are ~2x quicker
//! than reconnecting for every request, by timing sequential searches.
//! Results are printed and appended to a CSV file:
//!   serpapi_zig_<zig_version>_<timestamp>.csv
//!
//! Usage:
//!   SERPAPI_KEY=secret_api_key zig build bench

const std = @import("std");
const builtin = @import("builtin");
const serpapi = @import("serpapi");

/// number of sequential requests per run
const n = 10;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const key = init.environ_map.get("SERPAPI_KEY") orelse {
        std.debug.print("SERPAPI_KEY environment variable is required\n", .{});
        std.process.exit(1);
    };

    const csv_path = try csvPath(allocator, unixSeconds(init.io));
    defer allocator.free(csv_path);
    var csv = try std.Io.Dir.cwd().createFile(init.io, csv_path, .{});
    defer csv.close(init.io);
    var csv_buffer: [512]u8 = undefined;
    var csv_writer = csv.writer(init.io, &csv_buffer);
    const out = &csv_writer.interface;
    try out.writeAll("timestamp,client_type,connection_type,requests_count,total_time_seconds,avg_time_per_request,requests_per_second,zig_version\n");

    inline for (.{ false, true }) |persistent| {
        const label = if (persistent) "persistent" else "non-persistent";
        std.debug.print("start SerpApi benchmark: {d} requests, {s} connection\n", .{ n, label });

        var client = try serpapi.Client.init(allocator, .{
            .api_key = key,
            .engine = "google",
            .persistent = persistent,
        });
        defer client.deinit();

        const started = std.Io.Clock.now(.awake, init.io);
        var query_buffer: [32]u8 = undefined;
        for (0..n) |i| {
            const query = try std.fmt.bufPrint(&query_buffer, "coffee {d}", .{if (persistent) n + i else i});
            var result = try client.search(.{ .q = query });
            result.deinit();
        }
        const elapsed_ns = std.Io.Clock.now(.awake, init.io).nanoseconds - started.nanoseconds;
        const runtime: f64 = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;

        std.debug.print("{s} took {d:.5}s to complete {d} requests\n", .{ label, runtime, n });
        try out.print("{d},SerpApi,{s},{d},{d:.5},{d:.5},{d:.2},{s}\n", .{
            unixSeconds(init.io),
            label,
            n,
            runtime,
            runtime / n,
            n / runtime,
            builtin.zig_version_string,
        });
    }

    try out.flush();
    std.debug.print("benchmark results saved to: {s}\n", .{csv_path});
}

fn unixSeconds(io: std.Io) i64 {
    const ts = std.Io.Clock.now(.real, io);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
}

fn csvPath(allocator: std.mem.Allocator, timestamp: i64) ![]u8 {
    const version = comptime blk: {
        var buffer: [32]u8 = undefined;
        const printed = std.fmt.bufPrint(&buffer, "{d}_{d}_{d}", .{
            builtin.zig_version.major,
            builtin.zig_version.minor,
            builtin.zig_version.patch,
        }) catch unreachable;
        break :blk printed[0..printed.len].*;
    };
    return std.fmt.allocPrint(allocator, "serpapi_zig_{s}_{d}.csv", .{ version, timestamp });
}
