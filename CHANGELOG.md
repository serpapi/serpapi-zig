# Changelog

## 1.1.0 (2026-09-23)

- Markdown output: `md` (Search API) and `searchArchiveMd` (Search Archive
  API), returning the results as token-efficient Markdown for LLMs and AI
  agents, via the `output=md` format
- `serpapi.Error` is exported from the module root
  (`serpapi.Error.SerpApiError`, previously only `serpapi.client.Error`)
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
