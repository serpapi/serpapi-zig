//! SerpApi.com client implementation.
//!
//! Features:
//!  * search API (JSON, raw HTML, and Markdown)
//!  * location API
//!  * account API
//!  * search archive API
//!  * image API (upload an image for Google Lens and friends)
//!  * persistent HTTP connection (keep-alive, reused between requests)

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Library version, reported to the backend through the `source` parameter.
/// Single-sourced from `build.zig.zon` via `build.zig`.
pub const version: []const u8 = @import("build_options").version;

/// Backend service host.
pub const backend = "serpapi.com";

/// Image API endpoint, the target of `uploadImage`.
const image_url = "https://" ++ backend ++ "/image";

/// Largest image the Image API accepts, in bytes (500 KiB). `uploadImage`
/// and `uploadImageBytes` reject anything bigger before sending it.
pub const image_max_size = 500 * 1024;

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
    /// The request did not complete within `timeout` seconds. The connection
    /// is dropped; the next request opens a fresh one.
    Timeout,
    /// The image passed to `uploadImage` / `uploadImageBytes` is larger than
    /// `image_max_size`; nothing was sent.
    ImageTooLarge,
};

/// Details of the last failed request, from `Client.lastError()`. The
/// strings are owned by the client and valid until its next request or
/// `deinit`.
///
/// Every request starts by clearing it, so it only ever describes the most
/// recent call: it is null after a success, and after a transport error
/// (DNS, connection, TLS), which carries no details beyond the Zig error.
pub const ErrorInfo = struct {
    /// What went wrong; the same text as `Client.errorMessage()`.
    message: []const u8,
    /// HTTP status of the failed response, or null when no response was
    /// received (`error.Timeout`).
    status: ?std.http.Status = null,
    /// The request URL without the `api_key`, safe to log.
    url: ?[]const u8 = null,
    /// `search_metadata.id` from the error payload, when serpapi.com
    /// assigned one to the failed search.
    search_id: ?[]const u8 = null,
};

