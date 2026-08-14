//! SerpApi.com client implementation.
//!
//! Features:
//!  * search API (JSON and raw HTML)
//!  * location API
//!  * account API
//!  * search archive API
//!  * persistent HTTP connection (keep-alive, reused between requests)

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Library version, reported to the backend through the `source` parameter.
pub const version = "1.0.0";

/// Backend service host.
pub const backend = "serpapi.com";

/// A single query parameter (key/value pair), e.g. `.{ .key = "q", .value = "coffee" }`.
pub const Param = struct {
    key: []const u8,
    value: []const u8,
};

/// Errors produced by the client itself. Lower-level network / TLS / memory
/// errors from `std.http` are propagated as-is.
pub const Error = error{
    /// serpapi.com replied with an error payload; details in `Client.errorMessage()`.
    SerpApiError,
    /// HTTP status was not 200 and no error payload was found.
    HttpRequestFailed,
    /// The response body could not be decoded as JSON.
    JsonParseError,
};

/// Client for SerpApi.com.
///
/// ```zig
/// const serpapi = @import("serpapi");
///
/// var client = try serpapi.Client.init(allocator, .{
///     .api_key = "secure API key",
///     .engine = "google",
/// });
/// defer client.deinit();
///
/// var result = try client.search(&.{.{ .key = "q", .value = "coffee" }});
/// defer result.deinit();
/// ```
pub const Client = struct {
    allocator: Allocator,
    /// Event loop / thread pool backing std.http. Heap-stable inside Client.
    threaded: std.Io.Threaded,
    http: std.http.Client,
    /// Default query parameters applied to every request (owned copies).
    params: std.array_list.Managed(Param),
    /// HTTP request timeout in seconds [default: 120].
    timeout: u32,
    /// Keep the connection open between requests (2x faster). [default: true]
    persistent: bool,
    /// Last error payload returned by serpapi.com (owned), see `errorMessage`.
    last_error: ?[]u8 = null,

    /// Constructor options. All fields are optional.
    pub const Options = struct {
        /// User secret API key.
        api_key: ?[]const u8 = null,
        /// Search engine selected, e.g. "google".
        engine: ?[]const u8 = null,
        /// HTTP request max timeout in seconds [default: 120s == 2m].
        timeout: u32 = 120,
        /// Keep socket connection open to save on SSL handshake /
        /// connection reconnection (2x faster). [default: true]
        persistent: bool = true,
        /// Additional default parameters applied to every search.
        params: []const Param = &.{},
    };

    const Decoder = enum { json, html };

    /// Create a client. The returned pointer is heap-allocated and must be
    /// released with `deinit`.
    pub fn init(allocator: Allocator, options: Options) !*Client {
        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .threaded = .init(allocator, .{}),
            .http = undefined,
            .params = .init(allocator),
            .timeout = options.timeout,
            .persistent = options.persistent,
        };
        self.http = .{ .allocator = allocator, .io = self.threaded.io() };
        errdefer self.freeParams();

        if (options.api_key) |key| try self.addParam("api_key", key);
        if (options.engine) |engine_id| try self.addParam("engine", engine_id);
        for (options.params) |extra| {
            if (std.mem.eql(u8, extra.key, "api_key") and options.api_key != null) continue;
            if (std.mem.eql(u8, extra.key, "engine") and options.engine != null) continue;
            try self.addParam(extra.key, extra.value);
        }
        // track the zig library as a client for statistic purpose
        try self.addParam("source", "serpapi-zig:" ++ version);

        return self;
    }

    /// Release all resources held by the client and close open connections.
    pub fn deinit(self: *Client) void {
        const allocator = self.allocator;
        if (self.last_error) |msg| allocator.free(msg);
        self.freeParams();
        self.http.deinit();
        self.threaded.deinit();
        allocator.destroy(self);
    }

    /// Perform a search using SerpApi.com and decode the JSON payload.
    ///
    /// Note that the raw response from the search engine is converted to JSON
    /// by the SerpApi.com backend; most of the compute is on the backend, not
    /// the client side.
    ///
    /// see: https://serpapi.com/search-api
    ///
    /// `params` override the defaults provided to the constructor.
    /// Caller owns the result and must call `deinit` on it.
    pub fn search(self: *Client, params: []const Param) !std.json.Parsed(std.json.Value) {
        return self.getJson("/search", params);
    }

    /// Perform a search using SerpApi.com and return the raw HTML from the
    /// search engine. Useful for training AI models, RAG, debugging, or when
    /// you need to parse the HTML yourself.
    ///
    /// Caller owns the returned slice and must free it.
    pub fn html(self: *Client, params: []const Param) ![]u8 {
        // the backend replies with JSON unless output=html is requested
        if (containsKey(params, "output")) return self.getHtml("/search", params);
        const with_output = try self.allocator.alloc(Param, params.len + 1);
        defer self.allocator.free(with_output);
        @memcpy(with_output[0..params.len], params);
        with_output[params.len] = .{ .key = "output", .value = "html" };
        return self.getHtml("/search", with_output);
    }

    /// Get locations using the Location API.
    ///
    /// doc: https://serpapi.com/locations-api
    ///
    /// `params` should include the fields: q, limit.
    /// Caller owns the result and must call `deinit` on it.
    pub fn location(self: *Client, params: []const Param) !std.json.Parsed(std.json.Value) {
        return self.getJson("/locations.json", params);
    }

    /// Retrieve a search result from the Search Archive API as JSON.
    ///
    /// `search_id` comes from an earlier search: `result.search_metadata.id`.
    /// doc: https://serpapi.com/search-archive-api
    ///
    /// Caller owns the result and must call `deinit` on it.
    pub fn searchArchive(self: *Client, search_id: []const u8) !std.json.Parsed(std.json.Value) {
        const endpoint = try std.fmt.allocPrint(self.allocator, "/searches/{s}.json", .{search_id});
        defer self.allocator.free(endpoint);
        return self.getJson(endpoint, &.{});
    }

    /// Retrieve a search result from the Search Archive API as raw HTML.
    ///
    /// Caller owns the returned slice and must free it.
    pub fn searchArchiveHtml(self: *Client, search_id: []const u8) ![]u8 {
        const endpoint = try std.fmt.allocPrint(self.allocator, "/searches/{s}.html", .{search_id});
        defer self.allocator.free(endpoint);
        return self.getHtml(endpoint, &.{});
    }

    /// Get account information using the Account API.
    ///
    /// doc: https://serpapi.com/account-api
    ///
    /// `api_key` is optional if already provided to the constructor.
    /// Caller owns the result and must call `deinit` on it.
    pub fn account(self: *Client, api_key: ?[]const u8) !std.json.Parsed(std.json.Value) {
        if (api_key) |key| {
            return self.getJson("/account", &.{.{ .key = "api_key", .value = key }});
        }
        return self.getJson("/account", &.{});
    }

    /// Default search engine as provided to the constructor, if any.
    pub fn engine(self: *const Client) ?[]const u8 {
        return self.param("engine");
    }

    /// User secret API key as provided to the constructor, if any.
    pub fn apiKey(self: *const Client) ?[]const u8 {
        return self.param("api_key");
    }

    /// Error payload from serpapi.com for the last failed request, if any.
    pub fn errorMessage(self: *const Client) ?[]const u8 {
        return self.last_error;
    }

    fn param(self: *const Client, key: []const u8) ?[]const u8 {
        for (self.params.items) |item| {
            if (std.mem.eql(u8, item.key, key)) return item.value;
        }
        return null;
    }

    fn addParam(self: *Client, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.params.append(.{ .key = key_copy, .value = value_copy });
    }

    fn freeParams(self: *Client) void {
        for (self.params.items) |item| {
            self.allocator.free(item.key);
            self.allocator.free(item.value);
        }
        self.params.deinit();
    }

    fn setLastError(self: *Client, message: []const u8) !void {
        const copy = try self.allocator.dupe(u8, message);
        if (self.last_error) |old| self.allocator.free(old);
        self.last_error = copy;
    }

    /// Build the full request URL: https://serpapi.com<endpoint>?<query>.
    /// Call `params` take precedence over constructor defaults.
    fn buildUrl(self: *const Client, allocator: Allocator, endpoint: []const u8, params: []const Param) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const w = &out.writer;

        try w.print("https://{s}{s}", .{ backend, endpoint });

        var separator: u8 = '?';
        for (params) |item| {
            try w.writeByte(separator);
            separator = '&';
            try std.Uri.Component.percentEncode(w, item.key, isUrlSafe);
            try w.writeByte('=');
            try std.Uri.Component.percentEncode(w, item.value, isUrlSafe);
        }
        for (self.params.items) |item| {
            if (containsKey(params, item.key)) continue;
            try w.writeByte(separator);
            separator = '&';
            try std.Uri.Component.percentEncode(w, item.key, isUrlSafe);
            try w.writeByte('=');
            try std.Uri.Component.percentEncode(w, item.value, isUrlSafe);
        }

        return out.toOwnedSlice();
    }

    fn containsKey(params: []const Param, key: []const u8) bool {
        for (params) |item| {
            if (std.mem.eql(u8, item.key, key)) return true;
        }
        return false;
    }

    /// RFC 3986 unreserved characters pass through, everything else is %XX.
    fn isUrlSafe(c: u8) bool {
        return switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
            else => false,
        };
    }

    /// Perform an HTTP GET request against the backend and return the raw
    /// body (caller owns) along with the HTTP status.
    fn get(self: *Client, endpoint: []const u8, params: []const Param) !struct { body: []u8, status: std.http.Status } {
        const url = try self.buildUrl(self.allocator, endpoint, params);
        defer self.allocator.free(url);

        var body: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body.deinit();

        const result = try self.http.fetch(.{
            .location = .{ .url = url },
            .response_writer = &body.writer,
            .keep_alive = self.persistent,
        });

        return .{ .body = try body.toOwnedSlice(), .status = result.status };
    }

    fn getJson(self: *Client, endpoint: []const u8, params: []const Param) !std.json.Parsed(std.json.Value) {
        const response = try self.get(endpoint, params);
        defer self.allocator.free(response.body);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{
            .allocate = .alloc_always,
        }) catch {
            try self.setLastError(response.body);
            return Error.JsonParseError;
        };
        errdefer parsed.deinit();

        // serpapi.com reports failures as an `error` field in the payload.
        if (parsed.value == .object) {
            if (parsed.value.object.get("error")) |error_value| {
                if (error_value == .string) {
                    try self.setLastError(error_value.string);
                    return Error.SerpApiError;
                }
            }
        }
        if (response.status != .ok) {
            try self.setLastError(@tagName(response.status));
            return Error.HttpRequestFailed;
        }
        return parsed;
    }

    fn getHtml(self: *Client, endpoint: []const u8, params: []const Param) ![]u8 {
        const response = try self.get(endpoint, params);
        errdefer self.allocator.free(response.body);

        if (response.status != .ok) {
            try self.setLastError(response.body);
            self.allocator.free(response.body);
            return Error.HttpRequestFailed;
        }
        return response.body;
    }
};

