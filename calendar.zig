// Calendar is a simple zig program that prints the calendar on the stdout. This
// is to showcase maturity of the time library.

const std = @import("std");
const warn = std.debug.warn;

fn month() [4][7]usize {
    var m: [4][7]usize = undefined;
    m[0][0] = 2;
    return m;
}

test "test" {
    const m = month();
    warn("{}\n", m.len);
}
