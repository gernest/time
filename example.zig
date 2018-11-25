const std = @import("std");
const warn = std.debug.warn;
const time = @import("./src/time.zig");

test "now" {
    var now = time.now();

    warn("\n today's date {}", now.date());
    warn("\n today's time {}", now.clock());
    warn("\n local timezone detail  {}\n", now.zone());
}
