# time

Time library for the zig programming language (ziglang).


In my opinion, the go programming language offers a very elegant api for dealing with time.
This library ports the [go standard library time package](). It is not 100% `1:1` mapping
with the go counterpart but offers majority of what you might need for your time needs.


# Locations and timezones

A time library isn't complete with timezone. This library supports timezone. I comes with
a parser implementation for reading timezone info from all supported platforms.