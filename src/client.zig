//! SerpApi.com client implementation.
//!
//! Features:
//!  * search API (JSON, raw HTML, and Markdown)
//!  * location API
//!  * account API
//!  * search archive API
//!  * persistent HTTP connection (keep-alive, reused between requests)

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Library version, reported to the backend through the `source` parameter.
pub const version = "1.1.0";

/// Backend service host.
pub const backend = "serpapi.com";

/// A single query parameter (key/value pair) as stored internally for the
/// client defaults. Public APIs take anonymous structs instead, e.g.
/// `.{ .q = "coffee", .limit = 3 }`.
pub const Param = struct {
    key: []const u8,
    value: []const u8,
};

/// Errors produced by the client itself. Lower-level network / TLS / memory
/// errors from `std.http` are propagated as-is.
///
/// Every variant records details retrievable through `Client.errorMessage()`.
pub const Error = error{
    /// serpapi.com replied with an error payload (`{"error": "..."}`),
    /// whatever the HTTP status and the requested output format.
    SerpApiError,
    /// HTTP status was not 200 and no error payload was found; the message
    /// holds the raw body, or the status name when the body is empty.
    HttpRequestFailed,
    /// The response body could not be decoded as JSON (or into the
    /// requested type); the message holds the raw body.
    JsonParseError,
};

