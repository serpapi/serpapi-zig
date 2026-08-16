//! Local dev server for the browser wasm demo.
//!
//! Browsers give wasm no sockets and no TLS, and serpapi.com does not send
//! CORS headers, so a page cannot `fetch()` it directly from a third-party
//! origin. This server sidesteps both problems: it serves the wasm demo's
//! static files and exposes a same-origin `/api/search` endpoint that
//! forwards to serpapi.com using this repository's own `serpapi.Client`.
//! The secret API key lives only here, read from `SERPAPI_KEY`, and is
//! never sent to the browser.
//!
//! Usage: SERPAPI_KEY=secret_api_key zig build serve
//!        then open http://127.0.0.1:8080

const std = @import("std");
const serpapi = @import("serpapi");
const demo_config = @import("demo_config");

const listen_port: u16 = 8080;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const api_key = init.environ_map.get("SERPAPI_KEY") orelse {
        std.debug.print("SERPAPI_KEY environment variable is required\n", .{});
        std.process.exit(1);
    };

    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", listen_port);
    var tcp_server = try address.listen(io, .{ .reuse_address = true });
    defer tcp_server.deinit(io);

    std.debug.print("serpapi wasm demo: http://127.0.0.1:{d}\n", .{listen_port});
    std.debug.print("serving files from: {s}\n", .{demo_config.web_dir});

    while (true) {
        var stream = tcp_server.accept(io) catch |err| {
            std.debug.print("accept failed: {t}\n", .{err});
            continue;
        };
        defer stream.close(io);
        handleConnection(allocator, io, stream, api_key) catch |err| {
            std.debug.print("request failed: {t}\n", .{err});
        };
    }
}

fn handleConnection(allocator: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream, api_key: []const u8) !void {
    var send_buffer: [8192]u8 = undefined;
    var recv_buffer: [8192]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        try route(allocator, io, &request, api_key);
        if (!request.head.keep_alive) return;
    }
}

fn route(allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request, api_key: []const u8) !void {
    const target = request.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;

    if (request.head.method == .GET and std.mem.eql(u8, path, "/api/search")) {
        return proxySearch(allocator, request, target, api_key);
    }
    if (request.head.method != .GET) {
        return request.respond("method not allowed", .{ .status = .method_not_allowed });
    }
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        return serveFile(allocator, io, request, "index.html", "text/html; charset=utf-8");
    }
    if (std.mem.eql(u8, path, "/serpapi_wasm.wasm")) {
        return serveFile(allocator, io, request, "serpapi_wasm.wasm", "application/wasm");
    }
    return request.respond("not found", .{ .status = .not_found });
}

fn serveFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    name: []const u8,
    content_type: []const u8,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, demo_config.web_dir, .{}) catch {
        return request.respond("demo not built: run `zig build wasm` first", .{ .status = .internal_server_error });
    };
    defer dir.close(io);

    const body = dir.readFileAlloc(io, name, allocator, .limited(16 * 1024 * 1024)) catch {
        return request.respond("file not found", .{ .status = .not_found });
    };
    defer allocator.free(body);

    try request.respond(body, .{
        .extra_headers = &.{.{ .name = "content-type", .value = content_type }},
    });
}

/// Forward a query to serpapi.com using this repository's own client,
/// keeping the SerpApi key on the server. `target` is the raw request
/// target, e.g. "/api/search?engine=google&q=coffee".
fn proxySearch(allocator: std.mem.Allocator, request: *std.http.Server.Request, target: []const u8, api_key: []const u8) !void {
    const query = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[i + 1 ..] else "";
    var engine: []const u8 = "google";
    var q: []const u8 = "";

    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const raw_value = pair[eq + 1 ..];
        var decode_buf = std.array_list.Managed(u8).init(allocator);
        defer decode_buf.deinit();
        try percentDecode(&decode_buf, raw_value);
        if (std.mem.eql(u8, key, "engine")) engine = try allocator.dupe(u8, decode_buf.items);
        if (std.mem.eql(u8, key, "q")) q = try allocator.dupe(u8, decode_buf.items);
    }

    var client = try serpapi.Client.init(allocator, .{ .api_key = api_key, .engine = engine });
    defer client.deinit();

    var result = client.search(.{ .q = q }) catch |err| {
        // Re-wrap as a `{"error": "..."}` payload — the same shape
        // serpapi.com itself uses — so the wasm module's `summarize` can
        // render it without a second, error-shaped JSON parser.
        const message = switch (err) {
            serpapi.client.Error.SerpApiError => client.errorMessage() orelse "unknown serpapi.com error",
            else => @errorName(err),
        };
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.print("{f}", .{std.json.fmt(.{ .@"error" = message }, .{})});
        return request.respond(out.writer.buffered(), .{
            .status = .bad_gateway,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    };
    defer result.deinit();
    return respondJson(allocator, request, result.value);
}

fn respondJson(allocator: std.mem.Allocator, request: *std.http.Server.Request, value: anytype) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{std.json.fmt(value, .{})});

    try request.respond(out.writer.buffered(), .{
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

fn percentDecode(out: *std.array_list.Managed(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '%' and i + 2 < text.len) {
            const hi = std.fmt.charToDigit(text[i + 1], 16) catch {
                try out.append(c);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(text[i + 2], 16) catch {
                try out.append(c);
                i += 1;
                continue;
            };
            try out.append(hi << 4 | lo);
            i += 3;
        } else if (c == '+') {
            try out.append(' ');
            i += 1;
        } else {
            try out.append(c);
            i += 1;
        }
    }
}
