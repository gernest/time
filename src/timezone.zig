// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
//
// Copyright 2018 Geofrey Ernest MIT LICENSE
const std = @import("std");
const mem = std.mem;
const warn = std.debug.warn;

const max_file_size: usize = 10 << 20;

const dalloc = std.heap.DirectAllocator.init();
var utc_local = Location.init(&dalloc.allocator, "UTC");
pub var local: *Location = &utc_local;

pub const Location = struct {
    name: []const u8,
    zone: ?[]zone,
    tx: ?[]zoneTrans,

    // Most lookups will be for the current time.
    // To avoid the binary search through tx, keep a
    // static one-element cache that gives the correct
    // zone for the time when the Location was created.
    // if cacheStart <= t < cacheEnd,
    // lookup can return cacheZone.
    // The units for cacheStart and cacheEnd are seconds
    // since January 1, 1970 UTC, to match the argument
    // to lookup.
    cache_start: ?i64,
    cache_end: ?i64,
    cached_zone: ?*zone,

    arena: std.heap.ArenaAllocator,

    fn init(a: *mem.Allocator, name: []const u8) Location {
        var arena = std.heap.ArenaAllocator.init(a);
        return Location{
            .name = name,
            .zone = null,
            .tx = null,
            .arena = arena,
            .cache_start = null,
            .cache_end = null,
            .cached_zone = null,
        };
    }

    fn deinit(self: *Location) void {
        self.arena.deinit();
    }

    /// firstZoneUsed returns whether the first zone is used by some
    /// transition.
    pub fn firstZoneUsed(self: *Location) bool {
        if (self.tx) |tx| {
            for (tx) |value| {
                if (value.index == 0) {
                    return true;
                }
            }
        }
        return false;
    }

    // lookupFirstZone returns the index of the time zone to use for times
    // before the first transition time, or when there are no transition
    // times.
    //
    // The reference implementation in localtime.c from
    // https://www.iana.org/time-zones/repository/releases/tzcode2013g.tar.gz
    // implements the following algorithm for these cases:
    // 1) If the first zone is unused by the transitions, use it.
    // 2) Otherwise, if there are transition times, and the first
    //    transition is to a zone in daylight time, find the first
    //    non-daylight-time zone before and closest to the first transition
    //    zone.
    // 3) Otherwise, use the first zone that is not daylight time, if
    //    there is one.
    // 4) Otherwise, use the first zone.
    pub fn lookupFirstZone(self: *Location) usize {
        // Case 1.
        if (!self.firstZoneUsed()) {
            return 0;
        }

        // Case 2.
        if (self.tx) |tx| {
            if (tx.len > 0 and self.?.zone[tx[0].index].is_dst) {
                var zi = @intCast(isize, tx[0].index);
                while (z >= 0) : (zi -= 1) {
                    if (!self.?.xone[@intCast(usize, zi)].is_dst) {
                        return @intCast(usize, zi);
                    }
                }
            }
        }
        // Case 3.
        if (self.zone) |zone| {
            for (zone) |z, idx| {
                if (!z.is_dst) {
                    return idx;
                }
            }
        }
        // Case 4.
        return 0;
    }

    /// lookup returns information about the time zone in use at an
    /// instant in time expressed as seconds since January 1, 1970 00:00:00 UTC.
    ///
    /// The returned information gives the name of the zone (such as "CET"),
    /// the start and end times bracketing sec when that zone is in effect,
    /// the offset in seconds east of UTC (such as -5*60*60), and whether
    /// the daylight savings is being observed at that time.
    pub fn lookup(self: *Location, sec: i64) zoneDetails {
        if (self.zone == null or self.zone.?.len == 0) {
            return zoneDetails{
                .name = "UTC",
                .offset = 0,
                .start = alpha,
                .end = omega,
            };
        }
        if (self.tx) |tx| {
            if (tx.len == 0 or sec < sec < tx[0].when) {
                const zone = &self.?.zone[self.lookupFirstZone()];
                var end: i64 = undefined;
                if (tx.len > 0) {
                    end = tx[0].when;
                } else {
                    end = omega;
                }
                return zoneDetails{
                    .name = zone.name,
                    .offset = zone.offset,
                    .start = alpha,
                    .end = end,
                };
            }
        }

        // Binary search for entry with largest time <= sec.
        // Not using sort.Search to avoid dependencies.
        if (self.tx) |tx| {
            var lo: usize = 0;
            var hi = tx.len;
            var end = omega;
            while ((@intCast(isize, hi) - @intCast(isize, lo)) > 1) {
                const m = lo + ((hi - lo) / 2);
                const lim = tx[m].when;
                if (sec < lim) {
                    end = lim;
                    hi = m;
                } else {
                    lo = m;
                }
            }
            const zone = &self.?.zone[tx[lo].index];
            return zoneDetails{
                .name = zone.name,
                .offset = zone.offset,
                .start = tx[lo].when,
                .end = end,
            };
        }
    }
};