/// Client for SerpApi.com.
///
/// Query parameters are plain anonymous structs, the same shape
/// `std.json.stringify` accepts: field names are parameter names, values
/// may be strings, integers, floats, or booleans.
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
/// var result = try client.search(.{ .q = "coffee" });
/// defer result.deinit();
/// ```
///
/// A `Client` is not thread-safe: `errorMessage()` reports the last failure
/// seen by the client, so use one instance per thread.
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

    /// Configuration-only option names; every other `init` field becomes a
    /// default query parameter, mirroring serpapi-ruby's constructor hash.
    const config_options = [_][]const u8{ "timeout", "persistent" };

    /// Create a client. The returned pointer is heap-allocated and must be
    /// released with `deinit`.
    ///
    /// `options` is an anonymous struct. Two fields configure the client:
    ///  * `timeout`: HTTP request max timeout in seconds [default: 120s == 2m]
    ///  * `persistent`: keep the socket open to save on SSL handshake /
    ///    reconnection (2x faster) [default: true]
    ///
    /// Every other field (`api_key`, `engine`, `gl`, ...) becomes a default
    /// query parameter applied to every request:
    ///
    /// ```zig
    /// var client = try serpapi.Client.init(allocator, .{
    ///     .api_key = key,
    ///     .engine = "google",
    ///     .timeout = 30,
    /// });
    /// ```
    pub fn init(allocator: Allocator, options: anytype) !*Client {
        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .threaded = .init(allocator, .{}),
            .http = undefined,
            .params = .init(allocator),
            .timeout = if (@hasField(@TypeOf(options), "timeout")) options.timeout else 120,
            .persistent = if (@hasField(@TypeOf(options), "persistent")) options.persistent else true,
        };
        self.http = .{ .allocator = allocator, .io = self.threaded.io() };
        errdefer self.freeParams();

        inline for (@typeInfo(@TypeOf(options)).@"struct".fields) |field| {
            if (comptime isConfigOption(field.name)) continue;
            try self.addParamValue(field.name, @field(options, field.name));
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

    /// Perform a search using SerpApi.com and decode the JSON payload into
    /// a dynamic `std.json.Value` tree. For typed decoding see `searchAs`.
    ///
    /// Note that the raw response from the search engine is converted to JSON
    /// by the SerpApi.com backend; most of the compute is on the backend, not
    /// the client side.
    ///
    /// see: https://serpapi.com/search-api
    ///
    /// `params` override the defaults provided to the constructor:
    /// `client.search(.{ .q = "coffee", .location = "Austin, TX" })`.
    /// Caller owns the result and must call `deinit` on it.
    pub fn search(self: *Client, params: anytype) !std.json.Parsed(std.json.Value) {
        return self.searchAs(std.json.Value, params);
    }

    /// Same as `search` but decodes the payload into `T`, following
    /// `std.json.parseFromSlice`. Unknown JSON fields are ignored, so `T`
    /// only needs to declare the fields you care about:
    ///
    /// ```zig
    /// const Answer = struct {
    ///     search_metadata: struct { id: []const u8, status: []const u8 },
    /// };
    /// var result = try client.searchAs(Answer, .{ .q = "coffee" });
    /// defer result.deinit();
    /// ```
    pub fn searchAs(self: *Client, comptime T: type, params: anytype) !std.json.Parsed(T) {
        return self.getJson(T, "/search", params, &.{});
    }

    /// Perform a search using SerpApi.com and return the raw HTML from the
    /// search engine. Useful for training AI models, RAG, debugging, or when
    /// you need to parse the HTML yourself.
    ///
    /// Caller owns the returned slice and must free it.
    pub fn html(self: *Client, params: anytype) ![]u8 {
        // the backend replies with JSON unless output=html is requested
        const extra: []const Param = if (@hasField(@TypeOf(params), "output"))
            &.{}
        else
            &.{.{ .key = "output", .value = "html" }};
        return self.getRaw("/search", params, extra);
    }

    /// Perform a search using SerpApi.com and return the results as Markdown,
    /// a compact, token-efficient rendering of the search engine result page.
    /// Useful for feeding results straight into LLMs and AI agents.
    ///
    /// Caller owns the returned slice and must free it.
    pub fn md(self: *Client, params: anytype) ![]u8 {
        // the backend replies with JSON unless output=md is requested
        const extra: []const Param = if (@hasField(@TypeOf(params), "output"))
            &.{}
        else
            &.{.{ .key = "output", .value = "md" }};
        return self.getRaw("/search", params, extra);
    }

    /// Get locations using the Location API, as a dynamic JSON tree.
    /// For typed decoding see `locationAs`.
    ///
    /// doc: https://serpapi.com/locations-api
    ///
    /// `params` should include the fields q and limit:
    /// `client.location(.{ .q = "Austin", .limit = 3 })`.
    /// Caller owns the result and must call `deinit` on it.
    pub fn location(self: *Client, params: anytype) !std.json.Parsed(std.json.Value) {
        return self.locationAs(std.json.Value, params);
    }

    /// Same as `location` but decodes the payload into `T`.
    pub fn locationAs(self: *Client, comptime T: type, params: anytype) !std.json.Parsed(T) {
        return self.getJson(T, "/locations.json", params, &.{});
    }

    /// Retrieve a search result from the Search Archive API as a dynamic
    /// JSON tree. For typed decoding see `searchArchiveAs`.
    ///
    /// `search_id` comes from an earlier search: `result.search_metadata.id`.
    /// doc: https://serpapi.com/search-archive-api
    ///
    /// Caller owns the result and must call `deinit` on it.
    pub fn searchArchive(self: *Client, search_id: []const u8) !std.json.Parsed(std.json.Value) {
        return self.searchArchiveAs(std.json.Value, search_id);
    }

    /// Same as `searchArchive` but decodes the payload into `T`.
    pub fn searchArchiveAs(self: *Client, comptime T: type, search_id: []const u8) !std.json.Parsed(T) {
        const endpoint = try self.archiveEndpoint(search_id, "json");
        defer self.allocator.free(endpoint);
        return self.getJson(T, endpoint, .{}, &.{});
    }

    /// Retrieve a search result from the Search Archive API as raw HTML.
    ///
    /// Caller owns the returned slice and must free it.
    pub fn searchArchiveHtml(self: *Client, search_id: []const u8) ![]u8 {
        const endpoint = try self.archiveEndpoint(search_id, "html");
        defer self.allocator.free(endpoint);
        return self.getRaw(endpoint, .{}, &.{});
    }

    /// Retrieve a search result from the Search Archive API as Markdown.
    ///
    /// Caller owns the returned slice and must free it.
    pub fn searchArchiveMd(self: *Client, search_id: []const u8) ![]u8 {
        const endpoint = try self.archiveEndpoint(search_id, "md");
        defer self.allocator.free(endpoint);
        return self.getRaw(endpoint, .{}, &.{});
    }

    /// Get account information using the Account API, as a dynamic JSON
    /// tree, with the api_key provided to the constructor.
    ///
    /// doc: https://serpapi.com/account-api
    ///
    /// To override the api_key, or to decode into your own struct, use
    /// `accountAs`. Caller owns the result and must call `deinit` on it.
    pub fn account(self: *Client) !std.json.Parsed(std.json.Value) {
        return self.accountAs(std.json.Value, .{});
    }

    /// Same as `account` but decodes the payload into `T` and accepts
    /// parameters, e.g. to override the key:
    /// `client.accountAs(std.json.Value, .{ .api_key = "other key" })`.
    pub fn accountAs(self: *Client, comptime T: type, params: anytype) !std.json.Parsed(T) {
        return self.getJson(T, "/account", params, &.{});
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

    fn isConfigOption(comptime name: []const u8) bool {
        for (config_options) |option| {
            if (std.mem.eql(u8, option, name)) return true;
        }
        return false;
    }

    fn isString(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .pointer => |ptr| switch (ptr.size) {
                .slice => ptr.child == u8,
                .one => switch (@typeInfo(ptr.child)) {
                    .array => |arr| arr.child == u8,
                    else => false,
                },
                else => false,
            },
            else => false,
        };
    }

    /// Store a default parameter, stringifying non-string values.
    fn addParamValue(self: *Client, key: []const u8, value: anytype) !void {
        const T = @TypeOf(value);
        if (comptime isString(T)) return self.addParam(key, value);
        switch (@typeInfo(T)) {
            .bool => try self.addParam(key, if (value) "true" else "false"),
            .int, .comptime_int, .float, .comptime_float => {
                const text = try std.fmt.allocPrint(self.allocator, "{d}", .{value});
                defer self.allocator.free(text);
                try self.addParam(key, text);
            },
            else => @compileError("unsupported parameter type: " ++ @typeName(T)),
        }
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

    /// Write one query parameter value, percent-encoding strings and
    /// stringifying integers, floats, and booleans.
    fn writeValue(w: *std.Io.Writer, value: anytype) !void {
        const T = @TypeOf(value);
        if (comptime isString(T)) {
            return std.Uri.Component.percentEncode(w, value, isUrlSafe);
        }
        switch (@typeInfo(T)) {
            .bool => try w.writeAll(if (value) "true" else "false"),
            .int, .comptime_int, .float, .comptime_float => try w.print("{d}", .{value}),
            else => @compileError("unsupported parameter type: " ++ @typeName(T)),
        }
    }

    /// Build the Search Archive path `/searches/<id>.<format>`, percent-encoding
    /// the id so it cannot escape the path. Caller owns the result.
    fn archiveEndpoint(self: *const Client, search_id: []const u8, format: []const u8) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();

        // an Allocating writer only ever fails to allocate
        writeArchiveEndpoint(&out.writer, search_id, format) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    fn writeArchiveEndpoint(w: *std.Io.Writer, search_id: []const u8, format: []const u8) std.Io.Writer.Error!void {
        try w.writeAll("/searches/");
        try std.Uri.Component.percentEncode(w, search_id, isUrlSafe);
        try w.writeByte('.');
        try w.writeAll(format);
    }

    /// Build the full request URL: https://serpapi.com<endpoint>?<query>.
    /// Precedence: call `params`, then `extra`, then constructor defaults.
    fn buildUrl(self: *const Client, allocator: Allocator, endpoint: []const u8, params: anytype, extra: []const Param) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();

        // an Allocating writer only ever fails to allocate
        self.writeUrl(&out.writer, endpoint, params, extra) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    fn writeUrl(self: *const Client, w: *std.Io.Writer, endpoint: []const u8, params: anytype, extra: []const Param) std.Io.Writer.Error!void {
        try w.print("https://{s}{s}", .{ backend, endpoint });

        var separator: u8 = '?';
        inline for (@typeInfo(@TypeOf(params)).@"struct".fields) |field| {
            try w.writeByte(separator);
            separator = '&';
            try std.Uri.Component.percentEncode(w, field.name, isUrlSafe);
            try w.writeByte('=');
            try writeValue(w, @field(params, field.name));
        }
        for (extra) |item| {
            if (hasParam(params, item.key)) continue;
            try w.writeByte(separator);
            separator = '&';
            try std.Uri.Component.percentEncode(w, item.key, isUrlSafe);
            try w.writeByte('=');
            try std.Uri.Component.percentEncode(w, item.value, isUrlSafe);
        }
        for (self.params.items) |item| {
            if (hasParam(params, item.key) or containsKey(extra, item.key)) continue;
            try w.writeByte(separator);
            separator = '&';
            try std.Uri.Component.percentEncode(w, item.key, isUrlSafe);
            try w.writeByte('=');
            try std.Uri.Component.percentEncode(w, item.value, isUrlSafe);
        }
    }

    fn hasParam(params: anytype, key: []const u8) bool {
        inline for (@typeInfo(@TypeOf(params)).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, key)) return true;
        }
        return false;
    }

    fn containsKey(items: []const Param, key: []const u8) bool {
        for (items) |item| {
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

    const Response = struct { body: []u8, status: std.http.Status };

    /// Perform an HTTP GET request against the backend and return the raw
    /// body (caller owns) along with the HTTP status.
    fn get(self: *Client, endpoint: []const u8, params: anytype, extra: []const Param) !Response {
        const url = try self.buildUrl(self.allocator, endpoint, params, extra);
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

    fn getJson(self: *Client, comptime T: type, endpoint: []const u8, params: anytype, extra: []const Param) !std.json.Parsed(T) {
        const response = try self.get(endpoint, params, extra);
        defer self.allocator.free(response.body);

        try self.checkResponse(response.body, response.status);

        const parsed = std.json.parseFromSlice(T, self.allocator, response.body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            try self.setLastError(response.body);
            return Error.JsonParseError;
        };
        return parsed;
    }

    fn getRaw(self: *Client, endpoint: []const u8, params: anytype, extra: []const Param) ![]u8 {
        const response = try self.get(endpoint, params, extra);
        errdefer self.allocator.free(response.body);

        try self.checkResponse(response.body, response.status);
        return response.body;
    }

    /// Apply the error rule shared by every decoder, recording the details
    /// for `errorMessage`:
    ///  * an `{"error": "..."}` payload is `SerpApiError`, whatever the
    ///    HTTP status (serpapi.com uses 200 as well as 4xx for these);
    ///  * otherwise a non-200 status is `HttpRequestFailed`.
    fn checkResponse(self: *Client, body: []const u8, status: std.http.Status) !void {
        if (try self.captureErrorPayload(body)) return Error.SerpApiError;
        if (status != .ok) {
            try self.setLastError(if (body.len > 0) body else @tagName(status));
            return Error.HttpRequestFailed;
        }
    }

    /// Top-level shape of a serpapi.com error payload. Success payloads
    /// parse too (every other field is skipped) and leave `error` null.
    const ErrorPayload = struct { @"error": ?[]const u8 = null };

    /// If `body` is a JSON object carrying a string `error` field, store the
    /// message as the last error and return true. Anything else (HTML,
    /// Markdown, a JSON array, an object without `error`) returns false.
    fn captureErrorPayload(self: *Client, body: []const u8) !bool {
        const parsed = std.json.parseFromSlice(ErrorPayload, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        defer parsed.deinit();
        const message = parsed.value.@"error" orelse return false;
        try self.setLastError(message);
        return true;
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
        .gl = "us",
    });
    defer client.deinit();

    try testing.expectEqual(@as(u32, 30), client.timeout);
    try testing.expect(!client.persistent);
    try testing.expectEqualStrings("google", client.engine().?);
    try testing.expectEqualStrings("secret", client.apiKey().?);
    try testing.expectEqualStrings("us", client.param("gl").?);
    // configuration-only options must not leak into query parameters
    try testing.expectEqual(@as(?[]const u8, null), client.param("timeout"));
    try testing.expectEqual(@as(?[]const u8, null), client.param("persistent"));
}

test "constructor stringifies non-string defaults" {
    var client = try Client.init(testing.allocator, .{
        .limit = 3,
        .no_cache = true,
    });
    defer client.deinit();

    try testing.expectEqualStrings("3", client.param("limit").?);
    try testing.expectEqualStrings("true", client.param("no_cache").?);
}

test "buildUrl merges defaults with call parameters" {
    var client = try Client.init(testing.allocator, .{ .api_key = "secret", .engine = "google" });
    defer client.deinit();

    const url = try client.buildUrl(testing.allocator, "/search", .{ .q = "coffee" }, &.{});
    defer testing.allocator.free(url);

    try testing.expectEqualStrings(
        "https://serpapi.com/search?q=coffee&api_key=secret&engine=google&source=serpapi-zig%3A" ++ version,
        url,
    );
}

test "buildUrl call parameters override defaults" {
    var client = try Client.init(testing.allocator, .{ .engine = "google" });
    defer client.deinit();

    const url = try client.buildUrl(testing.allocator, "/search", .{ .engine = "bing" }, &.{});
    defer testing.allocator.free(url);

    try testing.expectEqualStrings(
        "https://serpapi.com/search?engine=bing&source=serpapi-zig%3A" ++ version,
        url,
    );
}

test "buildUrl stringifies numbers and booleans" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    const url = try client.buildUrl(testing.allocator, "/locations.json", .{
        .q = "Austin",
        .limit = 3,
        .no_cache = true,
    }, &.{});
    defer testing.allocator.free(url);

    try testing.expectEqualStrings(
        "https://serpapi.com/locations.json?q=Austin&limit=3&no_cache=true&source=serpapi-zig%3A" ++ version,
        url,
    );
}

test "buildUrl percent-encodes reserved characters" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    const url = try client.buildUrl(testing.allocator, "/search", .{ .q = "fresh coffee & tea=100%" }, &.{});
    defer testing.allocator.free(url);

    try testing.expectEqualStrings(
        "https://serpapi.com/search?q=fresh%20coffee%20%26%20tea%3D100%25&source=serpapi-zig%3A" ++ version,
        url,
    );
}

