// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
//
// Copyright 2018 Geofrey Ernest MIT LICENSE

const std = @import("std");
const mem = std.mem;
const builtin = @import("builtin");
const timezone = @import("zig");
const Os = builtin.Os;
const warn = std.debug.warn;

const windows = std.os.windows;
const linux = std.os.linux;
const darwin = std.os.darwin;
const posix = std.os.posix;

// -----------
// Timezone
// -----------
const max_file_size: usize = 10 << 20;
var dalloc = std.heap.DirectAllocator.init();
pub var utc_local = Location.init(&dalloc.allocator, "UTC");

pub fn getLocal() Location {
    return initLocation();
}

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
    pub fn firstZoneUsed(self: *const Location) bool {
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
    pub fn lookupFirstZone(self: *const Location) usize {
        // Case 1.
        if (!self.firstZoneUsed()) {
            return 0;
        }

        // Case 2.
        if (self.tx) |tx| {
            if (tx.len > 0 and self.zone.?[tx[0].index].is_dst) {
                var zi = @intCast(isize, tx[0].index);
                while (zi >= 0) : (zi -= 1) {
                    if (!self.zone.?[@intCast(usize, zi)].is_dst) {
                        return @intCast(usize, zi);
                    }
                }
            }
        }
        // Case 3.
        if (self.zone) |tzone| {
            for (tzone) |z, idx| {
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
    pub fn lookup(self: *const Location, sec: i64) zoneDetails {
        if (self.zone == null) {
            return zoneDetails{
                .name = "UTC",
                .offset = 0,
                .start = alpha,
                .end = omega,
            };
        }
        if (self.tx) |tx| {
            if (tx.len == 0 or sec < tx[0].when) {
                const tzone = &self.zone.?[self.lookupFirstZone()];
                var end: i64 = undefined;
                if (tx.len > 0) {
                    end = tx[0].when;
                } else {
                    end = omega;
                }
                return zoneDetails{
                    .name = tzone.name,
                    .offset = tzone.offset,
                    .start = alpha,
                    .end = end,
                };
            }
        }

        // Binary search for entry with largest time <= sec.
        // Not using sort.Search to avoid dependencies.
        var lo: usize = 0;
        var hi = self.tx.?.len;
        var end = omega;
        while ((hi - lo) > 1) {
            const m = lo + ((hi - lo) / 2);
            const lim = self.tx.?[m].when;
            if (sec < lim) {
                end = lim;
                hi = m;
            } else {
                lo = m;
            }
        }
        const tzone = &self.zone.?[self.tx.?[lo].index];
        return zoneDetails{
            .name = tzone.name,
            .offset = tzone.offset,
            .start = self.tx.?[lo].when,
            .end = end,
        };
    }

    /// lookupName returns information about the time zone with
    /// the given name (such as "EST") at the given pseudo-Unix time
    /// (what the given time of day would be in UTC).
    pub fn lookupName(self: *Location, name: []const u8, unix: i64) !isize {
        // First try for a zone with the right name that was actually
        // in effect at the given time. (In Sydney, Australia, both standard
        // and daylight-savings time are abbreviated "EST". Using the
        // offset helps us pick the right one for the given time.
        // It's not perfect: during the backward transition we might pick
        // either one.)
        if (self.zone) |zone| {
            for (zone) |*z| {
                if (mem.eql(u8, z.name, name)) {
                    const d = self.lookup(unix - @intCast(i64, z.offset));
                    if (mem.eql(d.name, z.name)) {
                        return d.offset;
                    }
                }
            }
        }

        // Otherwise fall back to an ordinary name match.
        if (self.zone) |zone| {
            for (zone) |*z| {
                if (mem.eql(u8, z.name, name)) {
                    return z.offset;
                }
            }
        }
        return error.ZoneNotFound;
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
    offset: isize,
    start: i64,
    end: i64,
};

// alpha and omega are the beginning and end of time for zone
// transitions.
const alpha: i64 = -1 << 63;
const omega: i64 = 1 << 63 - 1;

const initLocation = switch (builtin.os) {
    Os.linux => initLinux,
    Os.macosx, Os.ios => initDarwin,
    else => @compileError("Unsupported OS"),
};

fn initDarwin() Location {
    return initLinux();
}

fn initLinux() Location {
    var tz: ?[]const u8 = null;
    if (std.os.getEnvMap(&dalloc.allocator)) |value| {
        const env = value;
        defer env.deinit();
        tz = env.get("TZ");
    } else |err| {}
    if (tz) |name| {
        if (name.len != 0 and !mem.eql(u8, name, "UTC")) {
            if (loadLocationFromTZFile(&dalloc.allocator, name, unix_sources[0..])) |tzone| {
                return tzone;
            } else |err| {}
        }
    } else {
        var etc = [][]const u8{"/etc/"};
        if (loadLocationFromTZFile(&dalloc.allocator, "localtime", etc[0..])) |tzone| {
            var zz = tzone;
            zz.name = "local";
            return zz;
        } else |err| {}
    }
    return utc_local;
}

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
var unix_sources = [][]const u8{
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

fn loadLocationFile(name: []const u8, buf: *std.Buffer, sources: [][]const u8) !void {
    var tmp = try std.Buffer.init(buf.list.allocator, "");
    defer tmp.deinit();
    for (sources) |source| {
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

fn loadLocationFromTZFile(a: *mem.Allocator, name: []const u8, sources: [][]const u8) !Location {
    var buf = try std.Buffer.init(a, "");
    defer buf.deinit();
    try loadLocationFile(name, &buf, sources);
    return loadLocationFromTZData(a, name, buf.toSlice());
}

pub fn load(name: []const u8) !Location {
    return loadLocationFromTZFile(&dalloc.allocator, name, unix_sources[0..]);
}

// -----------
// TIME
//-------------
const secondsPerMinute = 60;
const secondsPerHour = 60 * secondsPerMinute;
const secondsPerDay = 24 * secondsPerHour;
const secondsPerWeek = 7 * secondsPerDay;
const daysPer400Years = 365 * 400 + 97;
const daysPer100Years = 365 * 100 + 24;
const daysPer4Years = 365 * 4 + 1;
// The unsigned zero year for internal calculations.
// Must be 1 mod 400, and times before it will not compute correctly,
// but otherwise can be changed at will.
const absoluteZeroYear: i64 = -292277022399;

// The year of the zero Time.
// Assumed by the unixToInternal computation below.
const internalYear: i64 = 1;

// Offsets to convert between internal and absolute or Unix times.
const absoluteToInternal: i64 = (absoluteZeroYear - internalYear) * @floatToInt(i64, 365.2425 * @intToFloat(f64, secondsPerDay));
const internalToAbsolute = -absoluteToInternal;

const unixToInternal: i64 = (1969 * 365 + 1969 / 4 - 1969 / 100 + 1969 / 400) * secondsPerDay;
const internalToUnix: i64 = -unixToInternal;

const wallToInternal: i64 = (1884 * 365 + 1884 / 4 - 1884 / 100 + 1884 / 400) * secondsPerDay;
const internalToWall: i64 = -wallToInternal;

const hasMonotonic = 1 << 63;
const maxWall = wallToInternal + ((1 << 33) - 1); // year 2157
const minWall = wallToInternal; // year 1885

const nsecMask: u64 = (1 << 30) - 1;
const nsecShift = 30;

pub const Time = struct {
    wall: u64,
    ext: i64,
    loc: ?Location,

    fn nsec(self: Time) i32 {
        if (self.wall == 0) {
            return 0;
        }
        return @intCast(i32, self.wall & nsecMask);
    }

    fn sec(self: Time) i64 {
        if ((self.wall & hasMonotonic) != 0) {
            return wallToInternal + @intCast(i64, self.wall << 1 >> (nsecShift + 1));
        }
        return self.ext;
    }

    // unixSec returns the time's seconds since Jan 1 1970 (Unix time).
    fn unixSec(self: Time) i64 {
        return self.sec() + internalToUnix;
    }

    pub fn unix(self: Time) i64 {
        return self.unixSec();
    }

    fn addSec(self: *Time, d: i64) void {
        self.ext += d;
    }

    pub fn isZero(self: Time) bool {
        return self.sec() == 0 and self.nsec() == 0;
    }

    pub fn after(self: Time, u: Time) bool {
        const ts = self.sec();
        const us = u.sec();
        return ts > us or (ts == us and self.nsec() > u.nsec());
    }

    pub fn before(self: Time, u: Time) bool {
        return (self.sec() < u.sec()) or (self.sec() == u.sec() and self.nsec() < u.nsec());
    }

    pub fn equal(self: Time, u: Time) bool {
        return self.sec() == u.sec() and self.nsec() == u.nsec();
    }

    /// abs returns the time t as an absolute time, adjusted by the zone offset.
    /// It is called when computing a presentation property like Month or Hour.
    fn abs(self: Time) u64 {
        var usec = self.unixSec();
        if (self.loc) |*value| {
            const d = value.lookup(usec);
            usec += @intCast(i64, d.offset);
        }
        return @intCast(u64, usec + (unixToInternal + internalToAbsolute));
    }

    pub fn date(self: Time) DateDetail {
        return absDate(self.abs(), true);
    }

    pub fn year(self: Time) isize {
        const d = self.date();
        return d.year;
    }

    pub fn month(self: Time) Month {
        const d = self.date();
        return d.month;
    }

    pub fn day(self: Time) isize {
        const d = self.date();
        return d.day;
    }

    pub fn weekday(self: Time) Weekday {
        return absWeekday(self.abs());
    }

    /// isoWeek returns the ISO 8601 year and week number in which self occurs.
    /// Week ranges from 1 to 53. Jan 01 to Jan 03 of year n might belong to
    /// week 52 or 53 of year n-1, and Dec 29 to Dec 31 might belong to week 1
    /// of year n+1.
    pub fn isoWeek(self: Time) ISOWeek {
        var d = self.date();
        const wday = @mod(@intCast(isize, @enumToInt(self.weekday()) + 8), 7);
        const Mon: isize = 0;
        const Tue = Mon + 1;
        const Wed = Tue + 1;
        const Thu = Wed + 1;
        const Fri = Thu + 1;
        const Sat = Fri + 1;
        const Sun = Sat + 1;

        // Calculate week as number of Mondays in year up to
        // and including today, plus 1 because the first week is week 0.
        // Putting the + 1 inside the numerator as a + 7 keeps the
        // numerator from being negative, which would cause it to
        // round incorrectly.
        var week = @divTrunc(d.yday - wday + 7, 7);

        // The week number is now correct under the assumption
        // that the first Monday of the year is in week 1.
        // If Jan 1 is a Tuesday, Wednesday, or Thursday, the first Monday
        // is actually in week 2.
        const jan1wday = @mod((wday - d.yday + 7 * 53), 7);

        if (Tue <= jan1wday and jan1wday <= Thu) {
            week += 1;
        }
        if (week == 0) {
            d.year -= 1;
            week = 52;
        }

        // A year has 53 weeks when Jan 1 or Dec 31 is a Thursday,
        // meaning Jan 1 of the next year is a Friday
        // or it was a leap year and Jan 1 of the next year is a Saturday.
        if (jan1wday == Fri or (jan1wday == Sat) and isLeap(d.year)) {
            week += 1;
        }

        // December 29 to 31 are in week 1 of next year if
        // they are after the last Thursday of the year and
        // December 31 is a Monday, Tuesday, or Wednesday.
        if (@enumToInt(d.month) == @enumToInt(Month.December) and d.day >= 29 and wday < Thu) {
            const dec31wday = @mod((wday + 31 - d.day), 7);
            if (Mon <= dec31wday and dec31wday <= Wed) {
                d.year += 1;
                week = 1;
            }
        }
        return ISOWeek{ .year = d.year, .week = week };
    }

    /// clock returns the hour, minute, and second within the day specified by t.
    pub fn clock(self: Time) Clock {
        return Clock.absClock(self.abs());
    }

    /// hour returns the hour within the day specified by t, in the range [0, 23].
    pub fn hour(self: Time) isize {
        return @divTrunc(@intCast(isize, self.abs() % secondsPerDay), secondsPerHour);
    }

    /// Minute returns the minute offset within the hour specified by t, in the
    /// range [0, 59].
    pub fn minute(self: Time) isize {
        return @divTrunc(@intCast(isize, self.abs() % secondsPerHour), secondsPerMinute);
    }

    /// second returns the second offset within the minute specified by t, in the
    /// range [0, 59].
    pub fn second(self: Time) isize {
        return @intCast(isize, self.abs() % secondsPerMinute);
    }

    /// Nanosecond returns the nanosecond offset within the second specified by t,
    /// in the range [0, 999999999].
    pub fn nanosecond(self: Time) isize {
        return @intCast(isize, self.nsec());
    }

    /// yearDay returns the day of the year specified by t, in the range [1,365] for non-leap years,
    /// and [1,366] in leap years.
    pub fn yearDay(self: Time) isize {
        const d = absDate(self.abs(), false);
        return d.yday + 1;
    }

    /// zone computes the time zone in effect at time t, returning the abbreviated
    /// name of the zone (such as "CET") and its offset in seconds east of UTC.
    pub fn zone(self: Time) ?ZoneDetail {
        if (self.loc) |v| {
            const zn = v.lookup(self.unixSec());
            return ZoneDetail{
                .name = zn.name,
                .offset = zn.offset,
            };
        }
        return null;
    }

    /// utc returns time with the location set to UTC.
    fn utc(self: Time) Time {
        return Time{
            .wall = self.wall,
            .ext = self.ext,
            .loc = utc_local,
        };
    }

    pub fn format(self: Time, out: *std.Buffer, layout: []const u8) !void {
        try out.resize(0);
        var stream = std.io.BufferOutStream.init(out);
        return self.appendFormat(&stream.stream, layout);
    }

    pub fn appendFormat(self: Time, stream: var, layout: []const u8) !void {
        const abs_value = self.abs();
        const tz = self.zone().?;
        const clock_value = self.clock();
        const ddate = self.date();
        var lay = layout;
        while (lay.len != 0) {
            const ctx = nextStdChunk(lay);
            if (ctx.prefix.len != 0) {
                try stream.print("{}", ctx.prefix);
            }
            lay = ctx.suffix;
            switch (ctx.chunk) {
                chunk.none => return,
                chunk.stdYear => {
                    var y = ddate.year;
                    if (y < 0) {
                        y = -y;
                    }
                    try appendInt(stream, @mod(y, 100), 2);
                },
                chunk.stdLongYear => {
                    try appendInt(stream, ddate.year, 4);
                },
                chunk.stdMonth => {
                    try stream.print("{}", ddate.month.string()[0..3]);
                },
                chunk.stdLongMonth => {
                    try stream.print("{}", ddate.month.string());
                },
                chunk.stdNumMonth => {
                    try appendInt(stream, @intCast(isize, @enumToInt(ddate.month) + 1), 0);
                },
                chunk.stdZeroMonth => {
                    try appendInt(stream, @intCast(isize, @enumToInt(ddate.month) + 1), 2);
                },
                chunk.stdWeekDay => {
                    const wk = self.weekday();
                    try stream.print("{}", wk.string()[0..3]);
                },
                chunk.stdLongWeekDay => {
                    const wk = self.weekday();
                    try stream.print("{}", wk.string());
                },
                chunk.stdDay => {
                    try appendInt(stream, ddate.day, 0);
                },
                chunk.stdUnderDay => {
                    if (ddate.day < 10) {
                        try stream.print("{}", " ");
                    }
                    try appendInt(stream, ddate.day, 0);
                },
                chunk.stdZeroDay => {
                    try appendInt(stream, ddate.day, 2);
                },
                chunk.stdHour => {
                    try appendInt(stream, clock_value.hour, 2);
                },
                chunk.stdHour12 => {
                    // Noon is 12PM, midnight is 12AM.
                    var hr = @mod(clock_value.hour, 12);
                    if (hr == 0) {
                        hr = 12;
                    }
                    try appendInt(stream, hr, 0);
                },
                chunk.stdZeroHour12 => {
                    // Noon is 12PM, midnight is 12AM.
                    var hr = @mod(clock_value.hour, 12);
                    if (hr == 0) {
                        hr = 12;
                    }
                    try appendInt(stream, hr, 2);
                },
                chunk.stdMinute => {
                    try appendInt(stream, clock_value.min, 0);
                },
                chunk.stdZeroMinute => {
                    try appendInt(stream, clock_value.min, 2);
                },
                chunk.stdSecond => {
                    try appendInt(stream, clock_value.sec, 0);
                },
                chunk.stdZeroSecond => {
                    try appendInt(stream, clock_value.sec, 2);
                },
                chunk.stdPM => {
                    if (clock_value.hour >= 12) {
                        try stream.print("{}", "PM");
                    } else {
                        try stream.print("{}", "AM");
                    }
                },
                chunk.stdpm => {
                    if (clock_value.hour >= 12) {
                        try stream.print("{}", "pm");
                    } else {
                        try stream.print("{}", "am");
                    }
                },
                chunk.stdISO8601TZ, chunk.stdISO8601ColonTZ, chunk.stdISO8601SecondsTZ, chunk.stdISO8601ShortTZ, chunk.stdISO8601ColonSecondsTZ, chunk.stdNumTZ, chunk.stdNumColonTZ, chunk.stdNumSecondsTz, chunk.stdNumShortTZ, chunk.stdNumColonSecondsTZ => {
                    // Ugly special case. We cheat and take the "Z" variants
                    // to mean "the time zone as formatted for ISO 8601".
                    const cond = tz.offset == 0 and (ctx.chunk.eql(chunk.stdISO8601TZ) or
                        ctx.chunk.eql(chunk.stdISO8601ColonTZ) or
                        ctx.chunk.eql(chunk.stdISO8601SecondsTZ) or
                        ctx.chunk.eql(chunk.stdISO8601ShortTZ) or
                        ctx.chunk.eql(chunk.stdISO8601ColonSecondsTZ));
                    if (cond) {
                        try stream.write("Z");
                    }
                    var z = @divTrunc(tz.offset, 60);
                    var abs_offset = tz.offset;
                    if (z < 0) {
                        try stream.write("-");
                        z = -z;
                        abs_offset = -abs_offset;
                    } else {
                        try stream.write("+");
                    }
                    try appendInt(stream, @divTrunc(z, 60), 2);
                    if (ctx.chunk.eql(chunk.stdISO8601ColonTZ) or
                        ctx.chunk.eql(chunk.stdNumColonTZ) or
                        ctx.chunk.eql(chunk.stdISO8601ColonSecondsTZ) or
                        ctx.chunk.eql(chunk.stdISO8601ColonSecondsTZ) or
                        ctx.chunk.eql(chunk.stdNumColonSecondsTZ))
                    {
                        try stream.write(":");
                    }
                    if (!ctx.chunk.eql(chunk.stdNumShortTZ) and !ctx.chunk.eql(chunk.stdISO8601ShortTZ)) {
                        try appendInt(stream, @mod(z, 60), 2);
                    }
                    if (ctx.chunk.eql(chunk.stdISO8601SecondsTZ) or
                        ctx.chunk.eql(chunk.stdNumSecondsTz) or
                        ctx.chunk.eql(chunk.stdNumColonSecondsTZ) or
                        ctx.chunk.eql(chunk.stdISO8601ColonSecondsTZ))
                    {
                        if (ctx.chunk.eql(chunk.stdNumColonSecondsTZ) or
                            ctx.chunk.eql(chunk.stdISO8601ColonSecondsTZ))
                        {
                            try stream.write(":");
                        }
                        try appendInt(stream, @mod(abs_offset, 60), 2);
                    }
                },
                chunk.stdTZ => {
                    if (tz.name.len != 0) {
                        try stream.print("{}", tz.name);
                        continue;
                    }
                    var z = @divTrunc(tz.offset, 60);
                    if (z < 0) {
                        try stream.write("-");
                        z = -z;
                    } else {
                        try stream.write("+");
                    }
                    try appendInt(stream, @divTrunc(z, 60), 2);
                    try appendInt(stream, @mod(z, 60), 2);
                },
                chunk.stdFracSecond0, chunk.stdFracSecond9 => {
                    try formatNano(stream, @intCast(usize, self.nanosecond()), ctx.args_shift.?, ctx.chunk.eql(chunk.stdFracSecond9));
                },
                else => unreachable,
            }
        }
    }
};

fn appendInt(stream: var, x: isize, width: usize) !void {
    var u = @intCast(usize, x);
    if (x < 0) {
        try stream.write("-");
        u = @intCast(usize, -x);
    }
    var buf: [20]u8 = undefined;
    var i = buf.len;
    while (u > 10) {
        i -= 1;
        const q = @divTrunc(u, 10);
        buf[i] = @intCast(u8, '0' + u - q * 10);
        u = q;
    }
    i -= 1;
    buf[i] = '0' + @intCast(u8, u);
    var w = buf.len - i;
    while (w < width) : (w += 1) {
        try stream.write("0");
    }
    const v = buf[i..];
    try stream.write(v);
}

fn formatNano(stream: var, nanosec: usize, n: usize, trim: bool) !void {
    var u = nanosec;
    var buf = []u8{0} ** 9;
    var start = buf.len;
    while (start > 0) {
        start -= 1;
        buf[start] = @intCast(u8, @mod(u, 10) + '0');
        u /= 10;
    }
    var x = n;
    if (x > 9) {
        x = 9;
    }
    if (trim) {
        while (x > 0 and buf[x - 1] == '0') : (x -= 1) {}
        if (x == 0) {
            return;
        }
    }
    try stream.write(".");
    try stream.write(buf[0..x]);
}

const ZoneDetail = struct {
    name: []const u8,
    offset: isize,
};

pub const Duration = struct {
    value: i64,

    pub const Nanosecond = init(1);
    pub const Microsecond = init(1000 * Nanosecond.value);
    pub const Millisecond = init(1000 * Microsecond.value);
    pub const Second = init(1000 * Millisecond.value);
    pub const Minute = init(60 * Second.value);
    pub const Hour = init(60 * Minute.value);

    pub fn init(v: i64) Duration {
        return Duration{ .value = v };
    }

    const fracRes = struct {
        nw: usize,
        nv: u64,
    };

    // fmtFrac formats the fraction of v/10**prec (e.g., ".12345") into the
    // tail of buf, omitting trailing zeros. It omits the decimal
    // point too when the fraction is 0. It returns the index where the
    // output bytes begin and the value v/10**prec.
    fn fmtFrac(buf: []u8, value: u64, prec: usize) fracRes {
        // Omit trailing zeros up to and including decimal point.
        var w = buf.len;
        var v = value;
        var i: usize = 0;
        var print: bool = false;
        while (i < prec) : (i += 1) {
            const digit = @mod(v, 10);
            print = print or digit != 0;
            if (print) {
                w -= 1;
                buf[w] = @intCast(u8, digit) + '0';
            }
            v /= 10;
        }
        if (print) {
            w -= 1;
            buf[w] = '.';
        }
        return fracRes{ .nw = w, .nv = v };
    }

    fn fmtInt(buf: []u8, value: u64) usize {
        var w = buf.len;
        var v = value;
        if (v == 0) {
            w -= 1;
            buf[w] = '0';
        } else {
            while (v > 0) {
                w -= 1;
                buf[w] = @intCast(u8, @mod(v, 10)) + '0';
                v /= 10;
            }
        }
        return w;
    }

    pub fn string(self: Duration) []const u8 {
        var buf: [32]u8 = undefined;
        var w = buf.len;
        var u = @intCast(u64, self.value);
        const neg = self.value < 0;
        if (neg) {
            u = @intCast(u64, -self.value);
        }
        if (u < @intCast(u64, Second.value)) {
            // Special case: if duration is smaller than a second,
            // use smaller units, like 1.2ms
            var prec: usize = 0;
            w -= 1;
            buf[w] = 's';
            w -= 1;
            if (u == 0) {
                const s = "0s";
                return s[0..];
            } else if (u < @intCast(u64, Microsecond.value)) {
                // print nanoseconds
                prec = 0;
                buf[w] = 'n';
            } else if (u < @intCast(u64, Millisecond.value)) {
                // print microseconds
                prec = 3;
                // U+00B5 'µ' micro sign == 0xC2 0xB5
                w -= 1;
                mem.copy(u8, buf[w..], "µ");
            } else {
                prec = 6;
                buf[w] = 'm';
            }
            const r = fmtFrac(buf[0..w], u, prec);
            w = r.nw;
            u = r.nv;
            w = fmtInt(buf[0..w], u);
        } else {
            w -= 1;
            buf[w] = 's';
            const r = fmtFrac(buf[0..w], u, 9);
            w = r.nw;
            u = r.nv;
            w = fmtInt(buf[0..w], @mod(u, 60));
            u /= 60;
            // u is now integer minutes
            if (u > 0) {
                w -= 1;
                buf[w] = 'm';
                w = fmtInt(buf[0..w], @mod(u, 60));
                u /= 60;
                // u is now integer hours
                // Stop at hours because days can be different lengths.
                if (u > 0) {
                    w -= 1;
                    buf[w] = 'h';
                    w = fmtInt(buf[0..w], u);
                }
            }
        }
        if (neg) {
            w -= 1;
            buf[w] = '-';
        }
        return buf[w..];
    }
};

/// ISO 8601 year and week number
pub const ISOWeek = struct {
    year: isize,
    week: isize,
};

pub const Clock = struct {
    hour: isize,
    min: isize,
    sec: isize,

    fn absClock(abs: u64) Clock {
        var sec = @intCast(isize, abs % secondsPerDay);
        var hour = @divTrunc(sec, secondsPerHour);
        sec -= (hour * secondsPerHour);
        var min = @divTrunc(sec, secondsPerMinute);
        sec -= (min * secondsPerMinute);
        return Clock{ .hour = hour, .min = min, .sec = sec };
    }
};

fn absWeekday(abs: u64) Weekday {
    const s = @mod(abs + @intCast(u64, @enumToInt(Weekday.Monday)) * secondsPerDay, secondsPerWeek);
    const w = s / secondsPerDay;
    return @intToEnum(Weekday, @intCast(usize, w));
}

pub const Month = enum(usize) {
    January,
    February,
    March,
    April,
    May,
    June,
    July,
    August,
    September,
    October,
    November,
    December,

    pub fn string(self: Month) []const u8 {
        const m = @enumToInt(self);
        if (@enumToInt(Month.January) <= m and m <= @enumToInt(Month.December)) {
            return months[m];
        }
        unreachable;
    }
};

pub const DateDetail = struct {
    year: isize,
    month: Month,
    day: isize,
    yday: isize,
};

fn absDate(abs: u64, full: bool) DateDetail {
    var details: DateDetail = undefined;
    // Split into time and day.
    var d = abs / secondsPerDay;

    // Account for 400 year cycles.
    var n = d / daysPer400Years;
    var y = 400 * n;
    d -= daysPer400Years * n;

    // Cut off 100-year cycles.
    // The last cycle has one extra leap year, so on the last day
    // of that year, day / daysPer100Years will be 4 instead of 3.
    // Cut it back down to 3 by subtracting n>>2.
    n = d / daysPer100Years;
    n -= n >> 2;
    y += 100 * n;
    d -= daysPer100Years * n;

    // Cut off 4-year cycles.
    // The last cycle has a missing leap year, which does not
    // affect the computation.
    n = d / daysPer4Years;
    y += 4 * n;
    d -= daysPer4Years * n;

    // Cut off years within a 4-year cycle.
    // The last year is a leap year, so on the last day of that year,
    // day / 365 will be 4 instead of 3. Cut it back down to 3
    // by subtracting n>>2.
    n = d / 365;
    n -= n >> 2;
    y += n;
    d -= 365 * n;
    details.year = @intCast(isize, @intCast(i64, y) + absoluteZeroYear);
    details.yday = @intCast(isize, d);
    if (!full) {
        return details;
    }
    details.day = details.yday;
    if (isLeap(details.year)) {
        if (details.day > (31 + 29 - 1)) {
            // After leap day; pretend it wasn't there.
            details.day -= 1;
        } else if (details.day == (31 + 29 - 1)) {
            // Leap day.
            details.month = Month.February;
            details.day = 29;
            return details;
        }
    }

    // Estimate month on assumption that every month has 31 days.
    // The estimate may be too low by at most one month, so adjust.
    var month = @intCast(usize, details.day) / usize(31);
    const end = daysBefore[month + 1];
    var begin: isize = 0;
    if (details.day >= end) {
        month += 1;
        begin = end;
    } else {
        begin = daysBefore[month];
    }
    details.day = details.day - begin + 1;
    details.month = @intToEnum(Month, month);
    return details;
}

// daysBefore[m] counts the number of days in a non-leap year
// before month m begins. There is an entry for m=12, counting
// the number of days before January of next year (365).
const daysBefore = []isize{
    0,
    31,
    31 + 28,
    31 + 28 + 31,
    31 + 28 + 31 + 30,
    31 + 28 + 31 + 30 + 31,
    31 + 28 + 31 + 30 + 31 + 30,
    31 + 28 + 31 + 30 + 31 + 30 + 31,
    31 + 28 + 31 + 30 + 31 + 30 + 31 + 31,
    31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30,
    31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31,
    31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31 + 30,
    31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31 + 30 + 31,
};
fn isLeap(year: isize) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 100) == 0);
}

const months = [][]const u8{
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
};

pub const Weekday = enum(usize) {
    Sunday,
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,

    pub fn string(self: Weekday) []const u8 {
        const d = @enumToInt(self);
        if (@enumToInt(Weekday.Sunday) <= d and d <= @enumToInt(Weekday.Saturday)) {
            return days[d];
        }
        unreachable;
    }
};

const days = [][]const u8{
    "Sunday",
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
};

/// now returns the current local time. This function is dog slow and expensive,
/// because it will call getLocal() that loads system timezone data
/// every time it is called (no cache).
///
/// Instead store getLocal() value somewhere and pass it to nowWithLoc
/// for faster local time values.
pub fn now() Time {
    const bt = timeNow();
    var local = getLocal();
    return nowWithLoc(local);
}

/// nowWithLoc returns the current local time and assigns the retuned time to use
/// local as location data.
pub fn nowWithLoc(local: Location) Time {
    const bt = timeNow();
    const sec = (bt.sec + unixToInternal) - minWall;
    if ((@intCast(u64, sec) >> 33) != 0) {
        return Time{
            .wall = @intCast(u64, bt.nsec),
            .ext = sec + minWall,
            .loc = local,
        };
    }
    return Time{
        .wall = hasMonotonic | (@intCast(u64, sec) << nsecShift) | @intCast(u64, bt.nsec),
        .ext = @intCast(i64, bt.mono),
        .loc = local,
    };
}

fn unixTime(sec: i64, nsec: i32) Time {
    var local = getLocal();
    return unixTimeWithLoc(sec, nsec, local);
}

fn unixTimeWithLoc(sec: i64, nsec: i32, loc: Location) Time {
    return Time{
        .wall = @intCast(u64, nsec),
        .ext = sec + unixToInternal,
        .loc = loc,
    };
}

pub fn unix(sec: i64, nsec: i64, local: Location) Time {
    var x = sec;
    var y = nsec;
    const exp = @floatToInt(i64, 1e9);
    if (nsec < 0 or nsec >= exp) {
        const n = @divTrunc(nsec, exp);
        x += n;
        y -= (n * exp);
        if (y < 0) {
            y += exp;
            x -= 1;
        }
    }
    return unixTimeWithLoc(x, @intCast(i32, y), local);
}

const bintime = struct {
    sec: isize,
    nsec: isize,
    mono: u64,
};

fn timeNow() bintime {
    switch (builtin.os) {
        Os.linux => {
            var ts: posix.timespec = undefined;
            const err = posix.clock_gettime(posix.CLOCK_REALTIME, &ts);
            std.debug.assert(err == 0);
            return bintime{ .sec = ts.tv_sec, .nsec = ts.tv_nsec, .mono = clockNative() };
        },
        Os.macosx, Os.ios => {
            var tv: darwin.timeval = undefined;
            var err = darwin.gettimeofday(&tv, null);
            std.debug.assert(err == 0);
            return bintime{ .sec = tv.tv_sec, .nsec = tv.tv_usec, .mono = clockNative() };
        },
        else => @compileError("Unsupported OS"),
    }
}

const clockNative = switch (builtin.os) {
    Os.windows => clockWindows,
    Os.linux => clockLinux,
    Os.macosx, Os.ios => clockDarwin,
    else => @compileError("Unsupported OS"),
};

fn clockWindows() u64 {
    var result: i64 = undefined;
    var err = windows.QueryPerformanceCounter(&result);
    debug.assert(err != windows.FALSE);
    return @intCast(u64, result);
}

fn clockDarwin() u64 {
    return darwin.mach_absolute_time();
}

fn clockLinux() u64 {
    var ts: posix.timespec = undefined;
    var result = posix.clock_gettime(monotonic_clock_id, &ts);
    debug.assert(posix.getErrno(result) == 0);
    return @intCast(u64, ts.tv_sec) * u64(1000000000) + @intCast(u64, ts.tv_nsec);
}

// These are predefined layouts for use in Time.Format and time.Parse.
// The reference time used in the layouts is the specific time:
//  Mon Jan 2 15:04:05 MST 2006
// which is Unix time 1136239445. Since MST is GMT-0700,
// the reference time can be thought of as
//  01/02 03:04:05PM '06 -0700
// To define your own format, write down what the reference time would look
// like formatted your way; see the values of constants like ANSIC,
// StampMicro or Kitchen for examples. The model is to demonstrate what the
// reference time looks like so that the Format and Parse methods can apply
// the same transformation to a general time value.
//
// Some valid layouts are invalid time values for time.Parse, due to formats
// such as _ for space padding and Z for zone information.
//
// Within the format string, an underscore _ represents a space that may be
// replaced by a digit if the following number (a day) has two digits; for
// compatibility with fixed-width Unix time formats.
//
// A decimal point followed by one or more zeros represents a fractional
// second, printed to the given number of decimal places. A decimal point
// followed by one or more nines represents a fractional second, printed to
// the given number of decimal places, with trailing zeros removed.
// When parsing (only), the input may contain a fractional second
// field immediately after the seconds field, even if the layout does not
// signify its presence. In that case a decimal point followed by a maximal
// series of digits is parsed as a fractional second.
//
// Numeric time zone offsets format as follows:
//  -0700  ±hhmm
//  -07:00 ±hh:mm
//  -07    ±hh
// Replacing the sign in the format with a Z triggers
// the ISO 8601 behavior of printing Z instead of an
// offset for the UTC zone. Thus:
//  Z0700  Z or ±hhmm
//  Z07:00 Z or ±hh:mm
//  Z07    Z or ±hh
//
// The recognized day of week formats are "Mon" and "Monday".
// The recognized month formats are "Jan" and "January".
//
// Text in the format string that is not recognized as part of the reference
// time is echoed verbatim during Format and expected to appear verbatim
// in the input to Parse.
//
// The executable example for Time.Format demonstrates the working
// of the layout string in detail and is a good reference.
//
// Note that the RFC822, RFC850, and RFC1123 formats should be applied
// only to local times. Applying them to UTC times will use "UTC" as the
// time zone abbreviation, while strictly speaking those RFCs require the
// use of "GMT" in that case.
// In general RFC1123Z should be used instead of RFC1123 for servers
// that insist on that format, and RFC3339 should be preferred for new protocols.
// RFC3339, RFC822, RFC822Z, RFC1123, and RFC1123Z are useful for formatting;
// when used with time.Parse they do not accept all the time formats
// permitted by the RFCs.
// The RFC3339Nano format removes trailing zeros from the seconds field
// and thus may not sort correctly once formatted.
pub const ANSIC = "Mon Jan _2 15:04:05 2006";
pub const UnixDate = "Mon Jan _2 15:04:05 MST 2006";
pub const RubyDate = "Mon Jan 02 15:04:05 -0700 2006";
pub const RFC822 = "02 Jan 06 15:04 MST";
pub const RFC822Z = "02 Jan 06 15:04 -0700"; // RFC822 with numeric zone
pub const RFC850 = "Monday, 02-Jan-06 15:04:05 MST";
pub const RFC1123 = "Mon, 02 Jan 2006 15:04:05 MST";
pub const RFC1123Z = "Mon, 02 Jan 2006 15:04:05 -0700"; // RFC1123 with numeric zone
pub const RFC3339 = "2006-01-02T15:04:05Z07:00";
pub const RFC3339Nano = "2006-01-02T15:04:05.999999999Z07:00";
pub const Kitchen = "3:04PM";
// Handy time stamps.
pub const Stamp = "Jan _2 15:04:05";
pub const StampMilli = "Jan _2 15:04:05.000";
pub const StampMicro = "Jan _2 15:04:05.000000";
pub const StampNano = "Jan _2 15:04:05.000000000";

pub const chunk = enum {
    none,
    stdLongMonth, // "January"
    stdMonth, // "Jan"
    stdNumMonth, // "1"
    stdZeroMonth, // "01"
    stdLongWeekDay, // "Monday"
    stdWeekDay, // "Mon"
    stdDay, // "2"
    stdUnderDay, // "_2"
    stdZeroDay, // "02"
    stdHour, // "15"
    stdHour12, // "3"
    stdZeroHour12, // "03"
    stdMinute, // "4"
    stdZeroMinute, // "04"
    stdSecond, // "5"
    stdZeroSecond, // "05"
    stdLongYear, // "2006"
    stdYear, // "06"
    stdPM, // "PM"
    stdpm, // "pm"
    stdTZ, // "MST"
    stdISO8601TZ, // "Z0700"  // prints Z for UTC
    stdISO8601SecondsTZ, // "Z070000"
    stdISO8601ShortTZ, // "Z07"
    stdISO8601ColonTZ, // "Z07:00" // prints Z for UTC
    stdISO8601ColonSecondsTZ, // "Z07:00:00"
    stdNumTZ, // "-0700"  // always numeric
    stdNumSecondsTz, // "-070000"
    stdNumShortTZ, // "-07"    // always numeric
    stdNumColonTZ, // "-07:00" // always numeric
    stdNumColonSecondsTZ, // "-07:00:00"
    stdFracSecond0, // ".0", ".00", ... , trailing zeros included
    stdFracSecond9, // ".9", ".99", ..., trailing zeros omitted

    stdNeedDate, // need month, day, year
    stdNeedClock, // need hour, minute, second
    stdArgShift, // extra argument in high bits, above low stdArgShift

    fn eql(self: chunk, other: chunk) bool {
        return @enumToInt(self) == @enumToInt(other);
    }
};

// startsWithLowerCase reports whether the string has a lower-case letter at the beginning.
// Its purpose is to prevent matching strings like "Month" when looking for "Mon".
fn startsWithLowerCase(str: []const u8) bool {
    if (str.len == 0) {
        return false;
    }
    const c = str[0];
    return 'a' <= c and c <= 'z';
}

const chunkResult = struct {
    prefix: []const u8,
    suffix: []const u8,
    chunk: chunk,
    args_shift: ?usize,
};
const std0x = []chunk{
    chunk.stdZeroMonth,
    chunk.stdZeroDay,
    chunk.stdZeroHour12,
    chunk.stdZeroMinute,
    chunk.stdZeroSecond,
    chunk.stdYear,
};

fn nextStdChunk(layout: []const u8) chunkResult {
    var i: usize = 0;
    while (i < layout.len) : (i += 1) {
        switch (layout[i]) {
            'J' => { // January, Jan
                if ((layout.len >= i + 3) and mem.eql(u8, layout[i .. i + 3], "Jan")) {
                    if ((layout.len >= i + 7) and mem.eql(u8, layout[i .. i + 7], "January")) {
                        return chunkResult{
                            .prefix = layout[0..i],
                            .chunk = chunk.stdLongMonth,
                            .suffix = layout[i + 7 ..],
                            .args_shift = null,
                        };
                    }
                    if (!startsWithLowerCase(layout[i + 3 ..])) {
                        return chunkResult{
                            .prefix = layout[0..i],
                            .chunk = chunk.stdMonth,
                            .suffix = layout[i + 3 ..],
                            .args_shift = null,
                        };
                    }
                }
            },
            'M' => { // Monday, Mon, MST
                if (layout.len >= 1 + 3) {
                    if (mem.eql(u8, layout[i .. i + 3], "Mon")) {
                        if ((layout.len >= i + 6) and mem.eql(u8, layout[i .. i + 6], "Monday")) {
                            return chunkResult{
                                .prefix = layout[0..i],
                                .chunk = chunk.stdLongWeekDay,
                                .suffix = layout[i + 6 ..],
                                .args_shift = null,
                            };
                        }
                        if (!startsWithLowerCase(layout[i + 3 ..])) {
                            return chunkResult{
                                .prefix = layout[0..i],
                                .chunk = chunk.stdWeekDay,
                                .suffix = layout[i + 3 ..],
                                .args_shift = null,
                            };
                        }
                    }
                    if (mem.eql(u8, layout[i .. i + 3], "MST")) {
                        return chunkResult{
                            .prefix = layout[0..i],
                            .chunk = chunk.stdTZ,
                            .suffix = layout[i + 3 ..],
                            .args_shift = null,
                        };
                    }
                }
            },
            '0' => {
                if (layout.len >= i + 2 and '1' <= layout[i + 1] and layout[i + 1] <= '6') {
                    const x = layout[i + 1] - '1';
                    return chunkResult{
                        .prefix = layout[0..i],
                        .chunk = std0x[x],
                        .suffix = layout[i + 2 ..],
                        .args_shift = null,
                    };
                }
            },
            '1' => { // 15, 1
                if (layout.len >= i + 2 and layout[i + 1] == '5') {
                    return chunkResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdHour,
                        .suffix = layout[i + 2 ..],
                        .args_shift = null,
                    };
                }
                return chunkResult{
                    .prefix = layout[0..i],
                    .chunk = chunk.stdNumMonth,
                    .suffix = layout[i + 1 ..],
                    .args_shift = null,
                };
            },
            '2' => { // 2006, 2
                if (layout.len >= i + 4 and mem.eql(u8, layout[i .. i + 4], "2006")) {
                    return chunkResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdLongYear,
                        .suffix = layout[i + 4 ..],
                        .args_shift = null,
                    };
                }
                return chunkResult{
                    .prefix = layout[0..i],
                    .chunk = chunk.stdDay,
                    .suffix = layout[i + 1 ..],
                    .args_shift = null,
                };
            },
            '_' => { // _2, _2006
                if (layout.len >= i + 4 and layout[i + 1] == '2') {
                    //_2006 is really a literal _, followed by stdLongYear
                    if (layout.len >= i + 5 and mem.eql(u8, layout[i + 1 .. i + 5], "2006")) {
                        return chunkResult{
                            .prefix = layout[0..i],
                            .chunk = chunk.stdLongYear,
                            .suffix = layout[i + 5 ..],
                            .args_shift = null,
                        };
                    }
                    return chunkResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdUnderDay,
                        .suffix = layout[i + 2 ..],
                        .args_shift = null,
                    };
                }
            },
            '3' => {
                return chunkResult{
                    .prefix = layout[0..i],
                    .chunk = chunk.stdHour12,
                    .suffix = layout[i + 1 ..],
                    .args_shift = null,
                };
            },
            '4' => {
                return chunkResult{
                    .prefix = layout[0..i],
                    .chunk = chunk.stdSecond,
                    .suffix = layout[i + 1 ..],
                    .args_shift = null,
                };
            },
            'P' => { // PM
                if (layout.len >= i + 2 and layout[i + 1] == 'M') {
                    return chunkResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdPM,
                        .suffix = layout[i + 2 ..],
                        .args_shift = null,
                    };
                }
            },
            'p' => { // pm
                if (layout.len >= i + 2 and layout[i + 1] == 'm') {
                    return chunkResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdpm,
                        .suffix = layout[i + 2 ..],
                        .args_shift = null,
                    };
                }
            },
            '-' => {
                if (layout.len >= i + 7 and mem.eql(u8, layout[i .. i + 7], "-070000")) {
                    return chunkResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdNumSecondsTz,
                        .suffix = layout[i + 7 ..],
                        .args_shift = null,
                    };
                }
                if (layout.len >= i + 9 and mem.eql(u8, layout[i .. i + 9], "-07:00:00")) {
                    return chunkResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdNumColonSecondsTZ,
                        .suffix = layout[i + 9 ..],
                        .args_shift = null,
                    };
                }
                if (layout.len >= i + 5 and mem.eql(u8, layout[i .. i + 5], "-0700")) {
                    return chunkResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdNumTZ,
                        .suffix = layout[i + 5 ..],
                        .args_shift = null,
                    };
                }
                if (layout.len >= i + 6 and mem.eql(u8, layout[i .. i + 6], "-07:00")) {
                    return chunkResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdNumColonTZ,
                        .suffix = layout[i + 6 ..],
                        .args_shift = null,
                    };
                }
                if (layout.len >= i + 3 and mem.eql(u8, layout[i .. i + 3], "-07")) {
                    return chunkResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdNumShortTZ,
                        .suffix = layout[i + 3 ..],
                        .args_shift = null,
                    };
                }
            },
            'Z' => { // Z070000, Z07:00:00, Z0700, Z07:00,
                if (layout.len >= i + 7 and mem.eql(u8, layout[i .. i + 7], "Z070000")) {
                    return chunkResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdISO8601SecondsTZ,
                        .suffix = layout[i + 7 ..],
                        .args_shift = null,
                    };
                }
                if (layout.len >= i + 9 and mem.eql(u8, layout[i .. i + 9], "Z07:00:00")) {
                    return chunkResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdISO8601ColonSecondsTZ,
                        .suffix = layout[i + 9 ..],
                        .args_shift = null,
                    };
                }
                if (layout.len >= i + 5 and mem.eql(u8, layout[i .. i + 5], "Z0700")) {
                    return chunkResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdISO8601TZ,
                        .suffix = layout[i + 5 ..],
                        .args_shift = null,
                    };
                }
                if (layout.len >= i + 6 and mem.eql(u8, layout[i .. i + 6], "Z07:00")) {
                    return chunkResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdISO8601ColonTZ,
                        .suffix = layout[i + 6 ..],
                        .args_shift = null,
                    };
                }
                if (layout.len >= i + 3 and mem.eql(u8, layout[i .. i + 3], "Z07")) {
                    return chunkResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdISO8601ShortTZ,
                        .suffix = layout[i + 6 ..],
                        .args_shift = null,
                    };
                }
            },
            '.' => { // .000 or .999 - repeated digits for fractional seconds.
                if (i + 1 < layout.len and (layout[i + 1] == '0' or layout[i + 1] == '9')) {
                    const ch = layout[i + 1];
                    var j = i + 1;
                    while (j < layout.len and layout[j] == ch) : (j += 1) {}
                    if (!isDigit(layout, j)) {
                        var st = chunk.stdFracSecond0;
                        if (layout[i + 1] == '9') {
                            st = chunk.stdFracSecond9;
                        }
                        return chunkResult{
                            .prefix = layout[0..i],
                            .chunk = st,
                            .suffix = layout[j..],
                            .args_shift = j - (i + 1),
                        };
                    }
                }
            },
            else => {},
        }
    }

    return chunkResult{
        .prefix = layout,
        .chunk = chunk.none,
        .suffix = "",
        .args_shift = null,
    };
}

