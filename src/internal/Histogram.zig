const std = @import("std");
const math = std.math;
const Image = @import("Image.zig");
pub const Histogram = @This();

items: [256]u32,

pub const empty: Histogram = .{ .items = @splat(0) };

pub fn fromImageChannel(self: *Histogram, image: *const Image) void {
    for (image.channel) |pixel_value| {
        self.items[pixel_value] += 1;
    }
}

pub fn weightedSum(self: *const Histogram) f64 {
    var sum: f64 = 0;

    for (self.items, 0..) |item, index| {
        sum += @as(f64, @floatFromInt(index)) * @as(f64, @floatFromInt(item));
    }

    return sum;
}
