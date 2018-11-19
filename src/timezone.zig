const std = @import("std");
const mem = std.mem;

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

fn readB4(stream: var) !usize {
    var p: [4]u8 = undefined;
    const size = try stream.read(p[0..]);
    if (size < 4) {
        return error.EOS;
    }
    return @intCast(usize, p[3]) | (@intCast(usize, p[2]) << 8) | (@intCast(usize, p[1]) << 16) | (@intCast(usize, p[0]) << 24);
}

pub fn loadLocationFromTZData(name: []const u8, in_stream: var) !void {
    var magic: [4]u8 = undefined;
    var size = try in_stream.read(magic[0..]);
    if (size != 4) {
        return error.BadData;
    }
    if (!mem.eql(u8, magic, "TZif")) {
        return error.BadData;
    }
    // 1-byte version, then 15 bytes of padding
    var p: [16]u8 = undefined;
    size = try in_stream.read(p[0..]);
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
