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
    zone: ?[]zone,
    tz: ?zoneTrans,

    fn initName(name: []const u8) Location {
        return Location{
            .name = name,
            .zone = null,
            .tz = null,
        };
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
};

pub fn loadLocationFromTZData(name: []const u8, data: []u8) !void {
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
}
