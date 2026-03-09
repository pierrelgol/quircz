const std = @import("std");
const Image = @import("Image.zig");
pub const Histogram = @This();

items: [256]u32,

pub const empty: Histogram = .{ .items = @splat(0) };

pub fn fromImageChannel(self: *Histogram, image: *const Image) void {
    std.debug.assert(image.channel.len == image.pixelCount());
    self.* = .empty;
    var lanes = [4][256]u32{ @splat(0), @splat(0), @splat(0), @splat(0) };
    const ch = image.channel;
    const n = ch.len & ~@as(usize, 3);
    var i: usize = 0;
    while (i < n) : (i += 4) {
        inline for (0..4) |lane| {
            lanes[lane][ch[i + lane]] += 1;
        }
    }
    while (i < ch.len) : (i += 1) lanes[0][ch[i]] += 1;
    for (0..256) |bucket| {
        self.items[bucket] = lanes[0][bucket] + lanes[1][bucket] + lanes[2][bucket] + lanes[3][bucket];
    }
}

pub fn weightedSum(self: *const Histogram) f64 {
    var sum: f64 = 0;

    for (self.items, 0..) |item, index| {
        sum += @as(f64, @floatFromInt(index)) * @as(f64, @floatFromInt(item));
    }

    return sum;
}

test "fromImageChannel counts repeated pixel values exactly" {
    const image = Image.init(&.{ 0, 1, 1, 2, 2, 2, 255 }, 7, 1);
    var histogram: Histogram = .empty;
    histogram.fromImageChannel(&image);

    try std.testing.expectEqual(@as(u32, 1), histogram.items[0]);
    try std.testing.expectEqual(@as(u32, 2), histogram.items[1]);
    try std.testing.expectEqual(@as(u32, 3), histogram.items[2]);
    try std.testing.expectEqual(@as(u32, 1), histogram.items[255]);
}

test "fromImageChannel uniform value fills single bucket" {
    var buf: [100]u8 = @splat(42);
    const image = Image.init(&buf, 100, 1);
    var histogram: Histogram = .empty;
    histogram.fromImageChannel(&image);
    try std.testing.expectEqual(@as(u32, 100), histogram.items[42]);
    try std.testing.expectEqual(@as(u32, 0), histogram.items[0]);
}

test "fromImageChannel 4-way result matches scalar reference" {
    var buf: [1024]u8 = undefined;
    var xo = std.Random.DefaultPrng.init(7);
    xo.random().bytes(&buf);
    const image = Image.init(&buf, 1024, 1);

    var ref: [256]u32 = @splat(0);
    for (buf) |b| ref[b] += 1;

    var histogram: Histogram = .empty;
    histogram.fromImageChannel(&image);

    try std.testing.expectEqualSlices(u32, &ref, &histogram.items);
}

test "weightedSum matches hand-computed histogram total" {
    var histogram: Histogram = .empty;
    histogram.items[1] = 2;
    histogram.items[7] = 3;
    histogram.items[200] = 1;

    try std.testing.expectEqual(@as(f64, 223.0), histogram.weightedSum());
}
