# Changelog

## 1.2.0 (unreleased)

### Features

- Image API: `uploadImage` (file path) and `uploadImageBytes` (in-memory
  image), with typed `uploadImageAs` / `uploadImageBytesAs`, upload an image
  to `POST https://serpapi.com/image` as `multipart/form-data` and return
  its `image_id` for engines such as Google Lens. The `api_key` travels in
  the form body, never in the URL; constructor search defaults (`engine`,
  `output`, ...) are not sent. The content type is detected from the image
  signature (JPEG, PNG, WebP), falling back to the file extension.
  Images over 500 KiB (`serpapi.image_max_size`) are rejected with
  `error.ImageTooLarge` before being read or sent
- The out-of-box test (`zig build oobt`) also uploads an image
- `Client.lastError()` returns a `serpapi.ErrorInfo` with the details of the
  last failure, mirroring serpapi-ruby's `SerpApiError`: `message` (as
  `errorMessage()`), the HTTP `status`, the request `url` without the
  `api_key`, and the `search_id` from the error payload
- `Client.format`: printing a client with `{f}` shows its configuration
  with the API key masked, as serpapi-ruby's `inspect` does
  (`abcd****wxyz`, `****` for a key of eight characters or fewer)
- README documents `engine()`, `apiKey()` and `serpapi.version`
- `rake release` runs `lint`, `test`, `itest` and `oobt` before tagging,
  and refuses to start unless it runs from `master` with `SERPAPI_KEY` set
  and an empty `git status --porcelain` (the previous `git diff --quiet`
  missed staged and untracked files)

### Behavior changes

- `errorMessage()` and `lastError()` describe the most recent request only:
  every request clears the previous failure, so they return null after a
  success or a transport error. Previously the last failure lingered, and a
  DNS error after a 404 still reported the 404

### Breaking changes

These ship in a minor release by decision; pin `v1.1.0` to keep the old API.

- The API key is no longer kept in `Client.params`: it moved to its own
  `api_key` field, which `{any}` prints as an address, so dumping the
  client state no longer leaks it. `apiKey()` is unchanged; code that read
  the key from `client.params.items` must call `apiKey()` instead
- `Client.last_error` is now a `?serpapi.ErrorInfo` instead of `?[]u8`;
  `errorMessage()` is unchanged
- `serpapi.Error` gains `ImageTooLarge`: code that switches exhaustively
  over `serpapi.Error` needs a prong for it

## 1.1.0 (2026-09-23)

- Markdown output: `md` (Search API) and `searchArchiveMd` (Search Archive
  API), returning the results as token-efficient Markdown for LLMs and AI
  agents, via the `output=md` format
- `serpapi.Error` is exported from the module root
  (`serpapi.Error.SerpApiError`, previously only `serpapi.client.Error`)
- `serpapi.version` is derived from `build.zig.zon` at build time instead
  of being duplicated in `src/client.zig`, so the tag cut by `rake release`
  and the version reported to serpapi.com cannot drift apart
- Fix: persistent connections are actually reused. `std.http.Client.fetch`
  leaves the terminating chunk of a compressed, chunked response unread,
  so it judged every serpapi.com body unfinished and closed the socket:
  `persistent = true` was silently a no-op and each request paid for a new
  TLS handshake. The client now drives the request itself and drains the
  framing; `zig build bench` goes from ~2.4s to ~0.5-1.0s for 10 searches
  (3-4x), where before persistent and non-persistent were within noise
- Fix: the `timeout` option is enforced. It was accepted and documented
  but never applied, so a stalled connection blocked forever. Each request
  now races a timer on the client's `std.Io.Threaded` pool and is canceled
  when it fires, returning `error.Timeout`; `0` disables the limit
- Browser wasm demo (`demo/wasm`): a `wasm32-freestanding` module for
  request building and JSON parsing, served by a native proxy
  (`zig build serve`) that keeps `SERPAPI_KEY` off the browser
- Flight tracker demo (`demo/flight_tracker`): typed results against the
  Google Flights API, as a standalone downstream project
- Fix: one error rule for every decoder. An `{"error": "..."}` payload is
  `SerpApiError` whatever the HTTP status, for JSON, HTML, and Markdown
  output alike; a non-200 status without such a payload is
  `HttpRequestFailed`. Previously `html` reported error payloads as
  `HttpRequestFailed`, and typed decoding (`searchAs` and friends) could
  surface an error payload as `JsonParseError` or, with all-optional
  fields, as an empty success
- Fix: `html` (and any other raw-body decoder) double-freed its response
  buffer when the backend returned a non-200 status
- Fix: Search Archive ids are percent-encoded in the request path
- CI: jobs are time-boxed, the kcov coverage job is advisory (it could hang
  the runner for six hours), and both demos are built on every push

## 1.0.0 (2026-08-13)

Initial release, ported from [serpapi-ruby](https://github.com/serpapi/serpapi-ruby).

- Search API: `search` (JSON) and `html` (raw HTML) decoders
- Location API: `location`
- Search Archive API: `searchArchive` (JSON) and `searchArchiveHtml` (raw HTML)
- Account API: `account`
- Persistent HTTP connection (keep-alive) enabled by default
- Zero dependency: Zig standard library only (`std.http`, `std.json`)
- Unit tests, live integration tests, out-of-box testing demo, CI workflow