/// The API key as held by the client. Formatting with `{f}` masks it, and
/// it is kept behind a many-item pointer so that `{any}` on the client
/// prints an address, never the key bytes.
const Secret = struct {
    ptr: [*]const u8,
    len: usize,

    fn reveal(self: Secret) []const u8 {
        return self.ptr[0..self.len];
    }

    /// Mask the key as serpapi-ruby's `Client#inspect` does: the first and
    /// last four characters of a key longer than eight, `****` otherwise.
    pub fn format(self: Secret, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const key = self.reveal();
        if (key.len > 8) {
            try w.print("{s}****{s}", .{ key[0..4], key[key.len - 4 ..] });
        } else {
            try w.writeAll("****");
        }
    }
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
/// A `Client` is not thread-safe: `errorMessage()` and `lastError()` report
/// the last failure seen by the client, so use one instance per thread.
pub const Client = struct {
    allocator: Allocator,
    /// Event loop / thread pool backing std.http. Heap-stable inside Client.
    threaded: std.Io.Threaded,
    http: std.http.Client,
    /// Default query parameters applied to every request (owned copies),
    /// except the API key, which lives in `api_key`.
    params: std.array_list.Managed(Param),
    /// API key provided to the constructor (owned), see `apiKey`. Sent
    /// along with `params`, but never printed.
    api_key: ?Secret = null,
    /// HTTP request timeout in seconds, 0 to wait forever [default: 120].
    timeout: u32,
    /// Keep the connection open between requests (3-4x faster). [default: true]
    persistent: bool,
    /// Last failure (owned strings), see `lastError` and `errorMessage`.
    last_error: ?ErrorInfo = null,

    /// Configuration-only option names; every other `init` field becomes a
    /// default query parameter, mirroring serpapi-ruby's constructor hash.
    const config_options = [_][]const u8{ "timeout", "persistent" };

    /// Create a client. The returned pointer is heap-allocated and must be
    /// released with `deinit`.
    ///
    /// `options` is an anonymous struct. Two fields configure the client:
    ///  * `timeout`: HTTP request max timeout in seconds [default: 120s == 2m].
    ///    Covers the whole request, from connecting to the last body byte;
    ///    an overrun returns `error.Timeout`. 0 disables the limit.
    ///  * `persistent`: keep the socket open to save on SSL handshake /
    ///    reconnection (3-4x faster) [default: true]
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
        errdefer self.freeApiKey();

        inline for (@typeInfo(@TypeOf(options)).@"struct".fields) |field| {
            if (comptime isConfigOption(field.name)) continue;
            if (comptime std.mem.eql(u8, field.name, "api_key")) {
                const key = try allocator.dupe(u8, options.api_key);
                self.api_key = .{ .ptr = key.ptr, .len = key.len };
                continue;
            }
            try self.addParamValue(field.name, @field(options, field.name));
        }
        // track the zig library as a client for statistic purpose
        try self.addParam("source", "serpapi-zig:" ++ version);

        return self;
    }

    /// Release all resources held by the client and close open connections.
    pub fn deinit(self: *Client) void {
        const allocator = self.allocator;
        self.clearLastError();
        self.freeApiKey();
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

    /// Upload an image file with the Image API, returning the payload as a
    /// dynamic JSON tree. Its `image_id` can be handed to engines that take
    /// an uploaded image, such as Google Lens:
    ///
    /// ```zig
    /// var upload = try client.uploadImage("./image.jpg", .{});
    /// defer upload.deinit();
    /// const image_id = upload.value.object.get("image_id").?.string;
    /// var results = try client.search(.{ .engine = "google_lens", .image_id = image_id });
    /// ```
    ///
    /// Supported formats: jpg, jpeg, png and webp, up to `image_max_size`
    /// bytes; a bigger file fails with `error.ImageTooLarge` before it is
    /// read. File errors such as `error.FileNotFound` are propagated as-is.
    /// The `image_id` expires after 10 minutes.
    ///
    /// doc: https://serpapi.com/image-api
    ///
    /// `path` is absolute or relative to the current working directory; its
    /// base name is sent as the file name. `params` go along as form fields,
    /// e.g. `.{ .api_key = "other key" }` to override the constructor key;
    /// a field named `image` is a compile error, as that field is the file.
    /// Other constructor defaults (`engine`, `output`, ...) are not sent.
    /// Caller owns the result and must call `deinit` on it.
    pub fn uploadImage(self: *Client, path: []const u8, params: anytype) !std.json.Parsed(std.json.Value) {
        return self.uploadImageAs(std.json.Value, path, params);
    }

    /// Same as `uploadImage` but decodes the payload into `T`, e.g.
    /// `struct { image_id: []const u8 }`.
    pub fn uploadImageAs(self: *Client, comptime T: type, path: []const u8, params: anytype) !std.json.Parsed(T) {
        // a file error returns before fetch, which would otherwise clear it
        self.clearLastError();
        const image = try self.readImage(path);
        defer self.allocator.free(image);
        return self.uploadImageBytesAs(T, image, std.fs.path.basename(path), params);
    }

    /// Upload an in-memory image with the Image API, as `uploadImage` does
    /// for a file. `file_name` is sent as the file name, extension included
    /// (`"image.png"`); the content type is detected from the image bytes,
    /// falling back to the extension.
    ///
    /// Caller owns the result and must call `deinit` on it.
    pub fn uploadImageBytes(self: *Client, image: []const u8, file_name: []const u8, params: anytype) !std.json.Parsed(std.json.Value) {
        return self.uploadImageBytesAs(std.json.Value, image, file_name, params);
    }

    /// Same as `uploadImageBytes` but decodes the payload into `T`.
    pub fn uploadImageBytesAs(self: *Client, comptime T: type, image: []const u8, file_name: []const u8, params: anytype) !std.json.Parsed(T) {
        self.clearLastError();
        try self.checkImageSize(image.len);

        var content_type_buffer: [multipart_content_type_len]u8 = undefined;
        const content_type = multipartContentType(self.threaded.io(), &content_type_buffer);
        const boundary = content_type[multipart_prefix.len..];

        var body: std.Io.Writer.Allocating = .init(self.allocator);
        defer body.deinit();
        // an Allocating writer only ever fails to allocate
        self.writeImageForm(&body.writer, boundary, image, file_name, params) catch return error.OutOfMemory;

        const response = self.post("/image", content_type, body.written()) catch |err| {
            if (err == Error.Timeout) try self.recordFixedUrl(image_url);
            return err;
        };
        return self.decodeJson(T, response) catch |err| {
            if (err != error.OutOfMemory) try self.recordFixedUrl(image_url);
            return err;
        };
    }

    /// Default search engine as provided to the constructor, if any.
    pub fn engine(self: *const Client) ?[]const u8 {
        return self.param("engine");
    }

    /// User secret API key as provided to the constructor, if any.
    pub fn apiKey(self: *const Client) ?[]const u8 {
        const key = self.api_key orelse return null;
        return key.reveal();
    }

    /// Description of the most recent request's failure, if any: the error
    /// payload from serpapi.com, the raw body of a non-200 response, or the
    /// client's own message. Null after a success or a transport error. See
    /// `lastError` for the HTTP status, URL and search id.
    pub fn errorMessage(self: *const Client) ?[]const u8 {
        const info = self.last_error orelse return null;
        return info.message;
    }

    /// Details of the most recent request's failure, if any: message, HTTP
    /// status, URL without the api_key, and search id. Mirrors the fields of
    /// serpapi-ruby's `SerpApiError`. Null after a success or a transport
    /// error, see `ErrorInfo`.
    ///
    /// ```zig
    /// var results = client.search(.{ .q = "coffee" }) catch |err| {
    ///     if (client.lastError()) |info| {
    ///         std.debug.print("{t}: HTTP {?d} {?s}: {s}\n", .{
    ///             err, if (info.status) |s| @intFromEnum(s) else null, info.url, info.message,
    ///         });
    ///     }
    ///     return err;
    /// };
    /// ```
    pub fn lastError(self: *const Client) ?ErrorInfo {
        return self.last_error;
    }

    /// Print the client configuration with the API key masked, as
    /// serpapi-ruby's `Client#inspect` does, e.g.
    /// `serpapi.Client{ .engine = "google", .timeout = 120, .persistent = true, .api_key = "abcd****wxyz" }`.
    /// Use it with `{f}`: `std.debug.print("{f}\n", .{client})`.
    pub fn format(self: *const Client, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("serpapi.Client{ .engine = ");
        if (self.engine()) |name| try w.print("\"{s}\"", .{name}) else try w.writeAll("null");
        try w.print(", .timeout = {d}, .persistent = {}, .api_key = ", .{ self.timeout, self.persistent });
        if (self.api_key) |key| try w.print("\"{f}\"", .{key}) else try w.writeAll("null");
        try w.writeAll(" }");
    }

    fn param(self: *const Client, key: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, key, "api_key")) return self.apiKey();
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

    fn freeApiKey(self: *Client) void {
        if (self.api_key) |key| self.allocator.free(key.reveal());
        self.api_key = null;
    }

    fn clearLastError(self: *Client) void {
        const info = self.last_error orelse return;
        self.allocator.free(info.message);
        if (info.url) |url| self.allocator.free(url);
        if (info.search_id) |id| self.allocator.free(id);
        self.last_error = null;
    }

    /// Record `info` as the last failure, copying its strings.
    fn fail(self: *Client, info: ErrorInfo) Allocator.Error!void {
        const message = try self.allocator.dupe(u8, info.message);
        errdefer self.allocator.free(message);
        const url = if (info.url) |url| try self.allocator.dupe(u8, url) else null;
        errdefer if (url) |u| self.allocator.free(u);
        const search_id = if (info.search_id) |id| try self.allocator.dupe(u8, id) else null;

        self.clearLastError();
        self.last_error = .{ .message = message, .status = info.status, .url = url, .search_id = search_id };
    }

    fn setLastError(self: *Client, message: []const u8) Allocator.Error!void {
        return self.fail(.{ .message = message });
    }

    /// Attach the URL of the request that just failed to the last error,
    /// leaving out the api_key.
    fn recordUrl(self: *Client, endpoint: []const u8, params: anytype, extra: []const Param) Allocator.Error!void {
        if (self.last_error) |*info| {
            const url = try self.buildUrlWith(self.allocator, endpoint, params, extra, .omit);
            if (info.url) |old| self.allocator.free(old);
            info.url = url;
        }
    }

    /// Attach a fixed URL to the last error. For the upload, whose URL
    /// never carries a parameter: the api_key travels in the body.
    fn recordFixedUrl(self: *Client, url: []const u8) Allocator.Error!void {
        if (self.last_error) |*info| {
            const copy = try self.allocator.dupe(u8, url);
            if (info.url) |old| self.allocator.free(old);
            info.url = copy;
        }
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

    /// Build the Search Archive path `/searches/<id>.<extension>`, percent-encoding
    /// the id so it cannot escape the path. Caller owns the result.
    fn archiveEndpoint(self: *const Client, search_id: []const u8, extension: []const u8) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();

        // an Allocating writer only ever fails to allocate
        writeArchiveEndpoint(&out.writer, search_id, extension) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    fn writeArchiveEndpoint(w: *std.Io.Writer, search_id: []const u8, extension: []const u8) std.Io.Writer.Error!void {
        try w.writeAll("/searches/");
        try std.Uri.Component.percentEncode(w, search_id, isUrlSafe);
        try w.writeByte('.');
        try w.writeAll(extension);
    }

    /// Build the full request URL: https://serpapi.com<endpoint>?<query>.
    /// Precedence: call `params`, then `extra`, then constructor defaults.
    fn buildUrl(self: *const Client, allocator: Allocator, endpoint: []const u8, params: anytype, extra: []const Param) Allocator.Error![]u8 {
        return self.buildUrlWith(allocator, endpoint, params, extra, .include);
    }

    /// Whether a URL carries the `api_key`: the request URL does, the one
    /// recorded for error reporting does not.
    const ApiKeyMode = enum { include, omit };

    fn buildUrlWith(self: *const Client, allocator: Allocator, endpoint: []const u8, params: anytype, extra: []const Param, comptime mode: ApiKeyMode) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();

        // an Allocating writer only ever fails to allocate
        self.writeUrl(&out.writer, endpoint, params, extra, mode) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    fn writeUrl(self: *const Client, w: *std.Io.Writer, endpoint: []const u8, params: anytype, extra: []const Param, comptime mode: ApiKeyMode) std.Io.Writer.Error!void {
        try w.print("https://{s}{s}", .{ backend, endpoint });

        var separator: u8 = '?';
        inline for (@typeInfo(@TypeOf(params)).@"struct".fields) |field| {
            if (mode == .omit and comptime std.mem.eql(u8, field.name, "api_key")) continue;
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
        if (self.api_key) |key| if (mode == .include and !hasParam(params, "api_key")) {
            try w.writeByte(separator);
            separator = '&';
            try w.writeAll("api_key=");
            try std.Uri.Component.percentEncode(w, key.reveal(), isUrlSafe);
        };
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

    /// Constructor defaults the Image API takes; search defaults such as
    /// `engine` or `output` are meaningless there and are not sent.
    const image_form_defaults = [_][]const u8{ "api_key", "source" };

    /// Read the image file at `path`, checking its size before loading it.
    /// Caller owns the result.
    fn readImage(self: *Client, path: []const u8) ![]u8 {
        const io = self.threaded.io();
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        const size = try file.length(io);
        try self.checkImageSize(size);

        const image = try self.allocator.alloc(u8, @intCast(size));
        errdefer self.allocator.free(image);
        const read = try file.readPositionalAll(io, image, 0);
        // the file shrank since `length`: hand back what is there
        if (read < image.len) return self.allocator.realloc(image, read);
        return image;
    }

    fn checkImageSize(self: *Client, size: u64) !void {
        if (size <= image_max_size) return;
        const message = try std.fmt.allocPrint(
            self.allocator,
            "image is too large: {d} bytes, the Image API limit is {d} bytes",
            .{ size, image_max_size },
        );
        defer self.allocator.free(message);
        try self.setLastError(message);
        return Error.ImageTooLarge;
    }

    /// Content-Type of a multipart body, up to its boundary.
    const multipart_prefix = "multipart/form-data; boundary=";
    /// The boundary is "serpapi-zig-" followed by 32 random hex digits.
    const multipart_content_type_len = multipart_prefix.len + "serpapi-zig-".len + 32;

    /// Fill `buffer` with a multipart/form-data Content-Type carrying a
    /// random boundary, `content_type[multipart_prefix.len..]`. 128 random
    /// bits make a collision with the image bytes practically impossible.
    fn multipartContentType(io: std.Io, buffer: *[multipart_content_type_len]u8) []const u8 {
        var random: [16]u8 = undefined;
        io.random(&random);
        return std.fmt.bufPrint(buffer, multipart_prefix ++ "serpapi-zig-{x}", .{&random}) catch unreachable;
    }

    /// Write the Image API multipart/form-data body: the call `params`,
    /// then the `api_key` and `source` defaults they do not override, then
    /// the image itself in the `image` field. A call parameter named
    /// `image` would send a second `image` part, so it is a compile error.
    fn writeImageForm(
        self: *const Client,
        w: *std.Io.Writer,
        boundary: []const u8,
        image: []const u8,
        file_name: []const u8,
        params: anytype,
    ) std.Io.Writer.Error!void {
        inline for (@typeInfo(@TypeOf(params)).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "image")) {
                @compileError("the `image` form field carries the uploaded file; it cannot be a parameter");
            }
            try writeFormFieldHead(w, boundary, field.name);
            try writeFormValue(w, @field(params, field.name));
            try w.writeAll("\r\n");
        }
        for (image_form_defaults) |key| {
            if (hasParam(params, key)) continue;
            const value = self.param(key) orelse continue;
            try writeFormFieldHead(w, boundary, key);
            try w.writeAll(value);
            try w.writeAll("\r\n");
        }

        try w.print("--{s}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"", .{boundary});
        try writeQuoted(w, file_name);
        try w.print("\"\r\nContent-Type: {s}\r\n\r\n", .{imageMimeType(image, file_name)});
        try w.writeAll(image);
        try w.print("\r\n--{s}--\r\n", .{boundary});
    }

    fn writeFormFieldHead(w: *std.Io.Writer, boundary: []const u8, name: []const u8) std.Io.Writer.Error!void {
        try w.print("--{s}\r\nContent-Disposition: form-data; name=\"", .{boundary});
        try writeQuoted(w, name);
        try w.writeAll("\"\r\n\r\n");
    }

    /// Write a form field value as is, stringifying integers, floats, and
    /// booleans.
    fn writeFormValue(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
        const T = @TypeOf(value);
        if (comptime isString(T)) return w.writeAll(value);
        switch (@typeInfo(T)) {
            .bool => try w.writeAll(if (value) "true" else "false"),
            .int, .comptime_int, .float, .comptime_float => try w.print("{d}", .{value}),
            else => @compileError("unsupported parameter type: " ++ @typeName(T)),
        }
    }

    /// Write a Content-Disposition name or filename, escaping the characters
    /// that would end the quoted string or the header line, the way browsers
    /// do (WHATWG HTML, multipart/form-data encoding).
    fn writeQuoted(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
        for (text) |c| switch (c) {
            '"' => try w.writeAll("%22"),
            '\r' => try w.writeAll("%0D"),
            '\n' => try w.writeAll("%0A"),
            else => try w.writeByte(c),
        };
    }

    /// Guess the image content type from its signature, falling back to the
    /// file extension. The Image API supports jpg, jpeg, png and webp.
    fn imageMimeType(image: []const u8, file_name: []const u8) []const u8 {
        if (std.mem.startsWith(u8, image, "\xFF\xD8\xFF")) return "image/jpeg";
        if (std.mem.startsWith(u8, image, "\x89PNG\r\n\x1a\n")) return "image/png";
        if (image.len >= 12 and std.mem.startsWith(u8, image, "RIFF") and std.mem.eql(u8, image[8..12], "WEBP")) {
            return "image/webp";
        }
        const extension = std.fs.path.extension(file_name);
        const types = [_]struct { []const u8, []const u8 }{
            .{ ".jpg", "image/jpeg" },
            .{ ".jpeg", "image/jpeg" },
            .{ ".png", "image/png" },
            .{ ".webp", "image/webp" },
        };
        for (types) |entry| {
            if (std.ascii.eqlIgnoreCase(extension, entry[0])) return entry[1];
        }
        return "application/octet-stream";
    }

    const Response = struct { body: []u8, status: std.http.Status };

    /// One HTTP request to the backend: a GET, or a POST when `body` is set.
    const Outgoing = struct {
        url: []const u8,
        body: ?Body = null,

        const Body = struct { content_type: []const u8, bytes: []const u8 };
    };

    /// Perform an HTTP GET request against the backend and return the raw
    /// body (caller owns) along with the HTTP status.
    fn get(self: *Client, endpoint: []const u8, params: anytype, extra: []const Param) !Response {
        const url = try self.buildUrl(self.allocator, endpoint, params, extra);
        defer self.allocator.free(url);
        return self.send(.{ .url = url });
    }

    /// Perform an HTTP POST request against the backend. Nothing goes in the
    /// URL: every parameter, `api_key` included, travels in the body.
    fn post(self: *Client, endpoint: []const u8, content_type: []const u8, body: []const u8) !Response {
        const url = try std.fmt.allocPrint(self.allocator, "https://{s}{s}", .{ backend, endpoint });
        defer self.allocator.free(url);
        return self.send(.{ .url = url, .body = .{ .content_type = content_type, .bytes = body } });
    }

    /// Send `request` under the client's timeout and return the raw body
    /// (caller owns) along with the HTTP status.
    fn send(self: *Client, request: Outgoing) !Response {
        var body: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body.deinit();

        const status = try self.fetch(request, &body.writer);
        return .{ .body = try body.toOwnedSlice(), .status = status };
    }

    /// Outcome of racing the request against the timeout timer.
    const Race = union(enum) {
        request: FetchError!std.http.Status,
        timer: std.Io.Cancelable!void,
    };

    /// Issue the request, writing the response body to `w`. When `timeout`
    /// is non-zero the request runs on its own thread and is canceled once
    /// the timer fires, so a stalled connection cannot block the caller
    /// forever.
    ///
    /// Every request goes through here, so this is where the previous
    /// call's failure is forgotten: `lastError()` describes this call only.
    fn fetch(self: *Client, request: Outgoing, w: *std.Io.Writer) !std.http.Status {
        self.clearLastError();
        if (self.timeout == 0) return fetchStatus(&self.http, request, w, self.persistent);

        const io = self.threaded.io();
        var buffer: [2]Race = undefined;
        var race: std.Io.Select(Race) = .init(io, &buffer);
        // cancels the loser and waits for it to finish, so `w` is quiescent
        // by the time the caller reads it
        defer race.cancelDiscard();

        const deadline: std.Io.Timeout = .{ .duration = .{
            .raw = .fromSeconds(self.timeout),
            .clock = .awake,
        } };
        // Both tasks need their own unit of concurrency: run inline, the
        // timer would block for the whole timeout and the request could not
        // be interrupted. Without concurrency (single-threaded builds),
        // fall back to an unbounded request rather than fail.
        race.concurrent(.timer, std.Io.Timeout.sleep, .{ deadline, io }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => return fetchStatus(&self.http, request, w, self.persistent),
        };
        race.concurrent(.request, fetchStatus, .{ &self.http, request, w, self.persistent }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => return fetchStatus(&self.http, request, w, self.persistent),
        };

        switch (try race.await()) {
            .request => |status| return status,
            .timer => {
                const message = try std.fmt.allocPrint(self.allocator, "request timed out after {d}s", .{self.timeout});
                defer self.allocator.free(message);
                try self.setLastError(message);
                return Error.Timeout;
            },
        }
    }

    /// Errors from `fetchStatus`: everything `std.http.Client.fetch` reports,
    /// plus body decoding failures surfaced while draining the framing.
    const FetchError = std.http.Client.FetchError || std.http.Reader.BodyError || Allocator.Error;

    /// Send `request` and stream the decoded response body to `w`, returning
    /// the status.
    ///
    /// This mirrors `std.http.Client.fetch`, with one addition. When the
    /// body is compressed *and* chunked (serpapi.com's default), the
    /// decompressor stops at the end of the gzip stream, leaving the
    /// terminating `0\r\n\r\n` chunk unread. std's `fetch` then sees the
    /// body as unfinished and closes the connection, so `keep_alive` was
    /// silently a no-op and every request paid for a new TLS handshake.
    /// Draining the framing marks the body complete and lets the connection
    /// return to the pool. Measured: ~4x faster on repeated searches.
    fn fetchStatus(http: *std.http.Client, request: Outgoing, w: *std.Io.Writer, keep_alive: bool) FetchError!std.http.Status {
        const uri = try std.Uri.parse(request.url);

        var req = try http.request(if (request.body == null) .GET else .POST, uri, .{
            // Follow up to 3 redirects for a GET, as std.http.Client.fetch
            // does. A POST is not repeatable: a redirect comes back as its
            // non-200 status rather than being replayed as a GET.
            .redirect_behavior = if (request.body == null) @enumFromInt(3) else .unhandled,
            .keep_alive = keep_alive,
            .headers = .{ .content_type = if (request.body) |body| .{ .override = body.content_type } else .default },
        });
        defer req.deinit();

        if (request.body) |body| {
            req.transfer_encoding = .{ .content_length = body.bytes.len };
            var body_writer = try req.sendBodyUnflushed(&.{});
            try body_writer.writer.writeAll(body.bytes);
            try body_writer.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try http.allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try http.allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer http.allocator.free(decompress_buffer);

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        _ = reader.streamRemaining(w) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            else => |e| return e,
        };

        // Consume whatever transfer framing the decompressor left behind so
        // `req.deinit` sees a finished body and keeps the connection.
        switch (req.reader.state) {
            .body_remaining_chunk_len, .body_remaining_content_length => {
                _ = req.reader.interface.discardRemaining() catch |err| switch (err) {
                    error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
                };
            },
            else => {},
        }

        return response.head.status;
    }

    fn getJson(self: *Client, comptime T: type, endpoint: []const u8, params: anytype, extra: []const Param) !std.json.Parsed(T) {
        const response = try self.getChecked(endpoint, params, extra);
        defer self.allocator.free(response.body);

        const parsed = std.json.parseFromSlice(T, self.allocator, response.body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            try self.fail(.{ .message = response.body, .status = response.status });
            try self.recordUrl(endpoint, params, extra);
            return Error.JsonParseError;
        };
        return parsed;
    }

    /// Check `response` and decode its JSON body into `T`, consuming the body.
    /// Used by the upload, whose failures carry the fixed `/image` URL.
    fn decodeJson(self: *Client, comptime T: type, response: Response) !std.json.Parsed(T) {
        defer self.allocator.free(response.body);

        try self.checkResponse(response.body, response.status);

        const parsed = std.json.parseFromSlice(T, self.allocator, response.body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            try self.fail(.{ .message = response.body, .status = response.status });
            return Error.JsonParseError;
        };
        return parsed;
    }

    fn getRaw(self: *Client, endpoint: []const u8, params: anytype, extra: []const Param) ![]u8 {
        const response = try self.getChecked(endpoint, params, extra);
        return response.body;
    }

    /// `get`, then apply `checkResponse`. A failure the client recorded (an
    /// error payload, a non-200 status, a timeout) also records the request
    /// URL, without the api_key, for `lastError`.
    fn getChecked(self: *Client, endpoint: []const u8, params: anytype, extra: []const Param) !Response {
        const response = self.get(endpoint, params, extra) catch |err| {
            if (err == Error.Timeout) try self.recordUrl(endpoint, params, extra);
            return err;
        };
        errdefer self.allocator.free(response.body);

        self.checkResponse(response.body, response.status) catch |err| {
            if (err != error.OutOfMemory) try self.recordUrl(endpoint, params, extra);
            return err;
        };
        return response;
    }

    /// Apply the error rule shared by every decoder, recording the details
    /// for `errorMessage` and `lastError`:
    ///  * an `{"error": "..."}` payload is `SerpApiError`, whatever the
    ///    HTTP status (serpapi.com uses 200 as well as 4xx for these);
    ///  * otherwise a non-200 status is `HttpRequestFailed`.
    fn checkResponse(self: *Client, body: []const u8, status: std.http.Status) !void {
        if (try self.captureErrorPayload(body, status)) return Error.SerpApiError;
        if (status != .ok) {
            try self.fail(.{ .message = if (body.len > 0) body else @tagName(status), .status = status });
            return Error.HttpRequestFailed;
        }
    }

    /// Top-level shape of a serpapi.com error payload. Success payloads
    /// parse too (every other field is skipped) and leave `error` null.
    const ErrorPayload = struct { @"error": ?[]const u8 = null };

    /// Search id carried by an error payload. Parsed on its own so that an
    /// unexpected `search_metadata` shape cannot hide the error itself.
    const ErrorMetadata = struct { search_metadata: ?struct { id: ?[]const u8 = null } = null };

    /// If `body` is a JSON object carrying a string `error` field, store the
    /// message, `status` and search id as the last error and return true.
    /// Anything else (HTML, Markdown, a JSON array, an object without
    /// `error`) returns false.
    fn captureErrorPayload(self: *Client, body: []const u8, status: std.http.Status) !bool {
        const parsed = std.json.parseFromSlice(ErrorPayload, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        defer parsed.deinit();
        const message = parsed.value.@"error" orelse return false;
        const metadata = std.json.parseFromSlice(ErrorMetadata, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        defer if (metadata) |m| m.deinit();
        const search_id = if (metadata) |m| if (m.value.search_metadata) |meta| meta.id else null else null;
        try self.fail(.{ .message = message, .status = status, .search_id = search_id });
        return true;
    }
};

// ---------------------------------------------------------------------------
// Unit tests (no network access required)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "version is the semantic version from build.zig.zon" {
    const parsed = try std.SemanticVersion.parse(version);
    try testing.expect(parsed.major >= 1);
}

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

test "fetch gives up after the timeout" {
    var client = try Client.init(testing.allocator, .{ .timeout = 2 });
    defer client.deinit();
    const io = client.threaded.io();

    // The kernel completes the TCP handshake on our behalf, but nobody ever
    // accepts or answers, so the request stalls waiting for the response.
    const loopback: std.Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var server = try loopback.listen(io, .{});
    defer server.deinit(io);

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/search", .{server.socket.address.getPort()});
    defer testing.allocator.free(url);

    var body: std.Io.Writer.Allocating = .init(testing.allocator);
    defer body.deinit();

    const started = std.Io.Clock.now(.awake, io);
    try testing.expectError(Error.Timeout, client.fetch(.{ .url = url }, &body.writer));
    const elapsed_ns = std.Io.Clock.now(.awake, io).nanoseconds - started.nanoseconds;

    try testing.expectEqualStrings("request timed out after 2s", client.errorMessage().?);
    // Generous bounds: this only needs to catch a race that fires wildly
    // early (e.g. the timer winning immediately) or not at all (hanging).
    // Exact-second bounds are flaky under CI clock jitter, particularly on
    // Windows where sleeping is implemented via thread parking rather than
    // a monotonic clock deadline.
    try testing.expect(elapsed_ns >= std.time.ns_per_s);
    try testing.expect(elapsed_ns < 30 * std.time.ns_per_s);
}

test "fetch returns before the timeout when the server answers" {
    var client = try Client.init(testing.allocator, .{ .timeout = 30 });
    defer client.deinit();
    const io = client.threaded.io();

    const loopback: std.Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var server = try loopback.listen(io, .{});
    defer server.deinit(io);

    const Answer = struct {
        fn serve(server_ptr: *std.Io.net.Server, server_io: std.Io) !void {
            var stream = try server_ptr.accept(server_io);
            defer stream.close(server_io);
            var read_buffer: [4096]u8 = undefined;
            var reader = stream.reader(server_io, &read_buffer);
            // consume the request head
            _ = try reader.interface.discardDelimiterInclusive('\n');
            while (true) {
                const line = try reader.interface.takeDelimiterInclusive('\n');
                if (line.len <= 2) break;
            }
            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(server_io, &write_buffer);
            try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\n{\"ok\":true}\n");
            try writer.interface.flush();
        }
    };
    var answer = try io.concurrent(Answer.serve, .{ &server, io });
    defer _ = answer.cancel(io) catch {};

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/search", .{server.socket.address.getPort()});
    defer testing.allocator.free(url);

    var body: std.Io.Writer.Allocating = .init(testing.allocator);
    defer body.deinit();

    const status = try client.fetch(.{ .url = url }, &body.writer);
    try testing.expectEqual(std.http.Status.ok, status);
    try testing.expectEqualStrings("{\"ok\":true}\n", body.written());
    try answer.await(io);
}

test "persistent connection is reused after a chunked gzip response" {
    var client = try Client.init(testing.allocator, .{ .timeout = 30 });
    defer client.deinit();
    const io = client.threaded.io();

    const loopback: std.Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var server = try loopback.listen(io, .{});
    defer server.deinit(io);

    // serpapi.com's default framing: Transfer-Encoding: chunked + gzip.
    // Two requests are answered on the same accepted connection; the second
    // can only succeed if the client kept the first connection alive.
    const Server = struct {
        fn serve(server_ptr: *std.Io.net.Server, server_io: std.Io, allocator: Allocator) !void {
            var stream = try server_ptr.accept(server_io);
            defer stream.close(server_io);
            var read_buffer: [4096]u8 = undefined;
            var reader = stream.reader(server_io, &read_buffer);
            var write_buffer: [1024]u8 = undefined;
            var writer = stream.writer(server_io, &write_buffer);

            var gz: std.Io.Writer.Allocating = .init(allocator);
            defer gz.deinit();
            try gz.ensureUnusedCapacity(64);
            const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
            defer allocator.free(window);
            var compress: std.compress.flate.Compress = try .init(&gz.writer, window, .gzip, .default);
            try compress.writer.writeAll("{\"ok\":true}");
            try compress.finish();
            try gz.writer.flush();
            const payload = gz.written();

            for (0..2) |_| {
                while (true) {
                    const line = try reader.interface.takeDelimiterInclusive('\n');
                    if (line.len <= 2) break;
                }
                try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n");
                try writer.interface.print("{x}\r\n", .{payload.len});
                try writer.interface.writeAll(payload);
                try writer.interface.writeAll("\r\n0\r\n\r\n");
                try writer.interface.flush();
            }
        }
    };
    var served = try io.concurrent(Server.serve, .{ &server, io, testing.allocator });
    defer _ = served.cancel(io) catch {};

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/search", .{server.socket.address.getPort()});
    defer testing.allocator.free(url);

    for (0..2) |_| {
        var body: std.Io.Writer.Allocating = .init(testing.allocator);
        defer body.deinit();
        try testing.expectEqual(std.http.Status.ok, try client.fetch(.{ .url = url }, &body.writer));
        try testing.expectEqualStrings("{\"ok\":true}", body.written());
        try testing.expectEqual(@as(usize, 1), client.http.connection_pool.free_len);
    }
    try served.await(io);
}

test "format masks the api key like serpapi-ruby's inspect" {
    var client = try Client.init(testing.allocator, .{ .api_key = "0123456789abcdef", .engine = "google" });
    defer client.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{client});
    try testing.expectEqualStrings(
        "serpapi.Client{ .engine = \"google\", .timeout = 120, .persistent = true, .api_key = \"0123****cdef\" }",
        out.written(),
    );

    // a short key is masked whole
    var short = try Client.init(testing.allocator, .{ .api_key = "12345678", .timeout = 5, .persistent = false });
    defer short.deinit();
    out.clearRetainingCapacity();
    try out.writer.print("{f}", .{short.*});
    try testing.expectEqualStrings(
        "serpapi.Client{ .engine = null, .timeout = 5, .persistent = false, .api_key = \"****\" }",
        out.written(),
    );

    var anonymous = try Client.init(testing.allocator, .{});
    defer anonymous.deinit();
    out.clearRetainingCapacity();
    try out.writer.print("{f}", .{anonymous});
    try testing.expect(std.mem.endsWith(u8, out.written(), ".api_key = null }"));
}

test "the api key does not show up when printing the client state with {any}" {
    var client = try Client.init(testing.allocator, .{ .api_key = "0123456789abcdef", .engine = "google" });
    defer client.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    // well past the default depth: every byte that is reachable gets printed
    try out.writer.printValue("any", .{}, client.params.items, 10);
    try out.writer.printValue("any", .{}, client.api_key, 10);
    try out.writer.printValue("any", .{}, client.last_error, 10);

    const printed = out.written();
    try testing.expect(std.mem.indexOf(u8, printed, "0123456789abcdef") == null);
    // nor as the decimal byte values `{any}` prints for a []const u8
    try testing.expect(std.mem.indexOf(u8, printed, "48, 49, 50, 51") == null);
    try testing.expect(std.mem.indexOf(u8, printed, "103, 111, 111, 103, 108, 101") != null); // "google" is printed
    try testing.expectEqualStrings("0123456789abcdef", client.apiKey().?);
}

test "lastError reports the status of a non-200 response" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    try testing.expectEqual(@as(?ErrorInfo, null), client.lastError());

    try testing.expectError(Error.HttpRequestFailed, client.checkResponse("Not Found", .not_found));
    var info = client.lastError().?;
    try testing.expectEqual(std.http.Status.not_found, info.status.?);
    try testing.expectEqualStrings("Not Found", info.message);
    try testing.expectEqual(@as(?[]const u8, null), info.search_id);

    try testing.expectError(Error.HttpRequestFailed, client.checkResponse("<html>Bad Gateway</html>", .bad_gateway));
    info = client.lastError().?;
    try testing.expectEqual(std.http.Status.bad_gateway, info.status.?);
    try testing.expectEqualStrings("<html>Bad Gateway</html>", info.message);
    try testing.expectEqualStrings(info.message, client.errorMessage().?);
}

test "lastError reports the search id of an error payload" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    try testing.expectError(Error.SerpApiError, client.checkResponse(
        "{\"search_metadata\":{\"id\":\"68a0d7f2\",\"status\":\"Error\"},\"error\":\"Google hasn't returned any results for this query.\"}",
        .ok,
    ));
    const info = client.lastError().?;
    try testing.expectEqual(std.http.Status.ok, info.status.?);
    try testing.expectEqualStrings("68a0d7f2", info.search_id.?);
    try testing.expectEqualStrings("Google hasn't returned any results for this query.", info.message);

    // an unexpected search_metadata shape does not hide the error
    try testing.expectError(Error.SerpApiError, client.checkResponse("{\"search_metadata\":[1],\"error\":\"boom\"}", .bad_request));
    try testing.expectEqualStrings("boom", client.errorMessage().?);
    try testing.expectEqual(@as(?[]const u8, null), client.lastError().?.search_id);
}

