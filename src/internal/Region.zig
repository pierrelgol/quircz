const std = @import("std");
const FloodFill = @import("FloodFill.zig");
const Perspective = @import("Perspective.zig");
const Spec = @import("Spec.zig");

const Region = @This();

pub const unlabeled: u8 = 0;
pub const white: u8 = std.math.maxInt(u8);

label: u8 = 0,
seed: Perspective.PixelPoint = .{},
area: u32 = 0,
capstone_index: ?u8 = null,

pub fn labelAt(labels: []const u8, width: u32, height: u32, x: i32, y: i32) ?u8 {
    if (x < 0 or y < 0 or x >= width or y >= height) {
        return null;
    }

    const label = labels[@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))];
    if (label == unlabeled or label == white) {
        return null;
    }

    return label;
}

pub fn byLabel(regions: []Region, label: u8) ?*Region {
    const index = labelIndex(regions.len, label) orelse return null;
    return &regions[index];
}

pub fn byLabelConst(regions: []const Region, label: u8) ?*const Region {
    const index = labelIndex(regions.len, label) orelse return null;
    return &regions[index];
}

pub fn labelRegionAt(
    labels: []u8,
    width: u32,
    height: u32,
    x: i32,
    y: i32,
    stack: []FloodFill.StackFrame,
    regions: []Region,
    region_count: *u16,
) error{ TooManyRegions, ScratchTooSmall }!?u8 {
    if (x < 0 or y < 0 or x >= width or y >= height) {
        return null;
    }

    const index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
    const current = labels[index];
    if (current == white) return null;
    if (current != unlabeled) return current;

    if (region_count.* >= regions.len or region_count.* >= Spec.max_regions) {
        return error.TooManyRegions;
    }

    const seed = Perspective.PixelPoint.init(x, y);
    const label: u8 = @intCast(region_count.* + 1);
    const area = try FloodFill.fillFromSeed(labels, width, height, seed, unlabeled, label, stack);

    regions[region_count.*] = .{
        .label = label,
        .seed = seed,
        .area = area,
        .capstone_index = null,
    };
    region_count.* += 1;
    return label;
}

pub fn findCorners(
    self: Region,
    labels: []u8,
    width: u32,
    height: u32,
    reference: Perspective.PixelPoint,
    stack: []FloodFill.StackFrame,
) error{InvalidRegion}![4]Perspective.PixelPoint {
    if (self.label == 0 or self.label == white) {
        return error.InvalidRegion;
    }

    var farthest = self.seed;
    var farthest_score: i64 = -1;

    var first_pass = FirstCornerContext{
        .reference = reference,
        .farthest = &farthest,
        .farthest_score = &farthest_score,
    };
    _ = FloodFill.fillFromSeedWithCallback(
        labels,
        width,
        height,
        self.seed,
        self.label,
        unlabeled,
        stack,
        FirstCornerContext,
        FirstCornerContext.onSpan,
        &first_pass,
    ) catch return error.InvalidRegion;

    if (farthest_score < 0) {
        return error.InvalidRegion;
    }

    const ref_dx: i64 = farthest.x - reference.x;
    const ref_dy: i64 = farthest.y - reference.y;

    var corners: [4]Perspective.PixelPoint = @splat(self.seed);
    var scores = [4]i64{
        self.seed.x * ref_dx + self.seed.y * ref_dy,
        self.seed.x * -ref_dy + self.seed.y * ref_dx,
        -(self.seed.x * ref_dx + self.seed.y * ref_dy),
        -(self.seed.x * -ref_dy + self.seed.y * ref_dx),
    };

    var second_pass = OtherCornersContext{
        .ref_dx = ref_dx,
        .ref_dy = ref_dy,
        .score0 = &scores[0],
        .score1 = &scores[1],
        .score2 = &scores[2],
        .score3 = &scores[3],
        .corner0 = &corners[0],
        .corner1 = &corners[1],
        .corner2 = &corners[2],
        .corner3 = &corners[3],
    };
    _ = FloodFill.fillFromSeedWithCallback(
        labels,
        width,
        height,
        self.seed,
        unlabeled,
        self.label,
        stack,
        OtherCornersContext,
        OtherCornersContext.onSpan,
        &second_pass,
    ) catch return error.InvalidRegion;

    return corners;
}

