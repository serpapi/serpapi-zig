//! Browser-side compute for the SerpApi wasm demo.
//!
//! This module runs as WebAssembly inside the page (see index.html). It has
//! no access to sockets or TLS — browsers do not let wasm open network
//! connections directly, so the SerpApi client's `std.http.Client` cannot
//! run here. Instead this module does the two things that are pure
//! computation and safe to ship to a browser:
//!
//!  1. `buildSearchPath` percent-encodes the search query into a path the
//!     page can `fetch()` (its own same-origin `/api/search` proxy, not
//!     serpapi.com directly — see serve.zig for why).
//!  2. `summarize` parses the JSON response `fetch()` receives and renders
//!     the organic results as a short Markdown-like list.
//!
//! The actual HTTP request to serpapi.com, and the secret API key, stay on
//! the server in serve.zig, built with the same zero-dependency serpapi
//! client used everywhere else in this repository.

const std = @import("std");

// `page_allocator` resolves to the wasm bump allocator when the target
// architecture is wasm, and to a normal page allocator otherwise — which
// keeps the tests below runnable with a plain native `zig test`.
const allocator = std.heap.page_allocator;

/// Allocate `len` bytes in wasm linear memory; the JS host writes strings
/// here before calling the exported functions below. Returns 0 on failure.
export fn alloc(len: usize) usize {
    const mem = allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(mem.ptr);
}

/// Free memory previously returned by `alloc`.
export fn dealloc(ptr: usize, len: usize) void {
    const slice: []u8 = @as([*]u8, @ptrFromInt(ptr))[0..len];
    allocator.free(slice);
}

fn isUrlSafe(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// Build `/api/search?engine=<engine>&q=<q>` into `out[0..out_len]`,
/// percent-encoding both values. Returns the number of bytes written, or 0
/// if the output buffer is too small.
export fn buildSearchPath(
    engine_ptr: usize,
    engine_len: usize,
    q_ptr: usize,
    q_len: usize,
    out_ptr: usize,
    out_len: usize,
) usize {
    const engine: []const u8 = @as([*]const u8, @ptrFromInt(engine_ptr))[0..engine_len];
    const q: []const u8 = @as([*]const u8, @ptrFromInt(q_ptr))[0..q_len];
    const out: []u8 = @as([*]u8, @ptrFromInt(out_ptr))[0..out_len];

    var w: std.Io.Writer = .fixed(out);
    w.writeAll("/api/search?engine=") catch return 0;
    std.Uri.Component.percentEncode(&w, engine, isUrlSafe) catch return 0;
    w.writeAll("&q=") catch return 0;
    std.Uri.Component.percentEncode(&w, q, isUrlSafe) catch return 0;
    return w.end;
}

/// Parse a SerpApi JSON response and render its organic results as
/// Markdown into `out[0..out_len]`: `- [title](link)` per line. Returns the
/// number of bytes written, or 0 on parse failure or if the buffer is too
/// small for even one line.
export fn summarize(json_ptr: usize, json_len: usize, out_ptr: usize, out_len: usize) usize {
    const json: []const u8 = @as([*]const u8, @ptrFromInt(json_ptr))[0..json_len];
    const out: []u8 = @as([*]u8, @ptrFromInt(out_ptr))[0..out_len];

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return 0;
    defer parsed.deinit();

    if (parsed.value != .object) return 0;
    if (parsed.value.object.get("error")) |err_value| {
        if (err_value == .string) {
            var w: std.Io.Writer = .fixed(out);
            w.print("**Error:** {s}\n", .{err_value.string}) catch {};
            return w.end;
        }
    }

    const organic = parsed.value.object.get("organic_results") orelse return 0;
    if (organic != .array) return 0;

    var w: std.Io.Writer = .fixed(out);
    for (organic.array.items) |item| {
        if (item != .object) continue;
        const title = item.object.get("title") orelse continue;
        const link = item.object.get("link") orelse continue;
        if (title != .string or link != .string) continue;
        w.print("- [{s}]({s})\n", .{ title.string, link.string }) catch break;
    }
    return w.end;
}

test "buildSearchPath percent-encodes query" {
    var out: [256]u8 = undefined;
    const engine = "google";
    const q = "fresh coffee & tea";
    const len = buildSearchPath(
        @intFromPtr(engine.ptr),
        engine.len,
        @intFromPtr(q.ptr),
        q.len,
        @intFromPtr(&out),
        out.len,
    );
    try std.testing.expectEqualStrings(
        "/api/search?engine=google&q=fresh%20coffee%20%26%20tea",
        out[0..len],
    );
}

test "summarize renders organic results as markdown" {
    const json =
        \\{"organic_results":[
        \\  {"title":"Coffee - Wikipedia","link":"https://en.wikipedia.org/wiki/Coffee"},
        \\  {"title":"Best coffee shops","link":"https://example.com/coffee"}
        \\]}
    ;
    var out: [512]u8 = undefined;
    const len = summarize(@intFromPtr(json.ptr), json.len, @intFromPtr(&out), out.len);
    try std.testing.expectEqualStrings(
        "- [Coffee - Wikipedia](https://en.wikipedia.org/wiki/Coffee)\n" ++
            "- [Best coffee shops](https://example.com/coffee)\n",
        out[0..len],
    );
}

test "summarize surfaces the backend error field" {
    const json = "{\"error\":\"Missing query `q` parameter.\"}";
    var out: [256]u8 = undefined;
    const len = summarize(@intFromPtr(json.ptr), json.len, @intFromPtr(&out), out.len);
    try std.testing.expectEqualStrings("**Error:** Missing query `q` parameter.\n", out[0..len]);
}