fn isDigit(s: []const u8, i: usize) bool {
    if (s.len <= i) {
        return false;
    }
    const c = s[i];
    return '0' <= c and c <= '9';
}

const long_day_names = [][]const u8{
    "Sunday",
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
};

const short_day_names = [][]const u8{
    "Sun",
    "Mon",
    "Tue",
    "Wed",
    "Thu",
    "Fri",
    "Sat",
};

const short_month_names = [][]const u8{
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
};

const long_month_names = [][]const u8{
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
};

// match reports whether s1 and s2 match ignoring case.
// It is assumed s1 and s2 are the same length.
fn match(s1: []const u8, s2: []const u8) bool {
    if (s1.len != s2.len) {
        return false;
    }
    var i: usize = 0;
    while (i < s1.len) : (i += 1) {
        var c1 = s1[i];
        var c2 = s2[i];
        if (c1 != c2) {
            c1 |= ('a' - 'A');
            c2 |= ('a' - 'A');
            if (c1 != c2 or c1 < 'a' or c1 > 'z') {
                return false;
            }
        }
    }
    return true;
}

fn lookup(tab: [][]const u8, val: []const u8) !usize {
    for (tab) |v, i| {
        if (val.len >= v.len and match(val[0..v.len], v)) {
            return i;
        }
    }
    return error.BadValue;
}