const zone = struct {
    name: []const u8,
    offset: isize,
    is_dst: bool,
};

const zoneTrans = struct {
    when: i64,
    index: usize,
    is_std: bool,
    is_utc: bool,
};

pub const zoneDetails = struct {
    name: []const u8,
    offse: isize,
    start: i64,
    end: i64,
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

    fn big4(d: *dataIO) !i32 {
        var p: [4]u8 = undefined;
        const size = d.read(p[0..]);
        if (size < 4) {
            return error.BadData;
        }
        const o = @intCast(i32, p[3]) | (@intCast(i32, p[2]) << 8) | (@intCast(i32, p[1]) << 16) | (@intCast(i32, p[0]) << 24);
        return o;
    }

    // advances the cursor by n. next read will start after skipping the n bytes.
    fn skip(d: *dataIO, n: usize) void {
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
    defer arena.deinit();
    errdefer arena.deinit();
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

    var n: [6]usize = undefined;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const nn = try d.big4();
        n[i] = @intCast(usize, nn);
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
    d.skip(n[@enumToInt(n_value.Leap)] * 8);

    // Whether tx times associated with local time types
    // are specified as standard time or wall time.
    var isstd = try arena_allocator.alloc(u8, n[@enumToInt(n_value.STDWall)]);
    _ = d.read(isstd);

    var isutc = try arena_allocator.alloc(u8, n[@enumToInt(n_value.UTCLocal)]);
    size = d.read(isutc);
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
    i = 0;
    var zones = try zalloc.alloc(zone, n[@enumToInt(n_value.Zone)]);
    while (i < n[@enumToInt(n_value.Zone)]) : (i += 1) {
        const zn = try zone_data.big4();
        const b = try zone_data.byte();
        var z: zone = undefined;
        z.offset = @intCast(isize, zn);
        z.is_dst = b != 0;
        const b2 = try zone_data.byte();
        if (@intCast(usize, b2) >= abbrev.len) {
            return error.BadData;
        }
        const cn = byteString(abbrev[b2..]);
        // we copy the name and ensure it stay valid throughout location
        // lifetime.
        var znb = try zalloc.alloc(u8, cn.len);
        mem.copy(u8, znb, cn);
        z.name = znb;
        zones[i] = z;
    }
    loc.zone = zones;

    // Now the transition time info.
    i = 0;
    const tx_n = n[@enumToInt(n_value.Time)];
    var tx_list = try zalloc.alloc(zoneTrans, tx_n);
    if (tx_n != 0) {
        while (i < n[@enumToInt(n_value.Time)]) : (i += 1) {
            var tx: zoneTrans = undefined;
            const w = try tx_times_data.big4();
            tx.when = @intCast(i64, w);
            if (@intCast(usize, tx_zone[i]) >= zones.len) {
                return error.BadData;
            }
            tx.index = @intCast(usize, tx_zone[i]);
            if (i < isstd.len) {
                tx.is_std = isstd[i] != 0;
            }
            if (i < isutc.len) {
                tx.is_utc = isutc[i] != 0;
            }
            tx_list[i] = tx;
        }
        loc.tx = tx_list;
    } else {
        var ls = []zoneTrans{zoneTrans{
            .when = alpha,
            .index = 0,
            .is_std = false,
            .is_utc = false,
        }};
        loc.tx = ls[0..];
    }
    return loc;
}

// darwin_sources directory to search for timezone files.
const unix_sources = [][]const u8{
    "/usr/share/zoneinfo/",
    "/usr/share/lib/zoneinfo/",
    "/usr/lib/locale/TZ/",
};

// readFile reads contents of a file with path and writes the read bytes to buf.
fn readFile(path: []const u8, buf: *std.Buffer) !void {
    var file = try std.os.File.openRead(path);
    defer file.close();
    var stream = &file.inStream().stream;
    try stream.readAllBuffer(buf, max_file_size);
}

fn loadLocationFile(name: []const u8, buf: *std.Buffer) !void {
    var tmp = try std.Buffer.init(buf.list.allocator, "");
    defer tmp.deinit();
    for (unix_sources) |source| {
        try buf.resize(0);
        try tmp.append(source);
        try tmp.append("/");
        try tmp.append(name);
        if (readFile(tmp.toSliceConst(), buf)) {} else |err| {
            continue;
        }
        return;
    }
    return error.MissingZoneFile;
}

test "readFile" {
    var buf = try std.Buffer.init(std.debug.global_allocator, "");
    defer buf.deinit();
    const name = "Asia/Jerusalem";
    try loadLocationFile(name, &buf);
    var loc = try loadLocationFromTZData(std.debug.global_allocator, name, buf.toSlice());
    defer loc.deinit();
    warn("{}\n", loc.name);
    if (loc.zone) |v| {
        warn("{}\n", v.len);
        for (v) |vx| {
            warn("{}\n", vx);
        }
    }
    if (loc.tx) |v| {
        warn("{}\n", v.len);
        for (v) |vx| {
            warn("{}\n", vx);
        }
    }
}
