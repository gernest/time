## formating timestamps with zig

Most of you are not aware of the [time package](https://github.com/gernest/time).
A new release has just landed with support for formating time into various timestamps.

### Layouts
Time is formatted into different layouts. A layout is a string which defines
how time is formatted, for example `Mon Jan 2 15:04:05 MST 2006`.

You can read more about layouts 
here https://github.com/gernest/time/blob/a3d45b5f5b607b7bedd4d0d4ca12307f0d6ff52b/src/time.zig#L791-L850

I will focus on showcasing using the standard timestamp layouts that are provided by the library.

These are standard layouts provided by the library

```
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
```

### show me some code

```
const std = @import("std");
const warn = std.debug.warn;
const time = @import("./src/time.zig");


const formatTest = struct {
    name: []const u8,
    format: []const u8,
    fn init(name: []const u8, format: []const u8) formatTest {
        return formatTest{ .name = name, .format = format };
    }
};

const format_tests = []formatTest{
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
    var ts = time.now();
    var buf = try std.Buffer.init(std.debug.global_allocator, "");
    defer buf.deinit();
    warn("\n");
    for (format_tests) |value| {
        try ts.format(&buf, value.format);
        const got = buf.toSlice();
        warn("{}:  {}\n", value.name, got);
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
```

All kind of feedback is welcome.

Enjoy.