test "buildUrl extra parameters yield to call parameters" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    const extra: []const Param = &.{.{ .key = "output", .value = "html" }};

    const url = try client.buildUrl(testing.allocator, "/search", .{ .q = "coffee" }, extra);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(
        "https://serpapi.com/search?q=coffee&output=html&source=serpapi-zig%3A" ++ version,
        url,
    );

    const override = try client.buildUrl(testing.allocator, "/search", .{ .q = "coffee", .output = "json" }, extra);
    defer testing.allocator.free(override);
    try testing.expectEqualStrings(
        "https://serpapi.com/search?q=coffee&output=json&source=serpapi-zig%3A" ++ version,
        override,
    );
}

test "buildUrl markdown output" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    const extra: []const Param = &.{.{ .key = "output", .value = "md" }};

    const url = try client.buildUrl(testing.allocator, "/search", .{ .q = "coffee" }, extra);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(
        "https://serpapi.com/search?q=coffee&output=md&source=serpapi-zig%3A" ++ version,
        url,
    );
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

test "construction cleans up on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: Allocator) !void {
            var client = try Client.init(allocator, .{
                .api_key = "secret",
                .engine = "google",
                .gl = "us",
                .limit = 3,
            });
            defer client.deinit();
        }
    }.run, .{});
}

