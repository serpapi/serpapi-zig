# SerpApi Zig Library

[![serpapi-zig](https://github.com/serpapi/serpapi-zig/actions/workflows/ci.yml/badge.svg)](https://github.com/serpapi/serpapi-zig/actions/workflows/ci.yml)

> [!WARNING]
> This library is under heavy development and is **not production ready**.
> The API may change without notice between releases.

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

Query parameters are plain anonymous structs — field names are parameter
names; values may be strings, integers, floats, or booleans.

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

    var results = try client.search(.{ .q = "coffee" });
    defer results.deinit();

    std.debug.print("{f}\n", .{std.json.fmt(results.value, .{ .whitespace = .indent_2 })});
}
```

This example runs a search for "coffee" on Google. It returns the results as a
`std.json.Parsed(std.json.Value)` tree. See the
[playground](https://serpapi.com/playground) to generate your own query.

A complete, runnable version of this program lives in
[oobt/demo.zig](oobt/demo.zig) — it prints the title and link of every
organic result. Run it against the live API with `zig build oobt`.

The SerpApi key can be obtained from [serpapi.com/signup](https://serpapi.com/users/sign_up?plan=free).

Environment variables are a secure, safe, and easy way to manage secrets:
set `export SERPAPI_KEY=<secret_serpapi_key>` in your shell, and the example
above reads it with `init.environ_map.get("SERPAPI_KEY")` — never hardcode
the key in source code.

As everywhere in Zig, the caller owns returned resources: results from JSON
APIs are released with `deinit()`, raw HTML slices with `allocator.free()`.
The remaining examples omit the `defer` cleanup lines for brevity.

## Client options

The `serpapi.Client.init` constructor takes an allocator and an anonymous
struct. `timeout` and `persistent` configure the client; every other field
becomes a default query parameter applied to every request:

```zig
var client = try serpapi.Client.init(allocator, .{
    .api_key = api_key,  // read from the SERPAPI_KEY environment variable
    .engine = "google",  // default search engine
    .gl = "us",          // any other field: default query parameter
    .timeout = 30,       // HTTP timeout in seconds [default: 120]
    .persistent = true,  // keep the connection open [default: true]
});
```

All fields are optional. Parameters passed to a method call override the
defaults provided to the constructor. Call `client.deinit()` when the client
is no longer needed; it closes the connection and frees all resources.

## APIs

### Search API

```zig
var results = try client.search(.{
    .q = "coffee",
    .location = "Austin, TX, Texas, United States",
});
const organic = results.value.object.get("organic_results").?.array;
```

doc: [serpapi.com/search-api](https://serpapi.com/search-api)

### Search API — typed results

Following `std.json.parseFromSlice`, every JSON method has an `As` variant
that decodes into your own struct instead of a dynamic tree. Unknown JSON
fields are ignored, so declare only what you need:

```zig
const Answer = struct {
    search_metadata: struct { id: []const u8, status: []const u8 },
};

var results = try client.searchAs(Answer, .{ .q = "coffee" });
std.debug.print("status: {s}\n", .{results.value.search_metadata.status});
```

Also available: `locationAs`, `searchArchiveAs`, and `accountAs`.

### Search API — raw HTML

`html` returns the raw HTML page from the search engine. It is useful for
training AI models, RAG, debugging, or when you need to parse the HTML
yourself.

```zig
const page = try client.html(.{ .q = "coffee" });
```

### Search API — Markdown

`markdown` returns the result rendered as Markdown via the `/md` endpoint.
It is a convenient format to feed straight into an LLM prompt or a RAG
pipeline without an HTML/JSON parsing step.

```zig
const page = try client.markdown(.{ .q = "coffee" });
```

### Location API

```zig
var locations = try client.location(.{ .q = "Austin", .limit = 3 });
```

doc: [serpapi.com/locations-api](https://serpapi.com/locations-api)

### Search Archive API

Retrieve a past search by id — the id comes from
`results.value.object.get("search_metadata").?.object.get("id")`.

```zig
var archived = try client.searchArchive(search_id);

// or as raw HTML:
const page = try client.searchArchiveHtml(search_id);
```

doc: [serpapi.com/search-archive-api](https://serpapi.com/search-archive-api)

### Account API

```zig
var account = try client.account();
```

The api_key provided to the constructor is used; override it with
`client.accountAs(std.json.Value, .{ .api_key = "other key" })`.

doc: [serpapi.com/account-api](https://serpapi.com/account-api)

## Error handling

Methods return a Zig error union. When serpapi.com reports a failure, the
call returns `error.SerpApiError` and the backend message is available from
`client.errorMessage()`:

```zig
const results = client.search(.{}) catch |err| switch (err) {
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

Pass `async = true` to submit a search without blocking on the result, then
fetch it later from the Search Archive API:

```zig
var submitted = try client.search(.{ .q = "coffee", .async = true });
const search_id = submitted.value.object.get("search_metadata").?.object.get("id").?.string;

// ... later: poll until search_metadata.status is "Success"
var results = try client.searchArchive(search_id);
```

## Search at scale

With `persistent = true` (the default), the client keeps the TLS connection
to serpapi.com open between requests, which roughly doubles throughput on
repeated searches (measure it yourself with `zig build bench`):

```zig
for (queries) |query| {
    var results = try client.search(.{ .q = query });
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
zig build cov     # measure code coverage (needs kcov + SERPAPI_KEY)
zig build lint    # check formatting (zig fmt --check)
zig build doc     # generate API documentation under zig-out/docs
```

A `Rakefile` wraps the same steps for anyone used to the other SerpApi
libraries — `rake --tasks` lists them all.

## Cross compilation

Zig cross-compiles without a toolchain to install, so the library builds for
every architecture listed in the
[cross-compilation guide](https://zig.guide/build-system/cross-compilation)
straight from a laptop:

```bash
rake cross           # all six architectures
rake cross:aarch64   # or one at a time
```

| architecture | zig target | verified |
|---|---|---|
| `x86_64` | `x86_64-linux` | ELF 64-bit x86-64 |
| `arm` | `arm-linux` | ELF 32-bit ARM EABI5 |
| `aarch64` | `aarch64-linux` | ELF 64-bit ARM aarch64 |
| `i386` | `x86-linux` | ELF 32-bit Intel 80386 |
| `riscv64` | `riscv64-linux` | ELF 64-bit UCB RISC-V |
| `wasm32` | `wasm32-wasi` | WebAssembly module |

Note that Zig names the 32-bit x86 architecture `x86`, not `i386`.

To *run* those foreign binaries — and the test suite — on a macOS host,
install QEMU and pass `-fqemu`:

```bash
rake install:qemu    # brew install qemu
rake cross:test      # zig build test -Dtarget=<triple> -fqemu
```

## Code coverage

Coverage is measured with [kcov](https://github.com/SimonKagstrom/kcov), which
Zig binaries support out of the box — no instrumentation flags required.

```bash
brew install kcov            # macOS; on Debian/Ubuntu: sudo apt-get install kcov
export SERPAPI_KEY=<secret_serpapi_key>
zig build cov
open zig-out/coverage/merged/kcov-merged/index.html
```

Current state: **90.4% of lines covered** (225 of 249 in `src/client.zig`)
without an API key, since the tests covering `html`, `searchArchive`, and
`account` skip themselves rather than fail. With `SERPAPI_KEY` set — as in
CI, which publishes the figure to every job summary — those paths execute
too and coverage rises accordingly.

The lines that remain uncovered either way are `errdefer` branches that only
execute if the operating system refuses an allocation midway through a
request.

One caveat specific to Zig: a coverage run over the unit tests alone reports
a flattering ~97% while actually exercising far less, because Zig never
generates code for a generic (`anytype`) function that no test instantiates
— so every HTTP method disappears from the denominator instead of counting
as uncovered. `zig build cov` therefore measures the unit and integration
binaries and merges the two reports.

## License

MIT License — see [LICENSE](LICENSE).
