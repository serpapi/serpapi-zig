//! Zig client for SerpApi.com
//!
//! Scrape results from all major search engines through a fast, easy,
//! and complete API. This module is dependency-free: it only uses the
//! Zig standard library (std.http for HTTPS, std.json for decoding).

const std = @import("std");

pub const client = @import("client.zig");

pub const version = client.version;
pub const Client = client.Client;
pub const Param = client.Param;

test {
    std.testing.refAllDecls(@This());
}
