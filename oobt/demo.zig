//! Out-of-box testing (OOBT) demo application.
//!
//! Runs a real Google search through serpapi.com and prints the top
//! organic results, then uploads a tiny image with the Image API. Usage:
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

    var result = client.search(.{
        .q = "coffee",
        .location = "Austin, TX, Texas, United States",
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

    // a 1x1 transparent PNG; the image_id it returns feeds a google_lens search
    const pixel = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
        "\x00\x00\x00\x0aIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\x0d\x0a\x2d\xb4\x00\x00\x00\x00IEND\xaeB\x60\x82";
    var upload = client.uploadImageBytesAs(struct { image_id: []const u8 }, pixel, "pixel.png", .{}) catch |err| {
        std.debug.print("upload failed: {t} ({s})\n", .{ err, client.errorMessage() orelse "no details" });
        std.process.exit(1);
    };
    defer upload.deinit();
    std.debug.print("image uploaded, image_id: {s}\n", .{upload.value.image_id});
    std.debug.print("serpapi-zig {s} out-of-box test: success\n", .{serpapi.version});
}
