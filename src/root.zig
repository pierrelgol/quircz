const std = @import("std");
const Io = std.Io;
const Decode = @import("Decode.zig");
const Encode = @import("Encode.zig");
const Detect = @import("Detect.zig");

comptime {
    std.testing.refAllDecls(Decode);
    std.testing.refAllDecls(Encode);
    std.testing.refAllDecls(Detect);
}
