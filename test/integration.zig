//! Integration tests against the live serpapi.com backend.
//!
//! These mirror the serpapi-ruby spec suite:
//!  * search API (JSON + HTML decoders)
//!  * location API
//!  * account API
//!  * search archive API
//!  * error reporting on invalid input
//!
//! They require the SERPAPI_KEY environment variable and are skipped
//! otherwise (e.g. `SERPAPI_KEY=secret zig build itest`).

const std = @import("std");
const serpapi = @import("serpapi");
const testing = std.testing;

fn apiKey(allocator: std.mem.Allocator) ?[]u8 {
    return std.testing.environ.getAlloc(allocator, "SERPAPI_KEY") catch null;
}

test "search returns coffee results from google" {
    const key = apiKey(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(key);

    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = key, .engine = "google" });
    defer client.deinit();

    var result = try client.search(&.{
        .{ .key = "q", .value = "coffee" },
        .{ .key = "location", .value = "Austin, TX, Texas, United States" },
    });
    defer result.deinit();

    const metadata = result.value.object.get("search_metadata").?.object;
    try testing.expectEqualStrings("Success", metadata.get("status").?.string);
    const organic = result.value.object.get("organic_results").?.array;
    try testing.expect(organic.items.len > 1);
}

test "html returns raw page" {
    const key = apiKey(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(key);

    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = key, .engine = "google" });
    defer client.deinit();

    const page = try client.html(&.{.{ .key = "q", .value = "coffee" }});
    defer testing.allocator.free(page);

    try testing.expect(std.mem.indexOf(u8, page, "<html") != null);
}

test "location API returns Austin locations" {
    var client = try serpapi.Client.init(testing.allocator, .{});
    defer client.deinit();

    var result = try client.location(&.{
        .{ .key = "q", .value = "Austin" },
        .{ .key = "limit", .value = "3" },
    });
    defer result.deinit();

    const locations = result.value.array;
    try testing.expect(locations.items.len > 0);
    const first = locations.items[0].object;
    try testing.expect(std.mem.startsWith(u8, first.get("name").?.string, "Austin"));
}

test "account API returns account info" {
    const key = apiKey(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(key);

    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = key });
    defer client.deinit();

    var result = try client.account(null);
    defer result.deinit();

    try testing.expect(result.value.object.get("account_id") != null);
    try testing.expect(result.value.object.get("account_email") != null);
}

test "search archive returns a past search" {
    const key = apiKey(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(key);

    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = key, .engine = "google" });
    defer client.deinit();

    var original = try client.search(&.{.{ .key = "q", .value = "coffee" }});
    defer original.deinit();
    const search_id = original.value.object.get("search_metadata").?.object.get("id").?.string;

    var archived = try client.searchArchive(search_id);
    defer archived.deinit();

    const archived_id = archived.value.object.get("search_metadata").?.object.get("id").?.string;
    try testing.expectEqualStrings(search_id, archived_id);
}

test "invalid api key reports a serpapi error" {
    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = "invalid_key", .engine = "google" });
    defer client.deinit();

    const result = client.search(&.{.{ .key = "q", .value = "coffee" }});
    try testing.expectError(serpapi.client.Error.SerpApiError, result);
    try testing.expect(client.errorMessage() != null);
}

test "missing query reports a serpapi error" {
    const key = apiKey(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(key);

    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = key, .engine = "google" });
    defer client.deinit();

    const result = client.search(&.{});
    try testing.expectError(serpapi.client.Error.SerpApiError, result);
    try testing.expect(client.errorMessage() != null);
}

test "persistent connection performs multiple searches" {
    const key = apiKey(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(key);

    var client = try serpapi.Client.init(testing.allocator, .{
        .api_key = key,
        .engine = "google",
        .persistent = true,
    });
    defer client.deinit();

    inline for (.{ "coffee", "tea" }) |query| {
        var result = try client.search(&.{.{ .key = "q", .value = query }});
        defer result.deinit();
        try testing.expect(result.value.object.get("organic_results") != null);
    }
}
