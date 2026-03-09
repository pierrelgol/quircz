const std = @import("std");
const FloodFill = @import("FloodFill.zig");
const Perspective = @import("Perspective.zig");
const Region = @import("Region.zig");
const Spec = @import("Spec.zig");

const Capstone = @This();

ring_region: u8 = 0,
stone_region: u8 = 0,
corners: [4]Perspective.PixelPoint = @splat(Perspective.PixelPoint.zero),
center: Perspective.PixelPoint = .{},
perspective: Perspective = .{},
grid_index: ?u16 = null,

pub const Match = struct {
    runs: [5]u32,
    x: u32,
    y: u32,
};

fn findNonWhite(row: []const u8, start: usize) usize {
    const VecLen = std.simd.suggestVectorLength(u8) orelse 16;
    const VecU8 = @Vector(VecLen, u8);
    const white_vec: VecU8 = @splat(Region.white);
    var i = start;
    while (i + VecLen <= row.len) : (i += VecLen) {
        const chunk: VecU8 = row[i..][0..VecLen].*;
        if (@reduce(.Or, chunk != white_vec)) {
            for (0..VecLen) |k| {
                if (row[i + k] != Region.white) return i + k;
            }
        }
    }
    while (i < row.len) : (i += 1) {
        if (row[i] != Region.white) return i;
    }
    return row.len;
}

fn findWhite(row: []const u8, start: usize) usize {
    const VecLen = std.simd.suggestVectorLength(u8) orelse 16;
    const VecU8 = @Vector(VecLen, u8);
    const white_vec: VecU8 = @splat(Region.white);
    var i = start;
    while (i + VecLen <= row.len) : (i += VecLen) {
        const chunk: VecU8 = row[i..][0..VecLen].*;
        if (@reduce(.Or, chunk == white_vec)) {
            for (0..VecLen) |k| {
                if (row[i + k] == Region.white) return i + k;
            }
        }
    }
    while (i < row.len) : (i += 1) {
        if (row[i] == Region.white) return i;
    }
    return row.len;
}

pub fn scanFinderRow(
    labels: []const u8,
    width: u32,
    y: u32,
    context: anytype,
    comptime on_match: fn (@TypeOf(context), Match) void,
) void {
    const row = labels[@as(usize, y) * width .. (@as(usize, y) + 1) * width];
    if (row.len == 0) return;

    var run_count: u32 = 0;
    var pb = [5]u32{ 0, 0, 0, 0, 0 };
    var pos: usize = 0;
    var current_is_white: bool = row[0] == Region.white;

    while (true) {
        const end_pos: usize = if (current_is_white)
            findNonWhite(row, pos + 1)
        else
            findWhite(row, pos + 1);

        pb[0..4].* = pb[1..5].*;
        pb[4] = @intCast(end_pos - pos);
        run_count += 1;

        if (!current_is_white and end_pos < row.len and run_count >= 5 and isFinderPattern(pb)) {
            on_match(context, .{
                .runs = pb,
                .x = @intCast(end_pos),
                .y = y,
            });
        }

        if (end_pos >= row.len) break;
        pos = end_pos;
        current_is_white = !current_is_white;
    }
}

pub fn testCandidate(
    labels: []const u8,
    width: u32,
    height: u32,
    regions: []Region,
    runs: [5]u32,
    x: u32,
    y: u32,
) ?struct {
    ring_region: u8,
    stone_region: u8,
} {
    const samples = candidateSamples(runs, x, y) orelse return null;
    const ring_right = Region.labelAt(labels, width, height, samples.ring_right_x, samples.y) orelse return null;
    const stone = Region.labelAt(labels, width, height, samples.stone_x, samples.y) orelse return null;
    const ring_left = Region.labelAt(labels, width, height, samples.ring_left_x, samples.y) orelse return null;

    if (ring_left != ring_right or ring_left == stone) {
        return null;
    }

    const stone_region = Region.byLabel(regions, stone) orelse return null;
    const ring_region = Region.byLabel(regions, ring_left) orelse return null;

    if (stone_region.capstone_index != null or ring_region.capstone_index != null) {
        return null;
    }

    if (!candidateAreaRatioOk(ring_region.area, stone_region.area)) return null;

    return .{
        .ring_region = ring_left,
        .stone_region = stone,
    };
}

pub fn record(
    regions: []Region,
    ring_region: u8,
    stone_region: u8,
    capstone_index: u16,
    labels: []u8,
    width: u32,
    height: u32,
    stack: []FloodFill.StackFrame,
) error{InvalidRegion}!Capstone {
    const stone = Region.byLabel(regions, stone_region) orelse return error.InvalidRegion;
    const ring = Region.byLabel(regions, ring_region) orelse return error.InvalidRegion;

    var capstone = Capstone{
        .ring_region = ring_region,
        .stone_region = stone_region,
        .corners = try ring.findCorners(labels, width, height, stone.seed, stack),
        .grid_index = null,
    };
    capstone.perspective = Perspective.init(capstone.corners, 7.0, 7.0);
    capstone.center = capstone.perspective.map(3.5, 3.5);

    stone.capstone_index = @intCast(capstone_index);
    ring.capstone_index = @intCast(capstone_index);

    return capstone;
}

