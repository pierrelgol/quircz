const std = @import("std");
const Spec = @import("Spec.zig");
const Perspective = @This();

pub const Scalar = f64;
pub const PixelPoint = struct {
    x: i32 = 0,
    y: i32 = 0,

    pub const zero: PixelPoint = .{};

    pub fn init(x: i32, y: i32) PixelPoint {
        return .{
            .x = x,
            .y = y,
        };
    }
};

pub const SamplePoint = struct {
    x: Scalar = 0.0,
    y: Scalar = 0.0,

    pub const zero: SamplePoint = .{};

    pub fn init(x: Scalar, y: Scalar) SamplePoint {
        return .{
            .x = x,
            .y = y,
        };
    }
};

pub const Rectangle = [4]PixelPoint;

pub const RowStepper = struct {
    x_num: Scalar,
    y_num: Scalar,
    den_num: Scalar,
    x_step: Scalar,
    y_step: Scalar,
    den_step: Scalar,

    pub fn mapCurrent(self: RowStepper) PixelPoint {
        const den: Scalar = 1.0 / self.den_num;
        return PixelPoint.init(
            roundToEvenInt(self.x_num * den),
            roundToEvenInt(self.y_num * den),
        );
    }

    pub fn advance(self: *RowStepper) void {
        self.x_num += self.x_step;
        self.y_num += self.y_step;
        self.den_num += self.den_step;
    }
};

coeffs: [Spec.perspective_parameter_count]Scalar = @splat(0.0),

pub fn init(rectangle: Rectangle, width: Scalar, height: Scalar) Perspective {
    const x0: Scalar = @floatFromInt(rectangle[0].x);
    const y0: Scalar = @floatFromInt(rectangle[0].y);
    const x1: Scalar = @floatFromInt(rectangle[1].x);
    const y1: Scalar = @floatFromInt(rectangle[1].y);
    const x2: Scalar = @floatFromInt(rectangle[2].x);
    const y2: Scalar = @floatFromInt(rectangle[2].y);
    const x3: Scalar = @floatFromInt(rectangle[3].x);
    const y3: Scalar = @floatFromInt(rectangle[3].y);

    const wden: Scalar = 1.0 / (width * (x2 * y3 - x3 * y2 + (x3 - x2) * y1 + x1 * (y2 - y3)));
    const hden: Scalar = 1.0 / (height * (x2 * y3 + x1 * (y2 - y3) - x3 * y2 + (x3 - x2) * y1));

    return .{
        .coeffs = .{
            (x1 * (x2 * y3 - x3 * y2) + x0 * (-x2 * y3 + x3 * y2 + (x2 - x3) * y1) +
                x1 * (x3 - x2) * y0) * wden,
            -(x0 * (x2 * y3 + x1 * (y2 - y3) - x2 * y1) - x1 * x3 * y2 + x2 * x3 * y1 +
                (x1 * x3 - x2 * x3) * y0) * hden,
            x0,
            (y0 * (x1 * (y3 - y2) - x2 * y3 + x3 * y2) + y1 * (x2 * y3 - x3 * y2) +
                x0 * y1 * (y2 - y3)) * wden,
            (x0 * (y1 * y3 - y2 * y3) + x1 * y2 * y3 - x2 * y1 * y3 +
                y0 * (x3 * y2 - x1 * y2 + (x2 - x3) * y1)) * hden,
            y0,
            (x1 * (y3 - y2) + x0 * (y2 - y3) + (x2 - x3) * y1 + (x3 - x2) * y0) * wden,
            (-x2 * y3 + x1 * y3 + x3 * y2 + x0 * (y1 - y2) - x3 * y1 + (x2 - x1) * y0) * hden,
        },
    };
}

pub fn map(self: Perspective, u: Scalar, v: Scalar) PixelPoint {
    const c = self.coeffs;
    const den: Scalar = 1.0 / (c[6] * u + c[7] * v + 1.0);
    const x = (c[0] * u + c[1] * v + c[2]) * den;
    const y = (c[3] * u + c[4] * v + c[5]) * den;

    return PixelPoint.init(roundToEvenInt(x), roundToEvenInt(y));
}

pub fn initRowStepper(self: Perspective, u: Scalar, v: Scalar, u_step: Scalar) RowStepper {
    const c = self.coeffs;
    const row_x = c[1] * v + c[2];
    const row_y = c[4] * v + c[5];
    const row_den = c[7] * v + 1.0;
    return .{
        .x_num = c[0] * u + row_x,
        .y_num = c[3] * u + row_y,
        .den_num = c[6] * u + row_den,
        .x_step = c[0] * u_step,
        .y_step = c[3] * u_step,
        .den_step = c[6] * u_step,
    };
}

pub fn unmap(self: Perspective, point: PixelPoint) SamplePoint {
    const c = self.coeffs;
    const x: Scalar = @floatFromInt(point.x);
    const y: Scalar = @floatFromInt(point.y);
    const den: Scalar = 1.0 /
        (-c[0] * c[7] * y + c[1] * c[6] * y + (c[3] * c[7] - c[4] * c[6]) * x + c[0] * c[4] - c[1] * c[3]);

    return SamplePoint.init(
        -(c[1] * (y - c[5]) - c[2] * c[7] * y + (c[5] * c[7] - c[4]) * x + c[2] * c[4]) * den,
        (c[0] * (y - c[5]) - c[2] * c[6] * y + (c[5] * c[6] - c[3]) * x + c[2] * c[3]) * den,
    );
}

