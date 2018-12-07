// Calendar is a simple zig program that prints the calendar on the stdout. This
// is to showcase maturity of the time library.

const std = @import("std");
const warn = std.debug.warn;
const Time = @import("./src/time.zig").Time;

pub fn main() void {
    Time.calendar();
}