pub fn rotateForGrid(
    self: *Capstone,
    hypotenuse_origin: Perspective.PixelPoint,
    hypotenuse_delta: Perspective.PixelPoint,
) void {
    var best: usize = 0;
    var best_score: i64 = std.math.maxInt(i64);

    for (self.corners, 0..) |corner, i| {
        const score = @as(i64, corner.x - hypotenuse_origin.x) * -hypotenuse_delta.y +
            @as(i64, corner.y - hypotenuse_origin.y) * hypotenuse_delta.x;
        if (score < best_score) {
            best = i;
            best_score = score;
        }
    }

    var copy: [4]Perspective.PixelPoint = undefined;
    for (0..4) |i| {
        copy[i] = self.corners[(i + best) % 4];
    }

    self.corners = copy;
    self.perspective = Perspective.init(self.corners, 7.0, 7.0);
}

fn isFinderPattern(runs: [5]u32) bool {
    const scale: u32 = 16;
    const avg = (runs[0] + runs[1] + runs[3] + runs[4]) * scale / 4;
    const err = avg * 3 / 4;

    for (runs, Spec.finder_pattern_ratio) |run, expect| {
        const scaled_expect = @as(u32, expect) * avg;
        if (run * scale < scaled_expect - err or run * scale > scaled_expect + err) {
            return false;
        }
    }

    return true;
}

fn candidateSamples(runs: [5]u32, x: u32, y: u32) ?struct {
    ring_right_x: i32,
    stone_x: i32,
    ring_left_x: i32,
    y: i32,
} {
    const span = runs[0] + runs[1] + runs[2] + runs[3] + runs[4];
    if (x < span) return null;

    const sample_y: i32 = @intCast(y);
    const ring_right_x: i32 = @intCast(x - runs[4]);
    const stone_x: i32 = @intCast(ring_right_x - @as(i32, @intCast(runs[3] + runs[2])));
    const ring_left_x: i32 = @intCast(stone_x - @as(i32, @intCast(runs[1] + runs[0])));
    return .{
        .ring_right_x = ring_right_x,
        .stone_x = stone_x,
        .ring_left_x = ring_left_x,
        .y = sample_y,
    };
}

fn candidateAreaRatioOk(ring_area: u32, stone_area: u32) bool {
    const ratio = @as(u32, @intCast(stone_area * 100 / @max(ring_area, 1)));
    return ratio >= 10 and ratio <= 70;
}

test "finder ratio classifier accepts ideal sequence" {
    try std.testing.expect(isFinderPattern(.{ 1, 1, 3, 1, 1 }));
    try std.testing.expect(!isFinderPattern(.{ 1, 1, 2, 1, 1 }));
}

test "finder scan reports a scaled fixture-style sequence" {
    var row: [96]u8 = @splat(Region.white);
    @memset(row[32..40], Region.unlabeled);
    @memset(row[48..72], Region.unlabeled);
    @memset(row[80..88], Region.unlabeled);

    const Context = struct {
        called: bool = false,
        x: u32 = 0,
    };

    const Callback = struct {
        fn onMatch(context: *Context, match: Match) void {
            context.called = true;
            context.x = match.x;
        }
    };

    var context: Context = .{};
    scanFinderRow(&row, row.len, 0, &context, Callback.onMatch);

    try std.testing.expect(context.called);
    try std.testing.expectEqual(@as(u32, 88), context.x);
}

test "candidate rejects mismatched ring regions" {
    const labels = [_]u8{
        0, 0, 0, 0, 0, 0, 0,
        1, 2, 2, 2, 2, 2, 3,
    };
    var regions: [3]Region = .{
        .{ .label = 1, .area = 40 },
        .{ .label = 2, .area = 15 },
        .{ .label = 3, .area = 40 },
    };

    const candidate = testCandidate(&labels, 7, 2, &regions, .{ 1, 1, 3, 1, 1 }, 7, 1);
    try std.testing.expect(candidate == null);
}

test "candidate rejects previously claimed region" {
    const labels = [_]u8{
        0, 0, 0, 0, 0, 0, 0,
        1, 2, 2, 2, 2, 2, 1,
    };
    var regions: [2]Region = .{
        .{ .label = 1, .area = 40, .capstone_index = 0 },
        .{ .label = 2, .area = 15 },
    };

    const candidate = testCandidate(&labels, 7, 2, &regions, .{ 1, 1, 3, 1, 1 }, 7, 1);
    try std.testing.expect(candidate == null);
}

test "candidate rejects ring and stone resolving to same region" {
    const labels = [_]u8{
        0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 1, 1, 1,
    };
    var regions: [1]Region = .{
        .{ .label = 1, .area = 40 },
    };

    const candidate = testCandidate(&labels, 7, 2, &regions, .{ 1, 1, 3, 1, 1 }, 7, 1);
    try std.testing.expect(candidate == null);
}

test "candidate enforces area ratio bounds" {
    const labels = [_]u8{
        0, 0, 0, 0, 0, 0, 0,
        1, 2, 2, 2, 2, 2, 1,
    };

    var low_ratio_regions: [2]Region = .{
        .{ .label = 1, .area = 100 },
        .{ .label = 2, .area = 9 },
    };
    try std.testing.expect(testCandidate(&labels, 7, 2, &low_ratio_regions, .{ 1, 1, 3, 1, 1 }, 7, 1) == null);

    var high_ratio_regions: [2]Region = .{
        .{ .label = 1, .area = 20 },
        .{ .label = 2, .area = 15 },
    };
    try std.testing.expect(testCandidate(&labels, 7, 2, &high_ratio_regions, .{ 1, 1, 3, 1, 1 }, 7, 1) == null);
}