// ---------------------------------------------------------------------------
// Unit tests (no network access required)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "constructor defaults" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    try testing.expectEqual(@as(u32, 120), client.timeout);
    try testing.expect(client.persistent);
    try testing.expectEqual(@as(?[]const u8, null), client.engine());
    try testing.expectEqual(@as(?[]const u8, null), client.apiKey());
    try testing.expectEqualStrings("serpapi-zig:" ++ version, client.param("source").?);
}

test "constructor options" {
    var client = try Client.init(testing.allocator, .{
        .api_key = "secret",
        .engine = "google",
        .timeout = 30,
        .persistent = false,
        .params = &.{.{ .key = "gl", .value = "us" }},
    });
    defer client.deinit();

    try testing.expectEqual(@as(u32, 30), client.timeout);
    try testing.expect(!client.persistent);
    try testing.expectEqualStrings("google", client.engine().?);
    try testing.expectEqualStrings("secret", client.apiKey().?);
    try testing.expectEqualStrings("us", client.param("gl").?);
}

test "buildUrl merges defaults with call parameters" {
    var client = try Client.init(testing.allocator, .{ .api_key = "secret", .engine = "google" });
    defer client.deinit();

    const url = try client.buildUrl(testing.allocator, "/search", &.{
        .{ .key = "q", .value = "coffee" },
    });
    defer testing.allocator.free(url);

    try testing.expectEqualStrings(
        "https://serpapi.com/search?q=coffee&api_key=secret&engine=google&source=serpapi-zig%3A" ++ version,
        url,
    );
}

