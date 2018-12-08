# Release notes for Time (v0.6.0)

This marks another notable release from `v0.3.1`. For anyone of you who isn't
familiar with what this is all about, [time](https://github.com/gernest/time) is a time package for the zig
programming language. It offers a clean API to manipulate and display time,
this package also supports time zones.

## Notable changes


### Print durations in a human format

`Duration.string` returns a human readable string for the duration.
For instance if you want to print duration of one hour ,four minutes and 10 seconds.

```
    const hour = Duration.Hour.value;
    const minute = Duration.Minute.value;
    const second = Duration.Second.value;
    var d = Duration.init(hour + minute * 4 + second * 10);
    warn("duration is {} \n", d.string());
```
```
duration is 1h4m10s
```


## date manipulations

### Time.addDate

You can add date value to an existing Time instance to get a new date.

For example

```
    var local = time.Location.getLocal();
    var ts = time.now(&local);
    var buf = try std.Buffer.init(std.debug.global_allocator, "");
    defer buf.deinit();
    try ts.string(&buf);
    warn("\ncurrent time is {}\n", buf.toSlice());

    // let's add 1 year
    ts = ts.addDate(1, 0, 0);
    try ts.string(&buf);
    warn("this time next year is {}\n", buf.toSlice());
```

```
current time is 2018-12-08 10:32:30.000178063 +0300 EATm=+419006.837156719
this time next year is 2019-12-08 10:32:30.000178063 +0300 EAT
```

Please play with the api, you can add year,month,day. If you want to go back in
time then use negative numbers. From the example above if you want to back one year then
use `ts.addDate(-1, 0, 0)`


This is just highlight, there are

- lots of bug fixes
- cleanups to more idiomatic zig
- lots of utility time goodies like `Time.beginningOfMonth`
- improved documentation
- lots of tests added
- ... and so much more

I encourage you to take a look at it so you can experiment for yourself.

All kind of feedback is welcome.

Enjoy

