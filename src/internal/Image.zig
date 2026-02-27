const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const Io = std.Io;
const Image = @This();
const Histogram = @import("Histogram.zig");
pub const Pixel = u8;
pub const Threshold = u8;

channel: []Pixel,
width: u32,
height: u32,

pub fn init(grayscale: []u8, width: u32, height: u32) Image {
    return .{
        .channel = grayscale,
        .height = height,
        .width = width,
    };
}

pub fn computeAdaptativeThreshold(self: *const Image, histogram: *const Histogram) Threshold {
    const total: f64 = @floatFromInt(self.channel.len);
    const sum_total: f64 = histogram.weightedSum();

    var sum_background: f64 = 0.0;
    var weight_background: f64 = 0.0;

    var best_threshold: u8 = 0;
    var max_variance: f64 = 0.0;

    for (histogram.items, 0..) |count, i| {
        const count_f: f64 = @floatFromInt(count);

        weight_background += count_f;
        if (weight_background == 0.0) {
            continue;
        }

        const weight_foreground = total - weight_background;
        if (weight_foreground == 0.0) {
            break;
        }
        sum_background += @as(f64, @floatFromInt(i)) * count_f;

        const mean_background = (sum_background / weight_background);
        const mean_foreground = (sum_total - sum_background) / weight_foreground;

        const diff = mean_background - mean_foreground;
        const variance = weight_background * weight_foreground * diff * diff;

        if (variance > max_variance) {
            max_variance = variance;
            best_threshold = @intCast(i);
        }
    }

    return best_threshold;
}

pub fn applyThreshold(self: *Image, threshold: Threshold) void {
    const VecLen = std.simd.suggestVectorLength(u8) orelse 8;
    const VecPix = @Vector(VecLen, u8);
    const VecBool = @Vector(VecLen, bool);
    const len = self.channel.len;
    const thresh_vec: VecPix = @splat(threshold);
    const zero: VecPix = @splat(0x00);
    const full: VecPix = @splat(0xFF);

    var i: usize = 0;
    while (i + VecLen <= len) : (i += VecLen) {
        const px: VecPix = @as(VecPix, self.channel[i..][0..VecLen].*);
        const mask: VecBool = px > thresh_vec;
        self.channel[i..][0..VecLen].* = @select(u8, mask, full, zero);
    }

    while (i < len) : (i += 1) {
        const mask: u8 = @intFromBool(self.channel[i] > threshold);
        self.channel[i] = 0 -% mask;
    }
}

test "otsu random" {
    var buffer: [1024]u8 = @splat(0);
    var xo = std.Random.DefaultPrng.init(42);
    const rand = xo.random();
    rand.fillFn(@ptrCast(@alignCast(&xo)), &buffer);

    var image = Image.init(&buffer, 32, 32);
    var histogram: Histogram = .empty;
    histogram.fromImageChannel(&image);
    const threshold = image.computeAdaptativeThreshold(&histogram);
    try std.testing.expect(threshold == 128);
}

test "otsu zero" {
    var buffer: [1024]u8 = @splat(0);

    const image = Image.init(&buffer, 32, 32);
    var histogram: Histogram = .empty;
    histogram.fromImageChannel(&image);
    const threshold = image.computeAdaptativeThreshold(&histogram);
    try std.testing.expect(threshold == 0);
}

test "otsu max" {
    var buffer: [1024]u8 = @splat(std.math.maxInt(u8));

    const image = Image.init(&buffer, 32, 32);
    var histogram: Histogram = .empty;
    histogram.fromImageChannel(&image);
    const threshold = image.computeAdaptativeThreshold(&histogram);
    try std.testing.expect(threshold == 0);
}
