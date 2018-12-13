// Calendar is a simple zig program that prints the calendar on the stdout. This
// is to showcase maturity of the time library.

const Time = @import("./src/time.zig").Time;

pub fn main() void {
    Time.calendar();
}
