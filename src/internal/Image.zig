const std = @import("std");
const Histogram = @import("Histogram.zig");
pub const Image = @This();
pub const Pixel = u8;
pub const Threshold = u8;

channel: []const Pixel,
width: u32,
height: u32,

pub fn init(grayscale: []const u8, width: u32, height: u32) Image {
    return .{
        .channel = grayscale,
        .height = height,
        .width = width,
    };
}

pub fn pixelCount(self: Image) usize {
    return @as(usize, self.width) * @as(usize, self.height);
}

pub fn validate(self: *const Image) error{ImageSizeMismatch}!void {
    if (self.channel.len != self.pixelCount()) return error.ImageSizeMismatch;
}

pub fn computeAdaptiveThreshold(self: *const Image, histogram: *const Histogram) Threshold {
    const total: f64 = @floatFromInt(self.pixelCount());
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

        const mean_background = sum_background / weight_background;
        const mean_foreground = (sum_total - sum_background) / weight_foreground;

        const diff = mean_background - mean_foreground;
        const variance = weight_background * weight_foreground * diff * diff;

        if (variance >= max_variance) {
            max_variance = variance;
            best_threshold = @intCast(i);
        }
    }

    return best_threshold;
}

pub fn thresholdIntoLabels(
    self: *const Image,
    threshold: Threshold,
    out_labels: []u8,
    unlabeled: u8,
    white_val: u8,
) error{ImageSizeMismatch}!void {
    if (out_labels.len != self.pixelCount()) return error.ImageSizeMismatch;
    const VecLen = std.simd.suggestVectorLength(u8) orelse 8;
    const VecU8 = @Vector(VecLen, u8);
    const thresh_vec: VecU8 = @splat(threshold);
    const black_vec: VecU8 = @splat(unlabeled);
    const white_vec: VecU8 = @splat(white_val);
    var i: usize = 0;
    while (i + VecLen <= self.channel.len) : (i += VecLen) {
        const pixels: VecU8 = self.channel[i..][0..VecLen].*;
        const is_black = pixels < thresh_vec;
        out_labels[i..][0..VecLen].* = @select(u8, is_black, black_vec, white_vec);
    }
    while (i < self.channel.len) : (i += 1) {
        out_labels[i] = thresholdLabel(self.channel[i], threshold, unlabeled, white_val);
    }
}

fn thresholdLabel(pixel: Pixel, threshold: Threshold, unlabeled: u8, white_val: u8) u8 {
    return if (pixel < threshold) unlabeled else white_val;
}

test "otsu random" {
    var buffer: [1024]u8 = @splat(0);
    var xo = std.Random.DefaultPrng.init(42);
    const rand = xo.random();
    rand.bytes(&buffer);

    const image = Image.init(&buffer, 32, 32);
    var histogram: Histogram = .empty;
    histogram.fromImageChannel(&image);
    const threshold = image.computeAdaptiveThreshold(&histogram);
    try std.testing.expect(threshold == 128);
}

test "otsu zero" {
    var buffer: [1024]u8 = @splat(0);

    const image = Image.init(&buffer, 32, 32);
    var histogram: Histogram = .empty;
    histogram.fromImageChannel(&image);
    const threshold = image.computeAdaptiveThreshold(&histogram);
    try std.testing.expect(threshold == 0);
}

test "otsu max" {
    var buffer: [1024]u8 = @splat(std.math.maxInt(u8));

    const image = Image.init(&buffer, 32, 32);
    var histogram: Histogram = .empty;
    histogram.fromImageChannel(&image);
    const threshold = image.computeAdaptiveThreshold(&histogram);
    try std.testing.expect(threshold == 0);
}

test "validate rejects channel length mismatch" {
    const image = Image.init(&.{ 0, 1, 2 }, 2, 2);
    try std.testing.expectError(error.ImageSizeMismatch, image.validate());
}

test "thresholdIntoLabels writes unlabeled and white sentinels" {
    const image = Image.init(&.{ 0, 127, 128, 255 }, 2, 2);
    var out: [4]u8 = undefined;
    try image.thresholdIntoLabels(128, &out, 0, 0xFF);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0xFF, 0xFF }, &out);
}

test "thresholdIntoLabels equality is white" {
    const image = Image.init(&.{ 10, 11, 12, 13 }, 2, 2);
    var out: [4]u8 = undefined;
    try image.thresholdIntoLabels(12, &out, 0, 0xFF);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0xFF, 0xFF }, &out);
}

test "thresholdIntoLabels rejects length mismatch" {
    const image = Image.init(&.{ 0, 1, 2, 3 }, 2, 2);
    var short: [3]u8 = undefined;
    try std.testing.expectError(error.ImageSizeMismatch, image.thresholdIntoLabels(128, &short, 0, 0xFF));
}

test "thresholdIntoLabels SIMD matches scalar for 512-byte input" {
    var buffer: [512]u8 = undefined;
    var xo = std.Random.DefaultPrng.init(99);
    xo.random().bytes(&buffer);

    const image = Image.init(&buffer, 32, 16);
    var simd_out: [512]u8 = undefined;
    try image.thresholdIntoLabels(128, &simd_out, 0, 0xFF);

    for (buffer, simd_out) |pix, label| {
        const expected: u8 = if (pix < 128) 0 else 0xFF;
        try std.testing.expectEqual(expected, label);
    }
}
