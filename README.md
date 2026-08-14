# SerpApi Zig Library

[![serpapi-zig](https://github.com/serpapi/serpapi-zig/actions/workflows/ci.yml/badge.svg)](https://github.com/serpapi/serpapi-zig/actions/workflows/ci.yml)

Integrate search data into your AI workflow, RAG / fine-tuning, or Zig application using this wrapper for [SerpApi](https://serpapi.com).

SerpApi supports Google, Google Maps, Google Shopping, Baidu, Yandex, Yahoo, eBay, App Stores, and [more](https://serpapi.com).

Query a vast range of data at scale, including web search results, flight schedules, stock market data, news headlines, and [more](https://serpapi.com).

## Features
  * `persistent` → Keep socket connection open to save on SSL handshake / reconnection (2x faster).
  * zero dependency → only the Zig standard library (`std.http`, `std.json`), nothing else to fetch.
  * cross platform → Linux, macOS, and Windows.
  * extensive documentation → easy to follow.

## Installation

Zig 0.16.0 or higher is required.

Add the dependency to your project:

```bash
zig fetch --save git+https://github.com/serpapi/serpapi-zig
```

Then wire the module in your `build.zig`:

```zig
const serpapi = b.dependency("serpapi", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("serpapi", serpapi.module("serpapi"));
```

## Simple Usage

```zig
const std = @import("std");
const serpapi = @import("serpapi");

pub fn main(init: std.process.Init) !void {
    const api_key = init.environ_map.get("SERPAPI_KEY") orelse
        return error.MissingSerpApiKey;

    var client = try serpapi.Client.init(init.gpa, .{
        .engine = "google",
        .api_key = api_key,
    });
    defer client.deinit();

    var results = try client.search(&.{.{ .key = "q", .value = "coffee" }});
    defer results.deinit();

    std.debug.print("{f}\n", .{std.json.fmt(results.value, .{ .whitespace = .indent_2 })});
}
```

This example runs a search for "coffee" on Google. It returns the results as a
`std.json.Parsed(std.json.Value)` tree. See the
[playground](https://serpapi.com/playground) to generate your own query.

The SerpApi key can be obtained from [serpapi.com/signup](https://serpapi.com/users/sign_up?plan=free).

Environment variables are a secure, safe, and easy way to manage secrets:
set `export SERPAPI_KEY=<secret_serpapi_key>` in your shell, and the example
above reads it with `init.environ_map.get("SERPAPI_KEY")` — never hardcode
the key in source code.

## Client options

The `serpapi.Client.init` constructor takes an allocator and an options struct:

```zig
var client = try serpapi.Client.init(allocator, .{
    .api_key = api_key,            // read from the SERPAPI_KEY environment variable
    .engine = "google",            // default search engine
    .timeout = 30,                 // HTTP timeout in seconds [default: 120]
    .persistent = true,            // keep the connection open [default: true]
    .params = &.{                  // extra default parameters
        .{ .key = "gl", .value = "us" },
    },
});
defer client.deinit();
```

All fields are optional. Parameters passed to a method call override the
defaults provided to the constructor. Call `deinit` when the client is no
longer needed; it closes the connection and frees all resources.

## APIs

### Search API

```zig
var results = try client.search(&.{
    .{ .key = "q", .value = "coffee" },
    .{ .key = "location", .value = "Austin, TX, Texas, United States" },
});
defer results.deinit();
const organic = results.value.object.get("organic_results").?.array;
```

doc: [serpapi.com/search-api](https://serpapi.com/search-api)

### Search API — raw HTML

`html` returns the raw HTML page from the search engine. It is useful for
training AI models, RAG, debugging, or when you need to parse the HTML
yourself.

```zig
const page = try client.html(&.{.{ .key = "q", .value = "coffee" }});
defer allocator.free(page);
```

### Location API

```zig
var locations = try client.location(&.{
    .{ .key = "q", .value = "Austin" },
    .{ .key = "limit", .value = "3" },
});
defer locations.deinit();
```

doc: [serpapi.com/locations-api](https://serpapi.com/locations-api)

### Search Archive API

Retrieve a past search by id — the id comes from
`results.value.object.get("search_metadata").?.object.get("id")`.

```zig
var archived = try client.searchArchive(search_id);
defer archived.deinit();

// or as raw HTML:
const page = try client.searchArchiveHtml(search_id);
defer allocator.free(page);
```

doc: [serpapi.com/search-archive-api](https://serpapi.com/search-archive-api)

### Account API

```zig
var account = try client.account(null); // or pass an api_key
defer account.deinit();
```

doc: [serpapi.com/account-api](https://serpapi.com/account-api)

## Error handling

Methods return a Zig error union. When serpapi.com reports a failure, the
call returns `error.SerpApiError` and the backend message is available from
`client.errorMessage()`:

```zig
const results = client.search(&.{}) catch |err| switch (err) {
    error.SerpApiError => {
        std.debug.print("serpapi.com says: {s}\n", .{client.errorMessage().?});
        return err;
    },
    else => return err,
};
```

Other errors: `error.HttpRequestFailed` (non-200 status without an error
payload), `error.JsonParseError` (response was not valid JSON), plus any
network / TLS / allocation errors propagated from the standard library.

## Search asynchronous

Pass `async=true` to submit a search without blocking on the result, then
fetch it later from the Search Archive API:

```zig
var submitted = try client.search(&.{
    .{ .key = "q", .value = "coffee" },
    .{ .key = "async", .value = "true" },
});
defer submitted.deinit();
const search_id = submitted.value.object.get("search_metadata").?.object.get("id").?.string;

// ... later: poll until search_metadata.status is "Success"
var results = try client.searchArchive(search_id);
defer results.deinit();
```

## Search at scale

With `persistent = true` (the default), the client keeps the TLS connection
to serpapi.com open between requests, which roughly doubles throughput on
repeated searches (measure it yourself with `zig build bench`):

```zig
for (queries) |query| {
    var results = try client.search(&.{.{ .key = "q", .value = query }});
    defer results.deinit();
    // process results...
}
```

## Developer workflow

```bash
zig build test    # run unit tests (no network)
zig build itest   # run integration tests against serpapi.com (needs SERPAPI_KEY)
zig build oobt    # out-of-box testing: build + run the demo app (needs SERPAPI_KEY)
zig build bench   # benchmark persistent vs non-persistent connections (needs SERPAPI_KEY)
zig build lint    # check formatting (zig fmt --check)
zig build doc     # generate API documentation under zig-out/docs
```

## License

MIT License — see [LICENSE](LICENSE).
