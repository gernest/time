const std = @import("std");
const mem = std.mem;
const warn = std.debug.warn;

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

const chuckResult = struct {
    prefix: []const u8,
    suffix: []const u8,
    chunk: chunk,
};
const std0x = []chunk{
    chunk.stdZeroMonth,
    chunk.stdZeroDay,
    chunk.stdZeroHour12,
    chunk.stdZeroMinute,
    chunk.stdZeroSecond,
    chunk.stdYear,
};

fn nextStdChunk(layout: []const u8) chuckResult {
    var i: usize = 0;
    while (i < layout.len) : (i += 1) {
        switch (layout[i]) {
            'J' => { // January, Jan
                if ((layout.len >= i + 3) and mem.eql(u8, layout[i .. i + 3], "Jan")) {
                    if ((layout.len >= i + 7) and mem.eql(u8, layout[i .. i + 7], "January")) {
                        return chuckResult{
                            .prefix = layout[0..i],
                            .chunk = chunk.stdLongMonth,
                            .suffix = layout[i + 7 ..],
                        };
                    }
                    if (!startsWithLowerCase(layout[i + 3 ..])) {
                        return chuckResult{
                            .prefix = layout[0..i],
                            .chunk = chunk.stdMonth,
                            .suffix = layout[i + 3 ..],
                        };
                    }
                }
            },
            'M' => { // Monday, Mon, MST
                if (layout.len >= 1 + 3) {
                    if (mem.eql(u8, layout[i .. i + 3], "Mon")) {
                        if ((layout.len >= i + 6) and mem.eql(u8, layout[i .. i + 6], "Monday")) {
                            return chuckResult{
                                .prefix = layout[0..i],
                                .chunk = chunk.stdLongWeekDay,
                                .suffix = layout[i + 6 ..],
                            };
                        }
                        if (!startsWithLowerCase(layout[i + 3 ..])) {
                            return chuckResult{
                                .prefix = layout[0..i],
                                .chunk = chunk.stdWeekDay,
                                .suffix = layout[i + 3 ..],
                            };
                        }
                    }
                    if (mem.eql(u8, layout[i .. i + 3], "MST")) {
                        return chuckResult{
                            .prefix = layout[0..i],
                            .chunk = chunk.stdTZ,
                            .suffix = layout[i + 3 ..],
                        };
                    }
                }
            },
            '0' => {
                if (layout.len >= i + 2 and '1' <= layout[i + 1] and layout[i + 1] <= '6') {
                    const x = layout[i + 1] - '1';
                    return chuckResult{
                        .prefix = layout[0..i],
                        .chunk = std0x[x],
                        .suffix = layout[i + 2 ..],
                    };
                }
            },
            '1' => { // 15, 1
                if (layout.len >= i + 2 and layout[i + 1] == '5') {
                    return chuckResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdHour,
                        .suffix = layout[i + 2 ..],
                    };
                }
                return chuckResult{
                    .prefix = layout[0..i],
                    .chunk = chunk.stdNumMonth,
                    .suffix = layout[i + 1 ..],
                };
            },
            '2' => { // 2006, 2
                if (layout.len >= i + 4 and mem.eql(u8, layout[i .. i + 4], "2006")) {
                    return chuckResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdLongYear,
                        .suffix = layout[i + 4 ..],
                    };
                }
                return chuckResult{
                    .prefix = layout[0..i],
                    .chunk = chunk.stdDay,
                    .suffix = layout[i + 1 ..],
                };
            },
            '_' => { // _2, _2006
                if (layout.len >= i + 4 and layout[i + 1] == '2') {
                    //_2006 is really a literal _, followed by stdLongYear
                    if (layout.len >= i + 5 and mem.eql(u8, layout[i + 1 .. i + 5], "2006")) {
                        return chuckResult{
                            .prefix = layout[0..i],
                            .chunk = chunk.stdLongYear,
                            .suffix = layout[i + 5 ..],
                        };
                    }
                    return chuckResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdUnderDay,
                        .suffix = layout[i + 2 ..],
                    };
                }
            },
            '3' => {
                return chuckResult{
                    .prefix = layout[0..i],
                    .chunk = chunk.stdHour12,
                    .suffix = layout[i + 1 ..],
                };
            },
            '4' => {
                return chuckResult{
                    .prefix = layout[0..i],
                    .chunk = chunk.stdSecond,
                    .suffix = layout[i + 1 ..],
                };
            },
            'P' => { // PM
                if (layout.len >= i + 2 and layout[i + 1] == 'M') {
                    return chuckResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdPM,
                        .suffix = layout[i + 2 ..],
                    };
                }
            },
            'p' => { // pm
                if (layout.len >= i + 2 and layout[i + 1] == 'm') {
                    return chuckResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdpm,
                        .suffix = layout[i + 2 ..],
                    };
                }
            },
            '-' => {
                if (layout.len >= i + 7 and mem.eql(u8, layout[i .. i + 7], "-070000")) {
                    return chuckResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdNumSecondsTz,
                        .suffix = layout[i + 7 ..],
                    };
                }
                if (layout.len >= i + 9 and mem.eql(u8, layout[i .. i + 9], "-07:00:00")) {
                    return chuckResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdNumColonSecondsTZ,
                        .suffix = layout[i + 9 ..],
                    };
                }
                if (layout.len >= i + 5 and mem.eql(u8, layout[i .. i + 5], "-0700")) {
                    return chuckResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdNumTZ,
                        .suffix = layout[i + 5 ..],
                    };
                }
                if (layout.len >= i + 6 and mem.eql(u8, layout[i .. i + 6], "-07:00")) {
                    return chuckResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdNumColonTZ,
                        .suffix = layout[i + 6 ..],
                    };
                }
                if (layout.len >= i + 3 and mem.eql(u8, layout[i .. i + 3], "-07")) {
                    return chuckResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdNumShortTZ,
                        .suffix = layout[i + 3 ..],
                    };
                }
            },
            'Z' => { // Z070000, Z07:00:00, Z0700, Z07:00,
                if (layout.len >= i + 7 and mem.eql(u8, layout[i .. i + 7], "Z070000")) {
                    return chuckResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdISO8601SecondsTZ,
                        .suffix = layout[i + 7 ..],
                    };
                }
                if (layout.len >= i + 9 and mem.eql(u8, layout[i .. i + 9], "Z07:00:00")) {
                    return chuckResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdISO8601ColonSecondsTZ,
                        .suffix = layout[i + 9 ..],
                    };
                }
                if (layout.len >= i + 5 and mem.eql(u8, layout[i .. i + 5], "Z0700")) {
                    return chuckResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdISO8601TZ,
                        .suffix = layout[i + 5 ..],
                    };
                }
                if (layout.len >= i + 6 and mem.eql(u8, layout[i .. i + 6], "Z07:00")) {
                    return chuckResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdISO8601ColonTZ,
                        .suffix = layout[i + 6 ..],
                    };
                }
                if (layout.len >= i + 3 and mem.eql(u8, layout[i .. i + 3], "Z07")) {
                    return chuckResult{
                        .prefix = layout[0..i],
                        .chunk = chunk.stdISO8601ShortTZ,
                        .suffix = layout[i + 6 ..],
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
                        return chuckResult{
                            .prefix = layout[0..i],
                            .chunk = st,
                            .suffix = layout[j..],
                        };
                    }
                }
            },
            else => {},
        }
    }

    return chuckResult{
        .prefix = layout,
        .chunk = chunk.none,
        .suffix = "",
    };
}

fn isDigit(s: []const u8, i: usize) bool {
    if (s.len <= i) {
        return false;
    }
    const c = s[i];
    return '0' <= c and c <= '9';
}

test "chunk" {
    const rs = nextStdChunk("02 yeah");
    warn("{}\n", rs);
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