test "recordUrl leaves the api key out of the reported URL" {
    var client = try Client.init(testing.allocator, .{ .api_key = "secret_key", .engine = "google" });
    defer client.deinit();

    // nothing to attach the URL to without a failure
    try client.recordUrl("/search", .{ .q = "coffee" }, &.{});
    try testing.expectEqual(@as(?ErrorInfo, null), client.lastError());

    try testing.expectError(Error.SerpApiError, client.checkResponse("{\"error\":\"Invalid API key.\"}", .unauthorized));
    try client.recordUrl("/search", .{ .q = "coffee" }, &.{.{ .key = "output", .value = "html" }});
    try testing.expectEqualStrings(
        "https://serpapi.com/search?q=coffee&output=html&engine=google&source=serpapi-zig%3A" ++ version,
        client.lastError().?.url.?,
    );

    // a key passed with the call is left out as well
    try client.recordUrl("/account", .{ .api_key = "call_key" }, &.{});
    try testing.expectEqualStrings(
        "https://serpapi.com/account?engine=google&source=serpapi-zig%3A" ++ version,
        client.lastError().?.url.?,
    );
    try testing.expectEqual(std.http.Status.unauthorized, client.lastError().?.status.?);

    // the request URL itself still carries the key, the call's first
    const url = try client.buildUrl(testing.allocator, "/account", .{ .api_key = "call_key" }, &.{});
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(
        "https://serpapi.com/account?api_key=call_key&engine=google&source=serpapi-zig%3A" ++ version,
        url,
    );
}

