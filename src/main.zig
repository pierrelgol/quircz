const std = @import("std");
const quircz = @import("quircz");
const Io = std.Io;

comptime {
    std.testing.refAllDecls(quircz);
}

pub fn main(init: std.process.Init) !void {
    _ = init;
}
