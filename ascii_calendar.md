This is part of [time](https://github.com/gernest/time) package. I think it is cool to showcase how far the package has matured.

`calendar.zig`

```
const Time = @import("./src/time.zig").Time;

pub fn main() void {
    Time.calendar();
}
```

```
$ zig run calendar.zig

Sun |Mon |Tue |Wed |Thu |Fri |Sat |
    |    |    |    |    |    |  1 |
  2 |  3 |  4 |  5 |  6 |  7 |  8 |
  9 | 10 | 11 | 12 |*13 | 14 | 15 |
 16 | 17 | 18 | 19 | 20 | 21 | 22 |
 23 | 24 | 25 | 26 | 27 | 28 | 29 |
 30 | 31 |    |    |    |    |    |
```

Today's date is prefixed with `*` eg `*13`.

Enjoy.