test "failure details clean up on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: Allocator) !void {
            var client = try Client.init(allocator, .{ .api_key = "secret_key" });
            defer client.deinit();

            client.checkResponse("{\"search_metadata\":{\"id\":\"1\"},\"error\":\"boom\"}", .bad_request) catch |err| switch (err) {
                Error.SerpApiError => {},
                else => return err,
            };
            try client.recordUrl("/search", .{ .q = "coffee" }, &.{});
            client.checkResponse("Bad Gateway", .bad_gateway) catch |err| switch (err) {
                Error.HttpRequestFailed => {},
                else => return err,
            };
        }
    }.run, .{});
}

test "lastError only describes the most recent request" {
    var client = try Client.init(testing.allocator, .{ .timeout = 30 });
    defer client.deinit();
    const io = client.threaded.io();

    const loopback: std.Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var server = try loopback.listen(io, .{});
    var listening = true;
    defer if (listening) server.deinit(io);

    const Answer = struct {
        fn serve(server_ptr: *std.Io.net.Server, server_io: std.Io) !void {
            var stream = try server_ptr.accept(server_io);
            defer stream.close(server_io);
            var read_buffer: [4096]u8 = undefined;
            var reader = stream.reader(server_io, &read_buffer);
            while (true) {
                const line = try reader.interface.takeDelimiterInclusive('\n');
                if (line.len <= 2) break;
            }
            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(server_io, &write_buffer);
            try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}");
            try writer.interface.flush();
        }
    };
    var answer = try io.concurrent(Answer.serve, .{ &server, io });
    defer _ = answer.cancel(io) catch {};

    const port = server.socket.address.getPort();
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/search", .{port});
    defer testing.allocator.free(url);

    // a 404 is recorded...
    try testing.expectError(Error.HttpRequestFailed, client.checkResponse("Not Found", .not_found));
    try client.recordUrl("/search", .{ .q = "coffee" }, &.{});
    try testing.expectEqual(std.http.Status.not_found, client.lastError().?.status.?);

    // ...and forgotten as soon as the next request starts
    var body: std.Io.Writer.Allocating = .init(testing.allocator);
    defer body.deinit();
    try testing.expectEqual(std.http.Status.ok, try client.fetch(.{ .url = url }, &body.writer));
    try answer.await(io);
    try testing.expectEqual(@as(?ErrorInfo, null), client.lastError());
    try testing.expectEqual(@as(?[]const u8, null), client.errorMessage());

    // a transport error leaves nothing behind either, not the older 404
    try testing.expectError(Error.HttpRequestFailed, client.checkResponse("Not Found", .not_found));
    server.deinit(io); // nobody listens on the port any more
    listening = false;
    body.clearRetainingCapacity();
    try testing.expectError(error.ConnectionRefused, client.fetch(.{ .url = url }, &body.writer));
    try testing.expectEqual(@as(?ErrorInfo, null), client.lastError());
}

