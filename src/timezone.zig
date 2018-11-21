// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
//
// Copyright 2018 Geofrey Ernest MIT LICENSE
const std = @import("std");
const mem = std.mem;
const warn = std.debug.warn;

pub const Location = struct {
    name: []const u8,
    zone: zoneList,
    tx: zoneTransList,

    // Most lookups will be for the current time.
    // To avoid the binary search through tx, keep a
    // static one-element cache that gives the correct
    // zone for the time when the Location was created.
    // if cacheStart <= t < cacheEnd,
    // lookup can return cacheZone.
    // The units for cacheStart and cacheEnd are seconds
    // since January 1, 1970 UTC, to match the argument
    // to lookup.
    cache_start: i64,
    cache_end: i64,
    cached_zone: *zone,

    arena: std.heap.ArenaAllocator,

    fn init(a: *mem.Allocator, name: []const u8) Location {
        var arena = std.heap.ArenaAllocator.init(a);
        return Location{
            .name = name,
            .zone = zoneList.init(&arena.allocator),
            .tx = zoneTransList.init(&arena.allocator),
        };
    }

    fn deinit(self: Location) void {
        self.arena.deinit();
    }
};

const zone = struct {
    name: []const u8,
    offset: isize,
    is_dst: bool,
};

const zoneList = std.ArrayList(zone);
const zoneTransList = std.ArrayList(zoneTrans);

const zoneTrans = struct {
    when: i64,
    index: usize,
    is_std: bool,
    is_utc: bool,
};

// alpha and omega are the beginning and end of time for zone
// transitions.
const alpha: i64 = -1 << 63;
const omega: i64 = 1 << 63 - 1;

const UTC = utc_location;
var utc_location = &Location.initName("UTC");

const dataIO = struct {
    p: []u8,
    n: usize,

    fn init(p: []u8) dataIO {
        return dataIO{
            .p = p,
            .n = 0,
        };
    }

    fn read(d: *dataIO, p: []u8) usize {
        if (d.n >= d.p.len) {
            // end of stream
            return 0;
        }
        const pos = d.n;
        const offset = pos + p.len;
        while ((d.n < offset) and (d.n < d.p.len)) : (d.n += 1) {
            p[d.n - pos] = d.p[d.n];
        }
        return d.n - pos;
    }

    fn big4(d: *dataIO) !usize {
        var p: [4]u8 = undefined;
        const size = d.read(p[0..]);
        if (size < 4) {
            return error.BadData;
        }
        return @intCast(usize, p[3]) | (@intCast(usize, p[2]) << 8) | (@intCast(usize, p[1]) << 16) | (@intCast(usize, p[0]) << 24);
    }

    // advances the cursor by n. next read will start after skipping the n bytes.
    fn skip(d: *dataIO, n: usize) !void {
        d.n += n;
    }

    fn byte(d: *dataIO) !u8 {
        if (d.n < d.p.len) {
            const u = d.p[d.n];
            d.n += 1;
            return u;
        }
        return error.EOF;
    }
};

fn byteString(x: []u8) []u8 {
    for (x) |v, idx| {
        if (v == 0) {
            return x[0..idx];
        }
    }
    return x;
}