test "buildUrl cleans up on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: Allocator) !void {
            var client = try Client.init(testing.allocator, .{ .engine = "google" });
            defer client.deinit();

            const url = try client.buildUrl(allocator, "/search", .{ .q = "coffee & tea" }, &.{
                .{ .key = "output", .value = "html" },
            });
            allocator.free(url);
        }
    }.run, .{});
}

test "error reporting cleans up on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: Allocator) !void {
            var client = try Client.init(allocator, .{});
            defer client.deinit();

            // the injected OutOfMemory must propagate, so match the expected
            // errors by hand rather than through expectError
            client.checkResponse("{\"error\":\"Missing query `q` parameter.\"}", .bad_request) catch |err| switch (err) {
                Error.SerpApiError => {},
                else => return err,
            };
            client.checkResponse("not json at all", .bad_request) catch |err| switch (err) {
                Error.HttpRequestFailed => {},
                else => return err,
            };
            try client.checkResponse("{\"search_metadata\":{\"id\":\"1\"}}", .ok);
        }
    }.run, .{});
}

test "checkResponse reports an error payload whatever the status" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    const payload = "{\"error\":\"Missing query `q` parameter.\"}";
    try testing.expectError(Error.SerpApiError, client.checkResponse(payload, .bad_request));
    try testing.expectEqualStrings("Missing query `q` parameter.", client.errorMessage().?);

    // serpapi.com sometimes answers 200 with an error payload
    try testing.expectError(Error.SerpApiError, client.checkResponse(payload, .ok));
    try testing.expectEqualStrings("Missing query `q` parameter.", client.errorMessage().?);

    // the error field is found even when other fields precede it
    try testing.expectError(Error.SerpApiError, client.checkResponse(
        "{\"search_metadata\":{\"status\":\"Error\"},\"error\":\"Google hasn't returned any results for this query.\"}",
        .ok,
    ));
    try testing.expectEqualStrings("Google hasn't returned any results for this query.", client.errorMessage().?);
}

