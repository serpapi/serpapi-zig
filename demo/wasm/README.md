# Browser wasm demo

Part of the SerpApi client compiled to WebAssembly and running inside a web
page, with a small native server handling the parts a browser cannot.

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

## Using this as a starting point

For a real integration, keep the same shape: the API key and the HTTP call
stay on your backend, and the browser talks to your own endpoint. Replace
`serve.zig` with whatever already serves your application — the wasm module
only assumes that a `GET /api/search?engine=…&q=…` returns SerpApi's JSON
unchanged.
