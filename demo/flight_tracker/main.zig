//! Flight tracker demo application.
//!
//! Runs a real Google Flights search through serpapi.com for a round trip
//! from Austin (AUS) to Paris (CDG) and prints the best itineraries: price,
//! airline, duration, and stops. Usage:
//!
//!   SERPAPI_KEY=secret_api_key zig build flight_tracker
//!
//! Override the route and dates with environment variables:
//!
//!   DEPARTURE_ID=AUS ARRIVAL_ID=CDG OUTBOUND_DATE=2026-10-15 RETURN_DATE=2026-10-22 \
//!     SERPAPI_KEY=secret_api_key zig build flight_tracker

const std = @import("std");
const serpapi = @import("serpapi");

/// Subset of the Google Flights API response we care about.
/// doc: https://serpapi.com/google-flights-api
const FlightResults = struct {
    best_flights: []const Itinerary = &.{},
    other_flights: []const Itinerary = &.{},
};

const Itinerary = struct {
    flights: []const Segment = &.{},
    layovers: []const Layover = &.{},
    total_duration: i64 = 0,
    price: i64 = 0,
    type: []const u8 = "",
};

const Segment = struct {
    departure_airport: Airport,
    arrival_airport: Airport,
    airline: []const u8 = "",
    flight_number: []const u8 = "",
    duration: i64 = 0,
};

const Airport = struct {
    name: []const u8 = "",
    id: []const u8 = "",
    time: []const u8 = "",
};

const Layover = struct {
    name: []const u8 = "",
    id: []const u8 = "",
    duration: i64 = 0,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const env = init.environ_map;

    const key = env.get("SERPAPI_KEY") orelse {
        std.debug.print("SERPAPI_KEY environment variable is required\n", .{});
        std.process.exit(1);
    };

    const departure_id = env.get("DEPARTURE_ID") orelse "AUS";
    const arrival_id = env.get("ARRIVAL_ID") orelse "CDG";
    const outbound_date = env.get("OUTBOUND_DATE") orelse "2026-10-15";
    const return_date = env.get("RETURN_DATE") orelse "2026-10-22";

    var client = try serpapi.Client.init(allocator, .{
        .api_key = key,
        .engine = "google_flights",
    });
    defer client.deinit();

    var result = client.searchAs(FlightResults, .{
        .departure_id = departure_id,
        .arrival_id = arrival_id,
        .outbound_date = outbound_date,
        .return_date = return_date,
        .currency = "USD",
        .hl = "en",
    }) catch |err| {
        std.debug.print("flight search failed: {t} ({s})\n", .{ err, client.errorMessage() orelse "no details" });
        std.process.exit(1);
    };
    defer result.deinit();

    std.debug.print(
        "tracking flights {s} -> {s}, {s} to {s}\n\n",
        .{ departure_id, arrival_id, outbound_date, return_date },
    );

    const itineraries = if (result.value.best_flights.len > 0) result.value.best_flights else result.value.other_flights;
    if (itineraries.len == 0) {
        std.debug.print("no flights found\n", .{});
        return;
    }

    std.debug.print("found {d} itineraries:\n", .{itineraries.len});
    for (itineraries, 0..) |itinerary, i| {
        const stops = if (itinerary.flights.len > 0) itinerary.flights.len - 1 else 0;
        std.debug.print(
            "\n{d}. ${d} — {d}h{d}m total, {d} stop(s)\n",
            .{ i + 1, itinerary.price, @divTrunc(itinerary.total_duration, 60), @mod(itinerary.total_duration, 60), stops },
        );
        for (itinerary.flights) |segment| {
            std.debug.print(
                "   {s} {s}: {s} ({s}) {s} -> {s} ({s}) {s}\n",
                .{
                    segment.airline,
                    segment.flight_number,
                    segment.departure_airport.name,
                    segment.departure_airport.id,
                    segment.departure_airport.time,
                    segment.arrival_airport.name,
                    segment.arrival_airport.id,
                    segment.arrival_airport.time,
                },
            );
        }
    }
    std.debug.print("\nserpapi-zig {s} flight tracker demo: success\n", .{serpapi.version});
}
