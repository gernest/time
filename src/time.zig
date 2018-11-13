const std = @import("std");
const builtin = @import("builtin");
const Os = builtin.Os;
const debug = std.debug;

const windows = std.os.windows;
const linux = std.os.linux;
const darwin = std.os.darwin;
const posix = std.os.posix;

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
const absoluteToInternal: i64 = (absoluteZeroYear - internalYear) * 365.2425 * secondsPerDay;
const internalToAbsolute = -absoluteToInternal;

const unixToInternal: i64 = (1969 * 365 + 1969 / 4 - 1969 / 100 + 1969 / 400) * secondsPerDay;
const internalToUnix: i64 = -unixToInternal;

const wallToInternal: i64 = (1884 * 365 + 1884 / 4 - 1884 / 100 + 1884 / 400) * secondsPerDay;
const internalToWall: i64 = -wallToInternal;

const hasMonotonic = 1 << 63;
const maxWall = wallToInternal + (1 << 33 - 1); // year 2157
const minWall = wallToInternal; // year 1885
const nsecMask = 1 << 30 - 1;
const nsecShift = 30;

pub const Time = struct {
    wall: u64,
    ext: i64,
    loc: ?*Loacation,
};

pub const Loacation = struct {};

pub fn now() Time {
    const bt = timeNow();
    const sec = bt.sec + unixToInternal - minWall;
    return Time{ .wall = @intCast(u64, bt.nsec), .ext = sec + minWall, .loc = null };
}

test "now" {
    const ts = now();
    debug.warn("{}\n", ts);
}

const bintime = struct {
    sec: isize,
    nsec: isize,
};

fn timeNow() bintime {
    switch (builtin.os) {
        Os.linux => {
            var ts: posix.timespec = undefined;
            const err = posix.clock_gettime(posix.CLOCK_REALTIME, &ts);
            debug.assert(err == 0);
            return bintime{ .sec = ts.tv_sec, .nsec = ts.tv_nsec };
        },
        Os.macosx, Os.ios => {
            var tv: darwin.timeval = undefined;
            var err = darwin.gettimeofday(&tv, null);
            debug.assert(err == 0);
            return bintime{ .sec = tv.tv_sec, .nsec = tv.tv_usec };
        },
        else => @compileError("Unsupported OS"),
    }
}