/// Smallest valid PNG: a 1x1 transparent pixel.
const png_1x1 = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
    "\x00\x00\x00\x0aIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\x0d\x0a\x2d\xb4\x00\x00\x00\x00IEND\xaeB\x60\x82";

test "imageMimeType sniffs the signature before the extension" {
    try testing.expectEqualStrings("image/png", Client.imageMimeType(png_1x1, "photo.jpg"));
    try testing.expectEqualStrings("image/jpeg", Client.imageMimeType("\xFF\xD8\xFF\xE0rest", "image"));
    try testing.expectEqualStrings("image/webp", Client.imageMimeType("RIFF\x00\x00\x00\x00WEBPVP8 ", "image.png"));
    // a RIFF container that is not WebP, and a truncated one
    try testing.expectEqualStrings("application/octet-stream", Client.imageMimeType("RIFF\x00\x00\x00\x00WAVE", "sound"));
    try testing.expectEqualStrings("application/octet-stream", Client.imageMimeType("RIFF", "image"));

    // unknown signature: fall back to the extension, whatever its case
    try testing.expectEqualStrings("image/jpeg", Client.imageMimeType("data", "a.jpg"));
    try testing.expectEqualStrings("image/jpeg", Client.imageMimeType("data", "a.JPEG"));
    try testing.expectEqualStrings("image/png", Client.imageMimeType("data", "dir.d/a.Png"));
    try testing.expectEqualStrings("image/webp", Client.imageMimeType("data", "a.webp"));
    try testing.expectEqualStrings("application/octet-stream", Client.imageMimeType("data", "a.gif"));
    try testing.expectEqualStrings("application/octet-stream", Client.imageMimeType("data", "image"));
    try testing.expectEqualStrings("application/octet-stream", Client.imageMimeType("", ""));
}

