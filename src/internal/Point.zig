const std = @import("std");
const Point = @This();

x: f64 = 0.0,
y: f64 = 0.0,

pub const zero: Point = .{};

pub fn init(x: f64, y: f64) Point {
    return .{
        .x = x,
        .y = y,
    };
}
