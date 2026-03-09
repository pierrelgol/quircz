const std = @import("std");

pub const Detect = @import("Detect.zig");
pub const Decode = @import("Decode.zig");
pub const Encode = @import("Encode.zig");
const BitStream = @import("internal/BitStream.zig");
const Capstone = @import("internal/Capstone.zig");
const FloodFill = @import("internal/FloodFill.zig");
const Grid = @import("internal/Grid.zig");
const Histogram = @import("internal/Histogram.zig");
const Image = @import("internal/Image.zig");
const Perspective = @import("internal/Perspective.zig");
const ReedSolomon = @import("internal/ReedSolomon.zig");
const Region = @import("internal/Region.zig");
const Scanner = @import("internal/Scanner.zig");
const Spec = @import("internal/Spec.zig");
const VersionDb = @import("internal/VersionDb.zig");

pub const scratchBytesForImage = Detect.scratchBytesForImage;
pub const bitmapBytesForSize = Detect.bitmapBytesForSize;
pub const scanFirst = Detect.scanFirst;

comptime {
    std.testing.refAllDecls(Detect);
    std.testing.refAllDecls(Decode);
    std.testing.refAllDecls(Encode);
    std.testing.refAllDecls(BitStream);
    std.testing.refAllDecls(Capstone);
    std.testing.refAllDecls(FloodFill);
    std.testing.refAllDecls(Grid);
    std.testing.refAllDecls(Histogram);
    std.testing.refAllDecls(Image);
    std.testing.refAllDecls(Perspective);
    std.testing.refAllDecls(ReedSolomon);
    std.testing.refAllDecls(Region);
    std.testing.refAllDecls(Scanner);
    std.testing.refAllDecls(Spec);
    std.testing.refAllDecls(VersionDb);
}