test "multipartContentType carries a random boundary" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();
    const io = client.threaded.io();

    var first_buffer: [Client.multipart_content_type_len]u8 = undefined;
    var second_buffer: [Client.multipart_content_type_len]u8 = undefined;
    const first = Client.multipartContentType(io, &first_buffer);
    const second = Client.multipartContentType(io, &second_buffer);

    try testing.expectEqual(Client.multipart_content_type_len, first.len);
    try testing.expect(std.mem.startsWith(u8, first, "multipart/form-data; boundary=serpapi-zig-"));
    for (first["multipart/form-data; boundary=serpapi-zig-".len..]) |c| try testing.expect(std.ascii.isHex(c));
    try testing.expect(!std.mem.eql(u8, first, second));
}

test "writeImageForm sends the image and api_key in the body, not search defaults" {
    var client = try Client.init(testing.allocator, .{
        .api_key = "secret",
        .engine = "google_lens",
        .output = "html",
    });
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(testing.allocator);
    defer body.deinit();
    try client.writeImageForm(&body.writer, "BOUNDARY", png_1x1, "image.png", .{});

    try testing.expectEqualStrings(
        "--BOUNDARY\r\nContent-Disposition: form-data; name=\"api_key\"\r\n\r\nsecret\r\n" ++
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"source\"\r\n\r\nserpapi-zig:" ++ version ++ "\r\n" ++
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"image\"; filename=\"image.png\"\r\n" ++
            "Content-Type: image/png\r\n\r\n" ++ png_1x1 ++ "\r\n--BOUNDARY--\r\n",
        body.written(),
    );
}

