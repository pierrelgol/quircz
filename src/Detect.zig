const std = @import("std");
const Histogram = @import("internal/Histogram.zig");
const Image = @import("internal/Image.zig");

comptime {
    std.testing.refAllDecls(Histogram);
    std.testing.refAllDecls(Image);
}
