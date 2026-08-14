//! Out-of-box testing (OOBT) demo application.
//!
//! Runs a real Google search through serpapi.com and prints the top
//! organic results. Usage:
//!
//!   SERPAPI_KEY=secret_api_key zig build oobt

const std = @import("std");
const serpapi = @import("serpapi");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const key = init.environ_map.get("SERPAPI_KEY") orelse {
        std.debug.print("SERPAPI_KEY environment variable is required\n", .{});
        std.process.exit(1);
    };

    var client = try serpapi.Client.init(allocator, .{ .api_key = key, .engine = "google" });
    defer client.deinit();

    var result = client.search(&.{
        .{ .key = "q", .value = "coffee" },
        .{ .key = "location", .value = "Austin, TX, Texas, United States" },
    }) catch |err| {
        std.debug.print("search failed: {t} ({s})\n", .{ err, client.errorMessage() orelse "no details" });
        std.process.exit(1);
    };
    defer result.deinit();

    const organic = result.value.object.get("organic_results").?.array;
    std.debug.print("top {d} organic results for \"coffee\":\n", .{organic.items.len});
    for (organic.items) |item| {
        const title = item.object.get("title").?.string;
        const link = item.object.get("link").?.string;
        std.debug.print(" - {s}\n   {s}\n", .{ title, link });
    }
    std.debug.print("serpapi-zig {s} out-of-box test: success\n", .{serpapi.version});
}