test "buildUrl call parameters override defaults" {
    var client = try Client.init(testing.allocator, .{ .engine = "google" });
    defer client.deinit();

    const url = try client.buildUrl(testing.allocator, "/search", &.{
        .{ .key = "engine", .value = "bing" },
    });
    defer testing.allocator.free(url);

    try testing.expectEqualStrings(
        "https://serpapi.com/search?engine=bing&source=serpapi-zig%3A" ++ version,
        url,
    );
}

test "buildUrl percent-encodes reserved characters" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    const url = try client.buildUrl(testing.allocator, "/search", &.{
        .{ .key = "q", .value = "fresh coffee & tea=100%" },
    });
    defer testing.allocator.free(url);

    try testing.expectEqualStrings(
        "https://serpapi.com/search?q=fresh%20coffee%20%26%20tea%3D100%25&source=serpapi-zig%3A" ++ version,
        url,
    );
}

test "constructor extra params do not duplicate api_key or engine" {
    var client = try Client.init(testing.allocator, .{
        .api_key = "secret",
        .engine = "google",
        .params = &.{
            .{ .key = "api_key", .value = "ignored" },
            .{ .key = "engine", .value = "ignored" },
            .{ .key = "hl", .value = "en" },
        },
    });
    defer client.deinit();

    try testing.expectEqualStrings("secret", client.apiKey().?);
    try testing.expectEqualStrings("google", client.engine().?);
    try testing.expectEqualStrings("en", client.param("hl").?);
}

test "setLastError replaces previous error" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    try testing.expectEqual(@as(?[]const u8, null), client.errorMessage());
    try client.setLastError("first");
    try testing.expectEqualStrings("first", client.errorMessage().?);
    try client.setLastError("second");
    try testing.expectEqualStrings("second", client.errorMessage().?);
}