test "writeImageForm call parameters override the constructor key" {
    var client = try Client.init(testing.allocator, .{ .api_key = "default" });
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(testing.allocator);
    defer body.deinit();
    try client.writeImageForm(&body.writer, "B", "data", "na\"me\r\n.jpg", .{ .api_key = "override", .retries = 2 });

    try testing.expectEqualStrings(
        "--B\r\nContent-Disposition: form-data; name=\"api_key\"\r\n\r\noverride\r\n" ++
            "--B\r\nContent-Disposition: form-data; name=\"retries\"\r\n\r\n2\r\n" ++
            "--B\r\nContent-Disposition: form-data; name=\"source\"\r\n\r\nserpapi-zig:" ++ version ++ "\r\n" ++
            // quotes and line breaks cannot break out of the header
            "--B\r\nContent-Disposition: form-data; name=\"image\"; filename=\"na%22me%0D%0A.jpg\"\r\n" ++
            "Content-Type: image/jpeg\r\n\r\ndata\r\n--B--\r\n",
        body.written(),
    );
    try testing.expect(std.mem.indexOf(u8, body.written(), "default") == null);
}

test "uploadImageBytes rejects an image over the size limit before sending it" {
    // no api_key and no network: the size check fails first
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    const image = try testing.allocator.alloc(u8, image_max_size + 1);
    defer testing.allocator.free(image);
    @memset(image, 0);

    try testing.expectError(Error.ImageTooLarge, client.uploadImageBytes(image, "image.png", .{}));
    try testing.expectEqualStrings(
        "image is too large: 512001 bytes, the Image API limit is 512000 bytes",
        client.errorMessage().?,
    );
}

