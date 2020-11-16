const std = @import("std");
const warn = std.debug.warn;
const time = @import("./src/time.zig");
const Duration = time.Duration;

test "now" {
    var local = time.Location.getLocal();
    var now = time.now(&local);

    warn("\n today's date {}", .{now.date()});
    warn("\n today's time {}", .{now.clock()});
    warn("\n local timezone detail  {}\n", .{now.zone()});

    // $ zig test example.zig
    // Test 1/1 now...
    //  today's date DateDetail{ .year = 2018, .month = Month.November, .day = 25, .yday = 328 }
    //  today's time Clock{ .hour = 11, .min = 17, .sec = 16 }
    //  local timezone detail  ZoneDetail{ .name = EAT, .offset = 10800 }
    // OK
    // All tests passed.
}

const formatTest = struct {
    name: []const u8,
    format: []const u8,
    fn init(name: []const u8, format: []const u8) formatTest {
        return formatTest{ .name = name, .format = format };
    }
};

const format_tests = [_]formatTest{
    formatTest.init("ANSIC", time.ANSIC),
    formatTest.init("UnixDate", time.UnixDate),
    formatTest.init("RubyDate", time.RubyDate),
    formatTest.init("RFC822", time.RFC822),
    formatTest.init("RFC850", time.RFC850),
    formatTest.init("RFC1123", time.RFC1123),
    formatTest.init("RFC1123Z", time.RFC1123Z),
    formatTest.init("RFC3339", time.RFC3339),
    formatTest.init("RFC3339Nano", time.RFC3339Nano),
    formatTest.init("Kitchen", time.Kitchen),
    formatTest.init("am/pm", "3pm"),
    formatTest.init("AM/PM", "3PM"),
    formatTest.init("two-digit year", "06 01 02"),
    // Three-letter months and days must not be followed by lower-case letter.
    formatTest.init("Janet", "Hi Janet, the Month is January"),
    // Time stamps, Fractional seconds.
    formatTest.init("Stamp", time.Stamp),
    formatTest.init("StampMilli", time.StampMilli),
    formatTest.init("StampMicro", time.StampMicro),
    formatTest.init("StampNano", time.StampNano),
};

test "time.format" {
    var local = time.Location.getLocal();
    var ts = time.now(&local);

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    warn("\n", .{});
    for (format_tests) |value| {
        try buf.resize(0);
        try ts.formatBuffer(&buf, value.format);
        warn("{}:  {}\n", .{ value.name, buf.items });
    }

    // Test 2/2 time.format...
    // ANSIC:  Thu Nov 29 05:46:03 2018
    // UnixDate:  Thu Nov 29 05:46:03 EAT 2018
    // RubyDate:  Thu Nov 29 05:46:03 +0300 2018
    // RFC822:  29 Nov 18 05:46 EAT
    // RFC850:  Thursday, 29-Nov-18 05:46:03 EAT
    // RFC1123:  Thu, 29 Nov 2018 05:46:03 EAT
    // RFC1123Z:  Thu, 29 Nov 2018 05:46:03 +0300
    // RFC3339:  2018-11-29T05:46:03+03:00
    // RFC3339Nano:  2018-11-29T05:46:03.000024416+03:00
    // Kitchen:  5:46AM
    // am/pm:  5am
    // AM/PM:  5AM
    // two-digit year:  18 11 29
    // Janet:  Hi Janet, the Month is November
    // Stamp:  Nov 29 05:46:03
    // StampMilli:  Nov 29 05:46:03.000
    // StampMicro:  Nov 29 05:46:03.000024
    // StampNano:  Nov 29 05:46:03.000024416
    // OK
    // All tests passed.
}

test "durations" {
    // print w0ne hour and 10 secods
    const hour = Duration.Hour.value;
    const minute = Duration.Minute.value;
    const second = Duration.Second.value;
    var d = Duration.init(hour + minute * 4 + second * 10);
    warn("duration is {} \n", .{d.string()});
}

test "addDate" {
    var local = time.Location.getLocal();
    var ts = time.now(&local);
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try ts.string(&buf);
    warn("\ncurrent time is {}\n", .{buf.items});

    // let's add 1 year
    ts = ts.addDate(1, 0, 0);
    try ts.string(&buf);
    warn("this time next year is {}\n", .{buf.items});
}
