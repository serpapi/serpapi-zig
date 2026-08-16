# Browser wasm demo

Part of the SerpApi client compiled to WebAssembly and running inside a web
page, with a small native server handling the parts a browser cannot.

It is a demo, not a way to ship the whole `serpapi.Client` to the browser —
see [what it would take to run the whole client in a
browser](#what-it-would-take-to-run-the-whole-client-in-a-browser) for why,
and what would have to change.

```bash
export SERPAPI_KEY=<secret_serpapi_key>
zig build serve
# open http://127.0.0.1:8080
```

Type a query, press **Search**, and the page prints the organic results as a
Markdown list.

## Why there is a server at all

The interesting constraint of this demo is what wasm *cannot* do:

- **Browsers give WebAssembly no sockets and no TLS.** A wasm module cannot
  open an HTTPS connection, so `std.http.Client` — and therefore the whole
  `serpapi.Client` — cannot run inside the page. This is a browser
  sandboxing rule, not a Zig or wasm-format limitation; the same module
  compiled for `wasm32-wasi` under a runtime like wasmtime has no such
  restriction.
- **serpapi.com sends no CORS headers.** Even using the browser's own
  `fetch()`, a page served from another origin is not permitted to read a
  response from serpapi.com.
- **An API key in client-side code is public.** Anything the browser can
  send, a visitor can read out of devtools.

All three point the same way: the HTTP request belongs on a server. So the
demo splits the work rather than pretending the split isn't there.

## How the pieces fit

```
browser                                    server (serve.zig)
┌─────────────────────────────┐            ┌────────────────────────────┐
│ index.html                  │            │ GET /            index.html│
│   │                         │            │ GET /*.wasm      wasm blob │
│   │ 1. write query to wasm  │            │                            │
│   ▼                         │            │ GET /api/search            │
│ serpapi_wasm.wasm           │            │   │ serpapi.Client.search()│
│   buildSearchPath() ────────┼─ 2. fetch ─┼──▶│ + SERPAPI_KEY          │
│                             │            │   ▼                        │
│   summarize()   ◀───────────┼─ 3. JSON ──┼─── serpapi.com             │
│   │                         │            └────────────────────────────┘
│   ▼ 4. render markdown      │
└─────────────────────────────┘
```

| file | target | role |
|---|---|---|
| [serpapi_wasm.zig](serpapi_wasm.zig) | `wasm32-freestanding` | runs in the page: percent-encodes the query into a request path, parses the JSON response into Markdown |
| [serve.zig](serve.zig) | native | serves the static files; proxies `/api/search` to serpapi.com via `serpapi.Client`, holding the API key |
| [index.html](index.html) | — | passes strings across the JS/wasm boundary and calls `fetch()` |

The API key is read from `SERPAPI_KEY` by the server process and is never
sent to the browser. `/api/search` is same-origin, so no CORS headers are
needed from anyone.

## The wasm module's interface

`serpapi_wasm.zig` is built with `-fno-entry -rdynamic`, has **no imports at
all**, and exports its own linear memory. Strings cross the boundary as
`(ptr, len)` pairs into that memory:

| export | signature | purpose |
|---|---|---|
| `alloc` | `(len) -> ptr` | reserve bytes for JS to write into; `0` means failure |
| `dealloc` | `(ptr, len) -> void` | release them again |
| `buildSearchPath` | `(engine, q, out) -> len` | writes `/api/search?engine=…&q=…`, percent-encoded |
| `summarize` | `(json, out) -> len` | writes `- [title](link)` per organic result |

`summarize` also recognises SerpApi's `{"error": "..."}` payload and renders
it as `**Error:** …`, so a failed search reports itself through the same
path as a successful one.

## Building and testing

```bash
zig build wasm    # build only, into zig-out/demo-wasm/
zig build serve   # build, then serve at http://127.0.0.1:8080 (needs SERPAPI_KEY)
zig build test    # includes this module's unit tests
```

The compute logic uses `std.heap.page_allocator`, which resolves to the wasm
bump allocator on wasm targets and to a normal page allocator elsewhere.
Nothing in it is wasm-only, so it is unit tested natively as part of
`zig build test` — no wasm runtime or browser required. Only exercising it
*as* wasm needs `zig build serve`.

## What it would take to run the whole client in a browser

A fair question is why the wasm module only builds URLs and parses JSON,
rather than being the real `serpapi.Client`. The blockers are concrete and
easy to reproduce.

**The full client does not even link for the browser target.**
`serpapi.Client` drives `std.http.Client` through a `std.Io.Threaded`, and
that implementation is built on POSIX:

```
$ zig build-exe -target wasm32-freestanding ... # a program calling client.search()
error: struct 'posix.system__struct_981' has no member named 'getrandom'
    std/Io/Threaded.zig:2064
error: struct 'posix.system__struct_981' has no member named 'IOV_MAX'
    std/posix.zig:90
```

**Under WASI it links, but still cannot connect.** `wasm32-wasi` produces a
working binary, yet its imports contain no socket calls at all — WASI
preview1 has no outbound `sock_connect`, so there is nothing for TLS to run
over:

```
$ zig build-exe -target wasm32-wasi ...   # links fine, 28 host imports
$ # imports: fd_read, fd_write, random_get, poll_oneoff, … and no sockets
```

So four things would have to change:

1. **An `Io` implementation that is not POSIX.** `std.Io` is a vtable
   interface, so a browser-backed one is expressible — it is simply not
   something the standard library ships today.
2. **A byte stream to the host.** This is the hard blocker: browsers expose
   no raw TCP. WebSocket, WebTransport and WebRTC all exist, but each needs
   a cooperating endpoint on the other side, so a page can never speak
   HTTP/1.1 directly to `serpapi.com:443`. The realistic transport is
   `fetch()`, which means the client's own HTTP layer is bypassed and only
   its *logic* (parameter merging, URL building, decoding, error handling)
   runs in wasm.
3. **CORS, which is not ours to fix.** Even over `fetch()`, a page may not
   read a cross-origin response unless the server allows it, and
   serpapi.com sends no `Access-Control-Allow-Origin`. Either SerpApi adds
   it, or a proxy stays in the picture.
4. **Async bridging.** `fetch()` returns a Promise while wasm exports are
   synchronous, so a blocking `client.search()` needs
   [JSPI](https://developer.mozilla.org/en-US/docs/WebAssembly/JavaScript_interface)
   or an Asyncify pass. Without one, the call has to be split in two — build
   the request, let JS fetch, hand the body back — which is exactly the
   shape of this demo.

And one that is a design decision rather than a limitation: an API key
shipped to the browser is readable by anyone who opens devtools. Even with
every blocker above solved, a key-authenticated API belongs behind your own
server.

The achievable version of "run the client in the browser" is therefore
**a pluggable transport**: keep every bit of client logic in wasm and let
the host move the bytes. In this codebase that means routing `Client.get()`
through a transport interface instead of calling `std.http.Client` directly
— a contained change, and worth doing if browser support is ever a goal.
The TLS side would also need a CA bundle compiled in via `@embedFile`,
since `std.crypto.Certificate.Bundle` normally reads the system trust store
off a filesystem that a browser does not have.

## Using this as a starting point

For a real integration, keep the same shape: the API key and the HTTP call
stay on your backend, and the browser talks to your own endpoint. Replace
`serve.zig` with whatever already serves your application — the wasm module
only assumes that a `GET /api/search?engine=…&q=…` returns SerpApi's JSON
unchanged.
