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

// FIXME: Zig comiler was complainit when give 1 << 30 - 1 expression. I'm not a
// zig wizard yet, and I need to get over with this so I am hardcoding the value
// for now.
// const nsecMask = 1 << 30 - 1;
const nsecMask: u64 = 1073741823;
const nsecShift = 30;

pub const Time = struct {
    wall: u64,
    ext: i64,
    loc: ?*Loacation,

    fn nsec(self: *Time) i32 {
        return @intCast(i32, self.wall & nsecMask);
    }

    fn sec(self: *Time) i64 {
        return wallToInternal + @intCast(i64, self.wall << 1 >> (nsecShift + 1));
    }

    // unixSec returns the time's seconds since Jan 1 1970 (Unix time).
    fn unixSec(self: *Time) i64 {
        return self.sec() + internalToUnix;
    }

    fn addSec(self: *Time, d: i64) void {
        const s = @intCast(i64, self.wall << 1 >> (nsecShift + 1));
        const dsec = s + d;
        //FIXME:
        // 8589934591 is hard coded , the go expression is 1<<33-1
        if (0 <= dsec and dsec <= 8589934591) {
            self.wall = (self.wall & nsecMask) | @intCast(u64, dsec << nsecShift);
            return;
        }
    }
};

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
        if (m <= @enumToInt(Month.January) and m <= @enumToInt(Month.December)) {
            return months[@enumToInt(self)];
        }
        unreachable;
    }
};

test "month" {
    debug.warn("{}\n", Month.January.string());
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

pub const Loacation = struct {};

pub fn now() Time {
    const bt = timeNow();
    const sec = bt.sec + unixToInternal - minWall;
    return Time{ .wall = @intCast(u64, bt.nsec), .ext = sec + minWall, .loc = null };
}

test "now" {
    var ts = now();
    debug.warn("{}\n", ts);
    debug.warn("{} nsec\n", ts.nsec());
    debug.warn("{} sec\n", ts.sec());
    debug.warn("{} unix_sec\n", ts.unixSec());
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