pub fn jiggle(
    self: *Perspective,
    context: anytype,
    comptime fitness_fn: fn (@TypeOf(context), Perspective) i32,
) void {
    var best = fitness_fn(context, self.*);
    var adjustments: [Spec.perspective_parameter_count]Scalar = undefined;

    for (&adjustments, self.coeffs) |*adjustment, coeff| {
        adjustment.* = coeff * 0.02;
    }

    for (0..5) |_| {
        for (0..(Spec.perspective_parameter_count * 2)) |i| {
            const index = i >> 1;
            const old = self.coeffs[index];
            const step = adjustments[index];
            const delta = if ((i & 1) != 0) step else -step;
            self.coeffs[index] = old + delta;

            const candidate = fitness_fn(context, self.*);
            if (candidate > best) {
                best = candidate;
            } else {
                self.coeffs[index] = old;
            }
        }

        for (&adjustments) |*adjustment| {
            adjustment.* *= 0.5;
        }
    }
}

pub fn jiggleInformed(
    self: *Perspective,
    context: anytype,
    comptime fitness_fn: fn (@TypeOf(context), Perspective, usize) i32,
) void {
    var best = fitness_fn(context, self.*, Spec.perspective_parameter_count);
    var adjustments: [Spec.perspective_parameter_count]Scalar = undefined;

    for (&adjustments, self.coeffs) |*adjustment, coeff| {
        adjustment.* = coeff * 0.02;
    }

    for (0..5) |_| {
        for (0..(Spec.perspective_parameter_count * 2)) |i| {
            const index = i >> 1;
            const old = self.coeffs[index];
            const step = adjustments[index];
            const delta = if ((i & 1) != 0) step else -step;
            self.coeffs[index] = old + delta;

            const candidate = fitness_fn(context, self.*, index);
            if (candidate > best) {
                best = candidate;
            } else {
                self.coeffs[index] = old;
            }
        }

        for (&adjustments) |*adjustment| {
            adjustment.* *= 0.5;
        }
    }
}

pub inline fn roundToEvenInt(value: Scalar) i32 {
    const magic: Scalar = 6755399441055744.0;
    return @intFromFloat((value + magic) - magic);
}

test "transform has fixed coefficient count" {
    const transform: Perspective = .{};
    try @import("std").testing.expectEqual(@as(usize, Spec.perspective_parameter_count), transform.coeffs.len);
}

test "map and unmap preserve rectangle corners" {
    const rect: Rectangle = .{
        .{ .x = 10, .y = 20 },
        .{ .x = 30, .y = 20 },
        .{ .x = 30, .y = 40 },
        .{ .x = 10, .y = 40 },
    };
    const transform = Perspective.init(rect, 20.0, 20.0);

    try std.testing.expectEqual(rect[0], transform.map(0.0, 0.0));
    try std.testing.expectEqual(rect[2], transform.map(20.0, 20.0));

    const sample = transform.unmap(.{ .x = 20, .y = 30 });
    try std.testing.expectApproxEqAbs(@as(Scalar, 10.0), sample.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(Scalar, 10.0), sample.y, 0.001);
}

test "roundToEvenInt preserves banker rounding on ties" {
    try std.testing.expectEqual(@as(i32, 2), roundToEvenInt(2.5));
    try std.testing.expectEqual(@as(i32, 4), roundToEvenInt(3.5));
    try std.testing.expectEqual(@as(i32, -2), roundToEvenInt(-2.5));
    try std.testing.expectEqual(@as(i32, -4), roundToEvenInt(-3.5));
}

test "roundToEvenInt keeps non-tie rounding stable around half steps" {
    const cases = [_]struct { value: Scalar, expected: i32 }{
        .{ .value = 1.499999999, .expected = 1 },
        .{ .value = 1.500000001, .expected = 2 },
        .{ .value = 2.500000001, .expected = 3 },
        .{ .value = -1.499999999, .expected = -1 },
        .{ .value = -1.500000001, .expected = -2 },
        .{ .value = -2.500000001, .expected = -3 },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.expected, roundToEvenInt(case.value));
    }
}

test "roundToEvenInt preserves zero-centered tie behavior" {
    try std.testing.expectEqual(@as(i32, 0), roundToEvenInt(0.5));
    try std.testing.expectEqual(@as(i32, 0), roundToEvenInt(-0.5));
    try std.testing.expectEqual(@as(i32, 0), roundToEvenInt(0.499999999));
    try std.testing.expectEqual(@as(i32, 0), roundToEvenInt(-0.499999999));
}

test "jiggle leaves coefficients unchanged on flat fitness" {
    const rect: Rectangle = .{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
        .{ .x = 0, .y = 10 },
    };
    var perspective = Perspective.init(rect, 10.0, 10.0);
    const before = perspective.coeffs;

    const Context = struct {};
    const Callback = struct {
        fn score(_: Context, _: Perspective) i32 {
            return 7;
        }
    };

    perspective.jiggle(Context{}, Callback.score);
    try std.testing.expectEqualDeep(before, perspective.coeffs);
}

test "row stepper matches map across the fitness cell sample offsets" {
    const rect: Rectangle = .{
        .{ .x = 2, .y = 1 },
        .{ .x = 24, .y = 3 },
        .{ .x = 23, .y = 26 },
        .{ .x = 0, .y = 25 },
    };
    const perspective = Perspective.init(rect, 20.0, 20.0);
    const offsets = [_]Scalar{ 0.3, 0.5, 0.7 };

    for (0..6) |cell_y| {
        const vy = @as(Scalar, @floatFromInt(cell_y)) + offsets[1];
        var stepper = perspective.initRowStepper(0.3, vy, 0.2);

        for (offsets, 0..) |offset, index| {
            const expected = perspective.map(offset, vy);
            try std.testing.expectEqualDeep(expected, stepper.mapCurrent());
            if (index + 1 < offsets.len) {
                stepper.advance();
            }
        }
    }
}
