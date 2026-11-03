//! Integration tests against the live serpapi.com backend.
//!
//! These mirror the serpapi-ruby spec suite:
//!  * search API (JSON + HTML decoders, dynamic and typed)
//!  * location API (persistent and non-persistent connections)
//!  * account API
//!  * search archive API
//!  * error reporting on invalid input (message, HTTP status, key-free URL)
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

test "md returns markdown page" {
    const key = apiKey(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(key);

    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = key, .engine = "google" });
    defer client.deinit();

    const page = try client.md(.{ .q = "coffee" });
    defer testing.allocator.free(page);

    try testing.expect(page.len > 0);
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

test "search archive returns a past search as html, markdown, and typed results" {
    const key = apiKey(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(key);

    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = key, .engine = "google" });
    defer client.deinit();

    const Metadata = struct { search_metadata: struct { id: []const u8, status: []const u8 } };
    var original = try client.searchAs(Metadata, .{ .q = "coffee" });
    defer original.deinit();
    const search_id = original.value.search_metadata.id;

    var archived = try client.searchArchiveAs(Metadata, search_id);
    defer archived.deinit();
    try testing.expectEqualStrings(search_id, archived.value.search_metadata.id);
    try testing.expectEqualStrings("Success", archived.value.search_metadata.status);

    const page = try client.searchArchiveHtml(search_id);
    defer testing.allocator.free(page);
    try testing.expect(std.ascii.indexOfIgnoreCase(page, "<html") != null);

    const markdown = try client.searchArchiveMd(search_id);
    defer testing.allocator.free(markdown);
    try testing.expect(markdown.len > 0);
    try testing.expect(std.ascii.indexOfIgnoreCase(markdown, "<html") == null);
}

test "locationAs decodes locations into typed structs" {
    var client = try serpapi.Client.init(testing.allocator, .{});
    defer client.deinit();

    const Location = struct { name: []const u8, canonical_name: []const u8, target_type: []const u8 };
    var result = try client.locationAs([]const Location, .{ .q = "Austin", .limit = 3 });
    defer result.deinit();

    try testing.expect(result.value.len > 0);
    try testing.expect(result.value.len <= 3);
    try testing.expect(std.mem.startsWith(u8, result.value[0].name, "Austin"));
    try testing.expect(result.value[0].canonical_name.len > 0);
}

test "invalid api key reports a serpapi error" {
    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = "invalid_key", .engine = "google" });
    defer client.deinit();

    const result = client.search(.{ .q = "coffee" });
    try testing.expectError(serpapi.Error.SerpApiError, result);
    try testing.expect(client.errorMessage() != null);
}

test "lastError reports the status and a key-free url" {
    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = "invalid_key_0123456789", .engine = "google" });
    defer client.deinit();

    try testing.expectError(serpapi.Error.SerpApiError, client.search(.{ .q = "coffee" }));
    const info = client.lastError().?;
    try testing.expectEqual(std.http.Status.unauthorized, info.status.?);
    try testing.expectEqualStrings(client.errorMessage().?, info.message);
    try testing.expect(std.mem.startsWith(u8, info.url.?, "https://serpapi.com/search?q=coffee&"));
    try testing.expect(std.mem.indexOf(u8, info.url.?, "api_key") == null);
    try testing.expect(std.mem.indexOf(u8, info.url.?, "invalid_key_0123456789") == null);
    try testing.expect(std.mem.indexOf(u8, info.message, "invalid_key_0123456789") == null);

    // the client prints with its key masked
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{client});
    try testing.expect(std.mem.indexOf(u8, out.written(), "invalid_key_0123456789") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "inva****6789") != null);
}

test "lastError reports a 404 from the search archive" {
    const key = apiKey(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(key);

    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = key });
    defer client.deinit();

    try testing.expectError(serpapi.Error.SerpApiError, client.searchArchive("0000000000000000000000ff"));
    const info = client.lastError().?;
    try testing.expectEqual(std.http.Status.not_found, info.status.?);
    try testing.expectEqualStrings("Search not found.", info.message);
    try testing.expect(std.mem.startsWith(u8, info.url.?, "https://serpapi.com/searches/0000000000000000000000ff.json"));
    try testing.expect(std.mem.indexOf(u8, info.url.?, key) == null);
}

test "typed decoding reports a serpapi error instead of a parse error" {
    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = "invalid_key", .engine = "google" });
    defer client.deinit();

    // a struct whose fields are all optional would otherwise decode an
    // error payload as an empty success
    const Answer = struct { search_metadata: ?struct { id: []const u8 } = null };
    const result = client.searchAs(Answer, .{ .q = "coffee" });
    try testing.expectError(serpapi.Error.SerpApiError, result);
    try testing.expect(client.errorMessage() != null);
}

test "missing query reports a serpapi error" {
    const key = apiKey(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(key);

    var client = try serpapi.Client.init(testing.allocator, .{ .api_key = key, .engine = "google" });
    defer client.deinit();

    const result = client.search(.{});
    try testing.expectError(serpapi.Error.SerpApiError, result);
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
