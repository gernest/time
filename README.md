time for zig.

This uses monotonic clock, support timezone.

__WARNING__: This was only tested to work on darwin (mac os), theoretical it might work with linux but don't hold your breath, I don't have a linux machine PR's are welcome though.


This is still in early stage, it isn't feature complete yet. But all important functions are available so you can still have fun and waste your `time` on it.

### Usage

```
const std = @import("std");
const warn = std.debug.warn;
const time = @import("./src/time.zig");

test "now" {
    var now = time.now();

    warn("\n today's date {}", now.date());
    warn("\n today's time {}", now.clock());
    warn("\n local timezone detail  {}\n", now.zone());

    // $ zig test example.zig
    // Test 1/1 now...
    //  today's date DateDetail{ .year = 2018, .month = Month.November, .day = 25, .yday = 328 }
    //  today's time Clock{ .hour = 11, .min = 17, .sec = 16 }
    //  local timezone detail  ZoneDetail{ .name = EAT, .offset = 10800 }
    // OK
    // All tests passed.
}
```