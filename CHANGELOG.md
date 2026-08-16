# Changelog

## Unreleased

- Browser wasm demo (`demo/wasm`): a `wasm32-freestanding` module for
  request building and JSON parsing, served by a native proxy
  (`zig build serve`) that keeps `SERPAPI_KEY` off the browser
- Fix: `html` (and any other raw-body decoder) double-freed its response
  buffer when the backend returned a non-200 status

## 1.0.0 (2026-08-13)

Initial release, ported from [serpapi-ruby](https://github.com/serpapi/serpapi-ruby).

- Search API: `search` (JSON) and `html` (raw HTML) decoders
- Location API: `location`
- Search Archive API: `searchArchive` (JSON) and `searchArchiveHtml` (raw HTML)
- Account API: `account`
- Persistent HTTP connection (keep-alive) enabled by default
- Zero dependency: Zig standard library only (`std.http`, `std.json`)
- Unit tests, live integration tests, out-of-box testing demo, CI workflow
