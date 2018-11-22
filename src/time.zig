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
const absoluteToInternal: i64 = @floatToInt(i64, @intToFloat(f64, absoluteZeroYear - internalYear) * 365.2425 * @intToFloat(f64, secondsPerDay));
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
    loc: ?*Loacation,

    fn nsec(self: Time) i32 {
        if (self.wall == 0) {
            return 0;
        }
        return @intCast(i32, self.wall & nsecMask);
    }

    fn sec(self: Time) i64 {
        return self.ext;
    }

    // unixSec returns the time's seconds since Jan 1 1970 (Unix time).
    fn unixSec(self: Time) i64 {
        return self.sec() + internalToUnix;
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

    fn abs(self: Time) u64 {
        const usec = self.unixSec();
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

    pub fn clock(self: Time) Clock {
        return Clock.absClock(self.abs());
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
        if (m <= @enumToInt(Month.January) and m <= @enumToInt(Month.December)) {
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

pub const Loacation = struct {};

pub fn now() Time {
    const bt = timeNow();
    const sec = bt.sec + unixToInternal - minWall;
    return Time{ .wall = @intCast(u64, bt.nsec), .ext = sec + minWall, .loc = null };
}

test "now" {
    var ts = now();
    debug.warn("date {}\n", ts.date());
    debug.warn("week {}\n", ts.weekday());
    debug.warn("isoWeek {}\n", ts.isoWeek());
    debug.warn("clock {}\n", ts.clock());
    debug.warn("maxWall {}\n", maxWall);
    debug.warn("wallToInternal {}\n", wallToInternal);
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