test "uploadImage checks the file size before reading it" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();
    const io = client.threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "large.png", .{});
    // a sparse file: the size is there, the bytes never are
    try file.setLength(io, 501 * 1024);
    file.close(io);

    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/large.png", .{tmp.sub_path});
    defer testing.allocator.free(path);
    try testing.expectError(Error.ImageTooLarge, client.uploadImage(path, .{}));
    try testing.expect(std.mem.startsWith(u8, client.errorMessage().?, "image is too large: 513024 bytes"));
}

test "uploadImage reports a missing file" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    try testing.expectError(error.FileNotFound, client.uploadImage("does/not/exist.png", .{}));
}

test "a failed upload does not report the previous request's error" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    // a file error never reaches fetch, which is where a request normally
    // clears the previous failure
    try client.fail(.{ .message = "Invalid API key.", .status = .unauthorized, .url = "https://serpapi.com/search" });
    try testing.expectError(error.FileNotFound, client.uploadImage("does/not/exist.png", .{}));
    try testing.expect(client.lastError() == null);

    // the size check records its own error in place of the previous one
    try client.fail(.{ .message = "Invalid API key.", .status = .unauthorized, .url = "https://serpapi.com/search" });
    const image = try testing.allocator.alloc(u8, image_max_size + 1);
    defer testing.allocator.free(image);
    @memset(image, 0);
    try testing.expectError(Error.ImageTooLarge, client.uploadImageBytes(image, "image.png", .{}));
    try testing.expect(client.lastError().?.status == null);
    try testing.expect(std.mem.startsWith(u8, client.errorMessage().?, "image is too large"));
}

test "readImage loads the whole file" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();
    const io = client.threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "pixel.png", .data = png_1x1 });

    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/pixel.png", .{tmp.sub_path});
    defer testing.allocator.free(path);
    const image = try client.readImage(path);
    defer testing.allocator.free(image);
    try testing.expectEqualSlices(u8, png_1x1, image);
}

test "fetch sends a POST body with its content type" {
    var client = try Client.init(testing.allocator, .{ .timeout = 30 });
    defer client.deinit();
    const io = client.threaded.io();

    const loopback: std.Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var server = try loopback.listen(io, .{});
    defer server.deinit(io);

    const Capture = struct {
        request_line: [64]u8 = undefined,
        request_line_len: usize = 0,
        content_type: [64]u8 = undefined,
        content_type_len: usize = 0,
        body: [64]u8 = undefined,
        body_len: usize = 0,

        fn serve(capture: *@This(), server_ptr: *std.Io.net.Server, server_io: std.Io) !void {
            var stream = try server_ptr.accept(server_io);
            defer stream.close(server_io);
            var read_buffer: [4096]u8 = undefined;
            var reader = stream.reader(server_io, &read_buffer);

            const request_line = std.mem.trimEnd(u8, try reader.interface.takeDelimiterInclusive('\n'), "\r\n");
            @memcpy(capture.request_line[0..request_line.len], request_line);
            capture.request_line_len = request_line.len;
            var content_length: usize = 0;
            while (true) {
                const line = std.mem.trimEnd(u8, try reader.interface.takeDelimiterInclusive('\n'), "\r\n");
                if (line.len == 0) break;
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const value = std.mem.trim(u8, line[colon + 1 ..], " ");
                if (std.ascii.eqlIgnoreCase(line[0..colon], "content-type")) {
                    @memcpy(capture.content_type[0..value.len], value);
                    capture.content_type_len = value.len;
                } else if (std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) {
                    content_length = try std.fmt.parseInt(usize, value, 10);
                }
            }
            try reader.interface.readSliceAll(capture.body[0..content_length]);
            capture.body_len = content_length;

            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(server_io, &write_buffer);
            try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 18\r\nConnection: close\r\n\r\n{\"image_id\":\"abc\"}");
            try writer.interface.flush();
        }
    };
    var capture: Capture = .{};
    var served = try io.concurrent(Capture.serve, .{ &capture, &server, io });
    defer _ = served.cancel(io) catch {};

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/image", .{server.socket.address.getPort()});
    defer testing.allocator.free(url);

    var body: std.Io.Writer.Allocating = .init(testing.allocator);
    defer body.deinit();
    const status = try client.fetch(.{
        .url = url,
        .body = .{ .content_type = "multipart/form-data; boundary=B", .bytes = "--B\r\nfield\r\n--B--\r\n" },
    }, &body.writer);
    try served.await(io);

    try testing.expectEqual(std.http.Status.ok, status);
    try testing.expectEqualStrings("{\"image_id\":\"abc\"}", body.written());
    try testing.expectEqualStrings("POST /image HTTP/1.1", capture.request_line[0..capture.request_line_len]);
    try testing.expectEqualStrings("multipart/form-data; boundary=B", capture.content_type[0..capture.content_type_len]);
    try testing.expectEqualStrings("--B\r\nfield\r\n--B--\r\n", capture.body[0..capture.body_len]);
}

test "decodeJson reports a rejected upload" {
    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    const rejected = try testing.allocator.dupe(u8, "{\"error\":\"Invalid image format. Supported format: jpg, jpeg, png, webp\"}");
    try testing.expectError(Error.SerpApiError, client.decodeJson(std.json.Value, .{ .body = rejected, .status = .bad_request }));
    try testing.expectEqualStrings("Invalid image format. Supported format: jpg, jpeg, png, webp", client.errorMessage().?);

    const accepted = try testing.allocator.dupe(u8, "{\"message\":\"Image uploaded successfully.\",\"image_id\":\"abc\"}");
    var upload = try client.decodeJson(struct { image_id: []const u8 }, .{ .body = accepted, .status = .ok });
    defer upload.deinit();
    try testing.expectEqualStrings("abc", upload.value.image_id);
}

test "image upload helpers clean up on allocation failure" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pixel.png", .data = png_1x1 });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/pixel.png", .{tmp.sub_path});
    defer testing.allocator.free(path);

    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: Allocator, image_path: []const u8) !void {
            var client = try Client.init(allocator, .{ .api_key = "secret" });
            defer client.deinit();

            const image = try client.readImage(image_path);
            defer allocator.free(image);

            var body: std.Io.Writer.Allocating = .init(allocator);
            defer body.deinit();
            client.writeImageForm(&body.writer, "B", image, "pixel.png", .{}) catch return error.OutOfMemory;
        }
    }.run, .{path});
}
