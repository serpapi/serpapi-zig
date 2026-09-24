# Flight tracker demo

A small, **standalone** Zig project that depends on `serpapi` the same way
any downstream user project would — it is not part of the parent
serpapi-zig repo's build. It uses `serpapi.Client.searchAs` against the
[Google Flights API](https://serpapi.com/google-flights-api) to track a
round trip from Austin (`AUS`) to Paris (`CDG`), and prints the best
itineraries: price, total duration, stops, and each flight segment.

```bash
cd demo/flight_tracker
export SERPAPI_KEY=<secret_serpapi_key>
zig build run
```

Override the route or dates with environment variables:

```bash
DEPARTURE_ID=AUS ARRIVAL_ID=CDG \
OUTBOUND_DATE=2026-10-15 RETURN_DATE=2026-10-22 \
SERPAPI_KEY=<secret_serpapi_key> zig build run
```

## Integrating the library

[build.zig.zon](build.zig.zon) and [build.zig](build.zig) show the two
pieces every user project needs:

1. A `serpapi` entry under `.dependencies` in `build.zig.zon`. This demo
   points it at the parent directory with `.path = "../.."` since it lives
   inside the serpapi-zig repo itself — an external project instead runs
   `zig fetch --save 'git+https://github.com/serpapi/serpapi-zig#v1.0.0'`,
   which writes a `url` + `hash` pair there. See the main
   [README's "Installation" section](../../README.md#installation).
2. `b.dependency("serpapi", .{...}).module("serpapi")` in `build.zig`,
   wired into the executable with `addImport`/`imports`.

[main.zig](main.zig) decodes the response into a small typed struct
(`FlightResults`) covering just the fields the demo prints, following the
pattern documented in the main
[README's "Search API — typed results" section](../../README.md#search-api--typed-results).
