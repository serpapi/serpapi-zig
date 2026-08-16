//! Integration tests against the live serpapi.com backend.
//!
//! These mirror the serpapi-ruby spec suite:
//!  * search API (JSON + HTML decoders, dynamic and typed)
//!  * location API (persistent and non-persistent connections)
//!  * account API
//!  * search archive API
//!  * error reporting on invalid input
//!
//! Tests that need an API key read the SERPAPI_KEY environment variable
//! and are skipped otherwise (e.g. `SERPAPI_KEY=secret zig build itest`).

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

    var result = try client.search(.{
        .q = "coffee",
        .location = "Austin, TX, Texas, United States",
    });
    defer result.deinit();

    const metadata = result.value.object.get("search_metadata").?.object;
    try testing.expectEqualStrings("Success", metadata.get("status").?.string);
    const organic = result.value.object.get("organic_results").?.array;
    try testing.expect(organic.items.len > 1);
}

test "searchAs decodes into a typed struct" {
    const key = apiKey(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(key);

    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = key, .engine = "google" });
    defer client.deinit();

    const Answer = struct {
        search_metadata: struct {
            id: []const u8,
            status: []const u8,
        },
    };

    var result = try client.searchAs(Answer, .{ .q = "coffee" });
    defer result.deinit();

    try testing.expectEqualStrings("Success", result.value.search_metadata.status);
    try testing.expect(result.value.search_metadata.id.len > 0);
}

test "html returns raw page" {
    const key = apiKey(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(key);

    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = key, .engine = "google" });
    defer client.deinit();

    const page = try client.html(.{ .q = "coffee" });
    defer testing.allocator.free(page);

    try testing.expect(std.ascii.indexOfIgnoreCase(page, "<html") != null);
}

test "markdown returns a rendered page" {
    const key = apiKey(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(key);

    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = key, .engine = "google" });
    defer client.deinit();

    const page = try client.markdown(.{ .q = "coffee" });
    defer testing.allocator.free(page);

    try testing.expect(page.len > 0);
    // markdown output must not be an HTML document
    try testing.expect(std.ascii.indexOfIgnoreCase(page, "<html") == null);
}

test "location API returns Austin locations" {
    var client = try serpapi.Client.init(testing.allocator, .{});
    defer client.deinit();

    var result = try client.location(.{ .q = "Austin", .limit = 3 });
    defer result.deinit();

    const locations = result.value.array;
    try testing.expect(locations.items.len > 0);
    const first = locations.items[0].object;
    try testing.expect(std.mem.startsWith(u8, first.get("name").?.string, "Austin"));
}

test "location API works without persistent connection" {
    var client = try serpapi.Client.init(testing.allocator, .{ .persistent = false });
    defer client.deinit();

    try testing.expect(!client.persistent);

    // two sequential requests, each on a fresh connection
    inline for (.{ "Austin", "Dallas" }) |city| {
        var result = try client.location(.{ .q = city, .limit = 3 });
        defer result.deinit();
        try testing.expect(result.value.array.items.len > 0);
    }
}

test "account API returns account info" {
    const key = apiKey(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(key);

    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = key });
    defer client.deinit();

    var result = try client.account();
    defer result.deinit();

    try testing.expect(result.value.object.get("account_id") != null);
    try testing.expect(result.value.object.get("account_email") != null);
}

test "accountAs overrides the constructor api_key" {
    const key = apiKey(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(key);

    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = "invalid_key" });
    defer client.deinit();

    var result = try client.accountAs(std.json.Value, .{ .api_key = key });
    defer result.deinit();

    try testing.expect(result.value.object.get("account_id") != null);
}

test "search archive returns a past search" {
    const key = apiKey(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(key);

    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = key, .engine = "google" });
    defer client.deinit();

    var original = try client.search(.{ .q = "coffee" });
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

    const result = client.search(.{ .q = "coffee" });
    try testing.expectError(serpapi.client.Error.SerpApiError, result);
    try testing.expect(client.errorMessage() != null);
}

test "missing query reports a serpapi error" {
    const key = apiKey(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(key);

    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = key, .engine = "google" });
    defer client.deinit();

    const result = client.search(.{});
    try testing.expectError(serpapi.client.Error.SerpApiError, result);
    const message = client.errorMessage().?;
    try testing.expect(std.ascii.indexOfIgnoreCase(message, "missing query") != null);
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
        var result = try client.search(.{ .q = query });
        defer result.deinit();
        try testing.expect(result.value.object.get("organic_results") != null);
    }
}
