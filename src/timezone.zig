pub const Location = struct {
    name: []const u8,
    zone: ?[]zone,
    tz: ?zoneTrans,

    fn initName(name: []const u8) Location {
        return Location{
            .name = name,
            .zone = null,
            .tz = null,
        };
    }
};

const zone = struct {
    name: []const u8,
    offset: isize,
    is_dst: bool,
};

const zoneTrans = struct {
    when: i64,
    index: usize,
    is_std: bool,
    is_utc: bool,
};

// alpha and omega are the beginning and end of time for zone
// transitions.
const alpha: i64 = -1 << 63;
const omega: i64 = 1 << 63 - 1;
