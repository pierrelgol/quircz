const std = @import("std");
pub const Perspective = @This();
pub const Rectangle = [4]Point;
const Point = @import("Point.zig");

rectangle: Rectangle = @splat(Point.zero),

pub fn setup(perspective: Perspective, c: []f64, w: f64, h: f64) void {
    const x0: f64 = perspective.rectangle[0].x;
    const y0: f64 = perspective.rectangle[0].y;
    const x1: f64 = perspective.rectangle[1].x;
    const y1: f64 = perspective.rectangle[1].y;
    const x2: f64 = perspective.rectangle[2].x;
    const y2: f64 = perspective.rectangle[2].y;
    const x3: f64 = perspective.rectangle[3].x;
    const y3: f64 = perspective.rectangle[3].y;

    const wden: f64 = 1.0 / (w * (x2 * y3 - x3 * y2 + (x3 - x2) * y1 + x1 * (y2 - y3)));
    const hden: f64 = 1.0 / (h * (x2 * y3 + x1 * (y2 - y3) - x3 * y2 + (x3 - x2) * y1));

    c[0] = (x1 * (x2 * y3 - x3 * y2) +
        x0 * (-x2 * y3 + x3 * y2 + (x2 - x3) * y1) + x1 * (x3 - x2) * y0) *
        wden;

    c[1] = -(x0 * (x2 * y3 + x1 * (y2 - y3) - x2 * y1) - x1 * x3 * y2 +
        x2 * x3 * y1 + (x1 * x3 - x2 * x3) * y0) *
        hden;

    c[2] = x0;

    c[3] = (y0 * (x1 * (y3 - y2) - x2 * y3 + x3 * y2) + y1 * (x2 * y3 - x3 * y2) +
        x0 * y1 * (y2 - y3)) *
        wden;

    c[4] = (x0 * (y1 * y3 - y2 * y3) + x1 * y2 * y3 - x2 * y1 * y3 +
        y0 * (x3 * y2 - x1 * y2 + (x2 - x3) * y1)) *
        hden;

    c[5] = y0;

    c[6] = (x1 * (y3 - y2) + x0 * (y2 - y3) + (x2 - x3) * y1 + (x3 - x2) * y0) *
        wden;

    c[7] = (-x2 * y3 + x1 * y3 + x3 * y2 + x0 * (y1 - y2) - x3 * y1 +
        (x2 - x1) * y0) *
        hden;
}

pub fn map(_: Perspective, c: []f64, u: f64, v: f64, ret: *Point) void {
    const den: f64 = 1.0 / (c[6] * u + c[7] * v + 1.0);
    const x: f64 = (c[0] * u + c[1] * v + c[2]) * den;
    const y: f64 = (c[3] * u + c[4] * v + c[5]) * den;
    ret.x = @round(x);
    ret.y = @round(y);
}
