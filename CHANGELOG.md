# Changelog

## Unreleased

- Search API: `markdown` decoder via the `/md` endpoint

## 1.0.0 (2026-08-13)

Initial release, ported from [serpapi-ruby](https://github.com/serpapi/serpapi-ruby).

- Search API: `search` (JSON) and `html` (raw HTML) decoders
- Location API: `location`
- Search Archive API: `searchArchive` (JSON) and `searchArchiveHtml` (raw HTML)
- Account API: `account`
- Persistent HTTP connection (keep-alive) enabled by default
- Zero dependency: Zig standard library only (`std.http`, `std.json`)
- Unit tests, live integration tests, out-of-box testing demo, CI workflow
