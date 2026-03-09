const std = @import("std");
const Decode = @import("Decode.zig");
const Capstone = @import("internal/Capstone.zig");
const FloodFill = @import("internal/FloodFill.zig");
const Grid = @import("internal/Grid.zig");
const Image = @import("internal/Image.zig");
const Perspective = @import("internal/Perspective.zig");
const Region = @import("internal/Region.zig");
const Scanner = @import("internal/Scanner.zig");
const Spec = @import("internal/Spec.zig");
const Detect = @This();

pub const Error = error{
    ScratchTooSmall,
    ImageSizeMismatch,
    TooManyRegions,
    TooManyCapstones,
    TooManyGrids,
};

pub const ExtractError = error{
    InvalidDetection,
    GridTooLarge,
};

pub const ScanError = Error || ExtractError || Decode.Error || error{
    NoCode,
    OutputTooSmall,
};

pub const Detection = struct {
    corners: [4]Perspective.PixelPoint = @splat(Perspective.PixelPoint.zero),
    grid_size: u16 = 0,
    perspective: Perspective = .{},
};

pub const Stats = struct {
    region_count: usize = 0,
    capstone_count: usize = 0,
    grid_count: usize = 0,
};

pub const Code = struct {
    corners: [4]Perspective.PixelPoint = @splat(Perspective.PixelPoint.zero),
    size: u16 = 0,
    cells: [Spec.max_bitmap_bytes]u8 = @splat(0),

    pub fn gridBit(self: *const Code, x: usize, y: usize) u1 {
        const index = y * self.size + x;
        return @intCast((self.cells[index >> 3] >> @as(u3, @intCast(index & 7))) & 1);
    }

    pub fn flip(self: *Code) void {
        var flipped: [Spec.max_bitmap_bytes]u8 = @splat(0);
        var offset: usize = 0;

        for (0..self.size) |y| {
            for (0..self.size) |x| {
                if (self.gridBit(y, x) != 0) {
                    flipped[offset >> 3] |= @as(u8, 1) << @as(u3, @intCast(offset & 7));
                }
                offset += 1;
            }
        }

        self.cells = flipped;
    }
};

image: Image,
scratch: []u8,
fba: std.heap.FixedBufferAllocator,
scanner: Scanner,

pub fn init(grayscale: []const u8, scratch: []u8, width: u32, height: u32) Detect {
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    var scanner = Scanner.init();
    scanner.reset(&fba);

    return .{
        .image = Image.init(grayscale, width, height),
        .scratch = scratch,
        .fba = fba,
        .scanner = scanner,
    };
}

pub fn reset(self: *Detect) void {
    self.fba = std.heap.FixedBufferAllocator.init(self.scratch);
    self.scanner.reset(&self.fba);
}

pub fn scratchBytesForImage(width: u32, height: u32) usize {
    const pixel_count = @as(usize, width) * @as(usize, height);
    return pixel_count * @sizeOf(u8) +
        FloodFill.stackDepthForHeight(height) * @sizeOf(FloodFill.StackFrame) +
        workspaceFixedBytes() +
        workspaceAlignmentSlack();
}

fn workspaceFixedBytes() usize {
    return @as(usize, Spec.max_regions) * @sizeOf(Region) +
        @as(usize, Spec.max_capstones) * @sizeOf(Capstone) +
        @as(usize, Spec.max_grids) * @sizeOf(Grid);
}

fn workspaceAlignmentSlack() usize {
    var slack: usize = 0;
    inline for (.{ u8, FloodFill.StackFrame, Region, Capstone, Grid }) |T| {
        slack += @alignOf(T) - 1;
    }
    return slack;
}

pub fn bitmapBytesForSize(size: u16) usize {
    return std.math.divCeil(usize, @as(usize, size) * size, 8) catch unreachable;
}

pub fn scan(
    self: *Detect,
    out_detections: []Detection,
) Error![]const Detection {
    self.reset();
    return self.scanner.scan(&self.image, out_detections);
}