const FirstCornerContext = struct {
    reference: Perspective.PixelPoint,
    farthest: *Perspective.PixelPoint,
    farthest_score: *i64,

    fn onSpan(self: *FirstCornerContext, y: i32, left: i32, right: i32) void {
        const xs = [_]i32{ left, right };
        for (xs) |x| {
            const dx: i64 = x - self.reference.x;
            const dy: i64 = y - self.reference.y;
            const score = dx * dx + dy * dy;
            if (score > self.farthest_score.*) {
                self.farthest_score.* = score;
                self.farthest.* = .{ .x = x, .y = y };
            }
        }
    }
};

fn labelIndex(region_len: usize, label: u8) ?usize {
    if (label == unlabeled or label > region_len) return null;
    return label - 1;
}

const OtherCornersContext = struct {
    ref_dx: i64,
    ref_dy: i64,
    score0: *i64,
    score1: *i64,
    score2: *i64,
    score3: *i64,
    corner0: *Perspective.PixelPoint,
    corner1: *Perspective.PixelPoint,
    corner2: *Perspective.PixelPoint,
    corner3: *Perspective.PixelPoint,

    fn onSpan(self: *OtherCornersContext, y: i32, left: i32, right: i32) void {
        const xs = [_]i32{ left, right };
        for (xs) |x| {
            const px: i64 = x;
            const py: i64 = y;
            const up = px * self.ref_dx + py * self.ref_dy;
            const right_score = px * -self.ref_dy + py * self.ref_dx;
            const point = Perspective.PixelPoint.init(x, y);
            if (up > self.score0.*) {
                self.score0.* = up;
                self.corner0.* = point;
            }
            if (right_score > self.score1.*) {
                self.score1.* = right_score;
                self.corner1.* = point;
            }
            if (-up > self.score2.*) {
                self.score2.* = -up;
                self.corner2.* = point;
            }
            if (-right_score > self.score3.*) {
                self.score3.* = -right_score;
                self.corner3.* = point;
            }
        }
    }
};

test "label region at assigns dense labels and area" {
    const binary = [_]u8{
        1, 1, 0, 0,
        1, 0, 0, 1,
        0, 0, 1, 1,
    };
    var labels: [binary.len]u8 = @splat(unlabeled);
    for (binary, 0..) |value, i| {
        if (value == 0) labels[i] = white;
    }

    var stack: [8]FloodFill.StackFrame = undefined;
    var regions: [Spec.max_regions]Region = undefined;
    var region_count: u16 = 0;

    const first = try labelRegionAt(&labels, 4, 3, 0, 0, &stack, &regions, &region_count);
    const second = try labelRegionAt(&labels, 4, 3, 3, 1, &stack, &regions, &region_count);

    try std.testing.expectEqual(@as(?u8, 1), first);
    try std.testing.expectEqual(@as(?u8, 2), second);
    try std.testing.expectEqual(@as(u16, 2), region_count);
    try std.testing.expectEqual(@as(u32, 3), regions[0].area);
    try std.testing.expectEqual(@as(u32, 3), regions[1].area);
}

test "labelAt and byLabel reject invalid lookups" {
    const labels = [_]u8{
        unlabeled, white,
        1,         2,
    };
    var regions: [2]Region = .{
        .{ .label = 1 },
        .{ .label = 2 },
    };

    try std.testing.expect(labelAt(&labels, 2, 2, -1, 0) == null);
    try std.testing.expect(labelAt(&labels, 2, 2, 0, 0) == null);
    try std.testing.expect(labelAt(&labels, 2, 2, 1, 0) == null);
    try std.testing.expectEqual(@as(?u8, 2), labelAt(&labels, 2, 2, 1, 1));
    try std.testing.expect(byLabel(&regions, 0) == null);
    try std.testing.expect(byLabelConst(&regions, 3) == null);
}

test "label region uses probe point as seed and reuses labels on later lookups" {
    const binary = [_]u8{
        1, 1, 1,
        1, 0, 0,
    };
    var labels: [binary.len]u8 = @splat(unlabeled);
    for (binary, 0..) |value, i| {
        if (value == 0) labels[i] = white;
    }

    var stack: [8]FloodFill.StackFrame = undefined;
    var regions: [Spec.max_regions]Region = undefined;
    var region_count: u16 = 0;

    const first = try labelRegionAt(&labels, 3, 2, 2, 0, &stack, &regions, &region_count);
    const second = try labelRegionAt(&labels, 3, 2, 0, 0, &stack, &regions, &region_count);

    try std.testing.expectEqual(@as(?u8, 1), first);
    try std.testing.expectEqual(@as(?u8, 1), second);
    try std.testing.expectEqual(@as(i32, 2), regions[0].seed.x);
    try std.testing.expectEqual(@as(i32, 0), regions[0].seed.y);
    try std.testing.expectEqual(@as(u16, 1), region_count);
}