pub fn loadLocationFromTZData(a: *mem.Allocator, name: []const u8, data: []u8) !Location {
    var arena = std.heap.ArenaAllocator.init(a);
    var arena_allocator = &arena.allocator;
    defer arena_allocator.deinit();
    errdefer arena_allocator.deinit();

    var d = &dataIO.init(data);
    var magic: [4]u8 = undefined;
    var size = d.read(magic[0..]);
    if (size != 4) {
        return error.BadData;
    }
    if (!mem.eql(u8, magic, "TZif")) {
        return error.BadData;
    }
    // 1-byte version, then 15 bytes of padding
    var p: [16]u8 = undefined;
    size = d.read(p[0..]);
    if (size != 16 or p[0] != 0 and p[0] != '2' and p[0] != '3') {
        return error.BadData;
    }
    // six big-endian 32-bit integers:
    //  number of UTC/local indicators
    //  number of standard/wall indicators
    //  number of leap seconds
    //  number of transition times
    //  number of local time zones
    //  number of characters of time zone abbrev strings
    const n_value = enum(usize) {
        UTCLocal,
        STDWall,
        Leap,
        Time,
        Zone,
        Char,
    };

    var n: [6]isize = undefined;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const nn = try d.big4();
        n[i] = @intCast(isize, nn);
    }

    // Transition times.
    var tx_times = try arena_allocator.alloc(u8, n[@enumToInt(n_value.Time)] * 4);
    _ = d.read(tx_times);
    var tx_times_data = dataIO.init(tx_times);

    // Time zone indices for transition times.
    var tx_zone = try arena_allocator.alloc(u8, n[@enumToInt(n_value.Time)]);
    _ = d.read(tx_zone);
    var tx_zone_data = dataIO.init(tx_zone);

    // Zone info structures
    var zone_data_value = try arena_allocator.alloc(u8, n[@enumToInt(n_value.Zone)] * 6);
    _ = d.read(zone_data_value);
    var zone_data = dataIO.init(zone_data_value);

    // Time zone abbreviations.
    var abbrev = try arena_allocator.alloc(u8, n[@enumToInt(n_value.Char)]);
    _ = d.read(abbrev);

    // Leap-second time pairs
    d.skip(n[@enumToInt(n_value.Char)] * 8);

    // Whether tx times associated with local time types
    // are specified as standard time or wall time.
    var isstd = try arena_allocator.alloc(u8, n[@enumToInt(n_value.StdWall)]);
    _ = d.read(isstd);

    var isutc = try arena_allocator.alloc(u8, n[@enumToInt(n_value.StdWall)]);
    var size = d.read(isstd);
    if (size == 0) {
        return error.BadData;
    }
    // If version == 2 or 3, the entire file repeats, this time using
    // 8-byte ints for txtimes and leap seconds.
    // We won't need those until 2106.

    var loc = Location.init(a, name);
    errdefer loc.deinit();
    var zalloc = &loc.arena.allocator;

    // Now we can build up a useful data structure.
    // First the zone information.
    //utcoff[4] isdst[1] nameindex[1]
    var i: usize = 0;
    while (i < n[@enumToInt(n_value.Zone)]) : (i += 1) {
        const zn = try zone_data.big4();
        const b = try zone_data.byte();
        var z: zone = undefined;
        z.offset = @intCast(isize, zn);
        z.is_dst = b != 0;

        const b2 = try zone_data.byte();
        if (@intCase(usize, b2) >= abbrev.len) {
            return error.BadData;
        }
        const cn = byteString(abbrev[b2..]);
        // we copy the name and ensure it stay valid throughout location
        // lifetime.
        var znb = try zalloc.alloc(u8, cn.len);
        mem.copy(u8, znb, cn);
        z.name = znb;
        try loc.zone.append(z);
    }
    // Now the transition time info.
    i = 0;
    while (i < n[@enumToInt(n_value.Time)]) : (i += 1) {
        var tx: zoneTrans = undefined;
        const w = try tx_times_data.big4();
        tx.when = @intCast(i64, w);
        if (@intCast(usize, tx_zone[i]) >= loc.zone.len) {
            return error.BadData;
        }
        tx.index = @intCast(usize, tx_zone[i]);
        if (i < isstd.len) {
            tx.is_std = isstd[i] != 0;
        }
        if (i < isutc.len) {
            tx.is_utc = isutc[i] != 0;
        }
    }
    if (loc.tx.len == 0) {
        try loc.tx.append(zoneTrans{
            .when = alpha,
            .index = 0,
            .is_std = false,
            .is_utc = false,
        });
    }
    return loc;
}

// darwin_sources directory to search for timezone files.
const unix_sources = [][]const u8{
    "/usr/share/zoneinfo/",
    "/usr/share/lib/zoneinfo/",
    "/usr/lib/locale/TZ/",
};