pub fn extract(
    self: *Detect,
    detection: *const Detection,
) ExtractError!Code {
    return self.scanner.extract(&self.image, detection);
}

pub fn stats(self: *const Detect) Stats {
    return .{
        .region_count = self.scanner.region_count,
        .capstone_count = self.scanner.capstone_count,
        .grid_count = self.scanner.grid_count,
    };
}

pub fn scanFirst(
    grayscale: []const u8,
    scratch: []u8,
    width: u32,
    height: u32,
    out_payload: []u8,
) ScanError![]const u8 {
    var detect = Detect.init(grayscale, scratch, width, height);
    var detections: [Spec.max_grids]Detection = undefined;
    const found = try detect.scan(&detections);
    if (found.len == 0) return error.NoCode;

    return tryDecodeFirst(&detect, found, out_payload);
}

fn tryDecodeFirst(detect: *Detect, detections: []const Detection, out_payload: []u8) ScanError![]const u8 {
    var last_error: ?Decode.Error = null;
    for (detections) |*detection| {
        const code = detect.extract(detection) catch continue;
        const result = Decode.decode(&code, out_payload) catch |err| {
            last_error = err;
            continue;
        };
        return out_payload[0..result.payload_len];
    }

    return last_error orelse error.NoCode;
}

test "scratch byte estimator grows with image size" {
    try std.testing.expect(scratchBytesForImage(2, 2) < scratchBytesForImage(3, 2));
    try std.testing.expect(scratchBytesForImage(3, 2) < scratchBytesForImage(3, 3));
}

test "scratch byte estimator uses shared flood fill depth helper" {
    const width: u32 = 21;
    const height: u32 = 21;
    const pixel_count = @as(usize, width) * height;
    const expected =
        pixel_count * @sizeOf(u8) +
        FloodFill.stackDepthForHeight(height) * @sizeOf(FloodFill.StackFrame) +
        workspaceFixedBytes() +
        workspaceAlignmentSlack();
    try std.testing.expectEqual(expected, scratchBytesForImage(width, height));
}

test "scratch estimator no longer carries full binary image and large fixed padding" {
    const current = scratchBytesForImage(232, 232);
    try std.testing.expect(current < 150_000);
}

test "workspace alignment slack is bounded to allocation alignments" {
    try std.testing.expect(workspaceAlignmentSlack() < 64);
}

test "bitmap byte estimator matches packed grid sizes" {
    try std.testing.expectEqual(@as(usize, 56), bitmapBytesForSize(21));
    try std.testing.expectEqual(@as(usize, 392), bitmapBytesForSize(56));
    try std.testing.expectEqual(@as(usize, Spec.max_bitmap_bytes), bitmapBytesForSize(Spec.max_grid_size));
}

test "scanFirst reports NoCode on blank image" {
    var grayscale: [21 * 21]u8 = @splat(0xFF);
    var scratch: [scratchBytesForImage(21, 21)]u8 = undefined;
    var payload: [Spec.max_payload_bytes]u8 = undefined;

    try std.testing.expectError(error.NoCode, scanFirst(&grayscale, &scratch, 21, 21, &payload));
}

test "stats remain zero after scanning a blank image" {
    var grayscale: [21 * 21]u8 = @splat(0xFF);
    var scratch: [scratchBytesForImage(21, 21)]u8 = undefined;
    var detect = Detect.init(&grayscale, &scratch, 21, 21);
    var detections: [Spec.max_grids]Detection = undefined;

    const found = try detect.scan(&detections);
    try std.testing.expectEqual(@as(usize, 0), found.len);

    const scan_stats = detect.stats();
    try std.testing.expectEqual(@as(usize, 0), scan_stats.region_count);
    try std.testing.expectEqual(@as(usize, 0), scan_stats.capstone_count);
    try std.testing.expectEqual(@as(usize, 0), scan_stats.grid_count);
}