test "checkResponse reports a non-200 status without an error payload" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    try testing.expectError(Error.HttpRequestFailed, client.checkResponse("not json at all", .bad_request));
    try testing.expectEqualStrings("not json at all", client.errorMessage().?);

    try testing.expectError(Error.HttpRequestFailed, client.checkResponse("<html>Bad Gateway</html>", .bad_gateway));
    try testing.expectEqualStrings("<html>Bad Gateway</html>", client.errorMessage().?);

    // an empty body falls back to the status name
    try testing.expectError(Error.HttpRequestFailed, client.checkResponse("", .internal_server_error));
    try testing.expectEqualStrings("internal_server_error", client.errorMessage().?);

    // a non-string error field is not a serpapi error payload
    try testing.expectError(Error.HttpRequestFailed, client.checkResponse("{\"error\":{\"code\":1}}", .bad_request));
    try testing.expectEqualStrings("{\"error\":{\"code\":1}}", client.errorMessage().?);
}

test "checkResponse accepts successful payloads of every format" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    try client.checkResponse("{\"search_metadata\":{\"id\":\"1\"},\"organic_results\":[]}", .ok);
    try client.checkResponse("[{\"id\":1,\"name\":\"Austin, TX\"}]", .ok);
    try client.checkResponse("<!DOCTYPE html><html></html>", .ok);
    try client.checkResponse("# coffee\n\n- [Coffee](https://example.com)\n", .ok);
    try client.checkResponse("", .ok);
    try testing.expectEqual(@as(?[]const u8, null), client.errorMessage());
}

test "archiveEndpoint percent-encodes the search id" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    const plain = try client.archiveEndpoint("68a0d7f2c3b1a9e4f5d6c7b8", "json");
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("/searches/68a0d7f2c3b1a9e4f5d6c7b8.json", plain);

    const hostile = try client.archiveEndpoint("../account?x=1#f", "html");
    defer testing.allocator.free(hostile);
    try testing.expectEqualStrings("/searches/..%2Faccount%3Fx%3D1%23f.html", hostile);
}

test "archiveEndpoint cleans up on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: Allocator) !void {
            var client = try Client.init(allocator, .{});
            defer client.deinit();

            const endpoint = try client.archiveEndpoint("abc/def", "md");
            allocator.free(endpoint);
        }
    }.run, .{});
}
