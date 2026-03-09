const std = @import("std");
const Perspective = @import("Perspective.zig");

pub const Span = struct {
    y: i32,
    left: i32,
    right: i32,
};

pub const StackFrame = struct {
    y: i32,
    right: i32,
    left_up: i32,
    left_down: i32,
};

pub fn stackDepthForHeight(height: u32) usize {
    return @max((@as(usize, height) * 2) / 3, 1);
}

pub fn fillSpan(
    labels: []u8,
    width: u32,
    height: u32,
    seed: Perspective.PixelPoint,
    from: u8,
    to: u8,
) error{ScratchTooSmall}!Span {
    _ = height;

    const x0: usize = std.math.cast(usize, seed.x) orelse return error.ScratchTooSmall;
    const y0: usize = std.math.cast(usize, seed.y) orelse return error.ScratchTooSmall;
    const row = labels[y0 * width .. (y0 + 1) * width];
    if (x0 >= row.len or row[x0] != from) {
        @branchHint(.unlikely);
        return error.ScratchTooSmall;
    }

    std.debug.assert(x0 < width);
    var left: usize = x0;
    var right: usize = x0;

    const VecLen = std.simd.suggestVectorLength(u8) orelse 8;
    const VecU8 = @Vector(VecLen, u8);
    const from_vec: VecU8 = @splat(from);

    while (left >= 4 * VecLen) {
        const start = left - 4 * VecLen;
        const c0: VecU8 = row[start + 0 * VecLen ..][0..VecLen].*;
        const c1: VecU8 = row[start + 1 * VecLen ..][0..VecLen].*;
        const c2: VecU8 = row[start + 2 * VecLen ..][0..VecLen].*;
        const c3: VecU8 = row[start + 3 * VecLen ..][0..VecLen].*;
        if (!@reduce(.And, (c0 == from_vec) & (c1 == from_vec) & (c2 == from_vec) & (c3 == from_vec))) break;
        left = start;
    }
    while (left >= VecLen) {
        const start = left - VecLen;
        const chunk: VecU8 = row[start..][0..VecLen].*;
        if (!@reduce(.And, chunk == from_vec)) {
            var k: usize = VecLen;
            while (k > 0) {
                k -= 1;
                if (row[start + k] != from) {
                    left = start + k + 1;
                    break;
                }
            }
            break;
        }
        left = start;
    }
    while (left > 0 and row[left - 1] == from) left -= 1;

    while (right + 1 + 4 * VecLen <= row.len) {
        const start = right + 1;
        const c0: VecU8 = row[start + 0 * VecLen ..][0..VecLen].*;
        const c1: VecU8 = row[start + 1 * VecLen ..][0..VecLen].*;
        const c2: VecU8 = row[start + 2 * VecLen ..][0..VecLen].*;
        const c3: VecU8 = row[start + 3 * VecLen ..][0..VecLen].*;
        if (!@reduce(.And, (c0 == from_vec) & (c1 == from_vec) & (c2 == from_vec) & (c3 == from_vec))) break;
        right += 4 * VecLen;
    }
    outer_right: while (right + 1 + VecLen <= row.len) {
        const start = right + 1;
        const chunk: VecU8 = row[start..][0..VecLen].*;
        if (!@reduce(.And, chunk == from_vec)) {
            for (0..VecLen) |k| {
                if (row[start + k] != from) {
                    right += k;
                    break :outer_right;
                }
            }
        }
        right += VecLen;
    }
    while (right + 1 < row.len and row[right + 1] == from) right += 1;

    @memset(row[left .. right + 1], to);

    return .{
        .y = seed.y,
        .left = @intCast(left),
        .right = @intCast(right),
    };
}

fn fillSpanWithCallback(
    labels: []u8,
    width: u32,
    height: u32,
    seed: Perspective.PixelPoint,
    from: u8,
    to: u8,
    comptime Context: type,
    comptime on_span: ?fn (*Context, i32, i32, i32) void,
    context: ?*Context,
) error{ScratchTooSmall}!Span {
    const span = try fillSpan(labels, width, height, seed, from, to);

    if (on_span) |callback| {
        callback(context.?, span.y, span.left, span.right);
    }

    return span;
}

pub fn fillFromSeed(
    labels: []u8,
    width: u32,
    height: u32,
    seed: Perspective.PixelPoint,
    from: u8,
    to: u8,
    stack: []StackFrame,
) error{ScratchTooSmall}!u32 {
    return fillFromSeedWithCallback(labels, width, height, seed, from, to, stack, void, null, null);
}

pub fn fillFromSeedWithCallback(
    labels: []u8,
    width: u32,
    height: u32,
    seed: Perspective.PixelPoint,
    from: u8,
    to: u8,
    stack: []StackFrame,
    comptime Context: type,
    comptime on_span: ?fn (*Context, i32, i32, i32) void,
    context: ?*Context,
) error{ScratchTooSmall}!u32 {
    if (stack.len == 0) {
        @branchHint(.unlikely);
        return error.ScratchTooSmall;
    }

    var area: u32 = 0;
    const first_span = try fillSpanWithCallback(labels, width, height, seed, from, to, Context, on_span, context);
    area += @intCast(first_span.right - first_span.left + 1);
    stack[0] = .{
        .y = seed.y,
        .right = first_span.right,
        .left_up = first_span.left,
        .left_down = first_span.left,
    };

    var next_index: usize = 0;
    while (true) {
        const frame = &stack[next_index];

        if (next_index == stack.len - 1) {
            @branchHint(.unlikely);
            break;
        }

        if (frame.y > 0) {
            if (try floodFillCallNext(
                labels,
                width,
                height,
                from,
                to,
                stack,
                next_index,
                -1,
                Context,
                on_span,
                context,
                &area,
            )) |new_index| {
                next_index = new_index;
                continue;
            }
        }

        if (frame.y < height - 1) {
            if (try floodFillCallNext(
                labels,
                width,
                height,
                from,
                to,
                stack,
                next_index,
                1,
                Context,
                on_span,
                context,
                &area,
            )) |new_index| {
                next_index = new_index;
                continue;
            }
        }

        if (next_index > 0) {
            next_index -= 1;
            continue;
        }

        break;
    }

    return area;
}

fn findFirstValue(row: []const u8, start: usize, end: usize, target: u8) ?usize {
    const VecLen = std.simd.suggestVectorLength(u8) orelse 16;
    const VecU8 = @Vector(VecLen, u8);
    const target_vec: VecU8 = @splat(target);
    var i = start;

    while (i + 4 * VecLen <= end) {
        const c0: VecU8 = row[i + 0 * VecLen ..][0..VecLen].*;
        const c1: VecU8 = row[i + 1 * VecLen ..][0..VecLen].*;
        const c2: VecU8 = row[i + 2 * VecLen ..][0..VecLen].*;
        const c3: VecU8 = row[i + 3 * VecLen ..][0..VecLen].*;
        if (@reduce(.Or, (c0 == target_vec) | (c1 == target_vec) | (c2 == target_vec) | (c3 == target_vec))) break;
        i += 4 * VecLen;
    }
    while (i + VecLen <= end) : (i += VecLen) {
        const chunk: VecU8 = row[i..][0..VecLen].*;
        if (@reduce(.Or, chunk == target_vec)) {
            for (0..VecLen) |k| {
                if (row[i + k] == target) return i + k;
            }
        }
    }
    while (i < end) : (i += 1) {
        if (row[i] == target) return i;
    }
    return null;
}

fn floodFillCallNext(
    labels: []u8,
    width: u32,
    height: u32,
    from: u8,
    to: u8,
    stack: []StackFrame,
    frame_index: usize,
    direction: i32,
    comptime Context: type,
    comptime on_span: ?fn (*Context, i32, i32, i32) void,
    context: ?*Context,
    area: *u32,
) error{ScratchTooSmall}!?usize {
    const frame = &stack[frame_index];
    const leftp = if (direction < 0) &frame.left_up else &frame.left_down;
    const row_index: usize = @intCast(frame.y + direction);
    const row = labels[row_index * width .. (row_index + 1) * width];

    const search_start: usize = @intCast(leftp.*);
    const search_end: usize = @intCast(frame.right + 1);
    const found = findFirstValue(row, search_start, search_end, from) orelse {
        leftp.* = @intCast(search_end);
        return null;
    };
    leftp.* = @intCast(found);

    const span = try fillSpanWithCallback(
        labels,
        width,
        height,
        .{
            .x = leftp.*,
            .y = frame.y + direction,
        },
        from,
        to,
        Context,
        on_span,
        context,
    );
    area.* += @intCast(span.right - span.left + 1);
    leftp.* = span.right + 1;

    const next_index = frame_index + 1;
    stack[next_index] = .{
        .y = frame.y + direction,
        .right = span.right,
        .left_down = span.left,
        .left_up = span.left,
    };
    return next_index;
}

test "fillSpan SIMD boundary matches scalar on long uniform row" {
    const width = 100;
    var labels = [_]u8{0xFF} ** width;
    for (10..81) |i| labels[i] = 1;
    const span = try fillSpan(&labels, width, 1, .{ .x = 40, .y = 0 }, 1, 7);
    try std.testing.expectEqual(@as(i32, 10), span.left);
    try std.testing.expectEqual(@as(i32, 80), span.right);
    for (0..10) |i| try std.testing.expectEqual(@as(u8, 0xFF), labels[i]);
    for (10..81) |i| try std.testing.expectEqual(@as(u8, 7), labels[i]);
    for (81..100) |i| try std.testing.expectEqual(@as(u8, 0xFF), labels[i]);
}

test "fillSpan SIMD boundary with seed at VecLen-aligned position" {
    const VecLen = std.simd.suggestVectorLength(u8) orelse 8;
    const width = VecLen * 4;
    var labels = [_]u8{1} ** (VecLen * 4);
    labels[0] = 0;
    labels[VecLen * 4 - 1] = 0;
    const span = try fillSpan(&labels, @intCast(width), 1, .{ .x = @intCast(VecLen), .y = 0 }, 1, 7);
    try std.testing.expectEqual(@as(i32, 1), span.left);
    try std.testing.expectEqual(@as(i32, @intCast(VecLen * 4 - 2)), span.right);
}

test "fillSpan scalar fallback on row shorter than VecLen" {
    const VecLen = std.simd.suggestVectorLength(u8) orelse 8;
    if (VecLen <= 2) return;
    const width = 3;
    var labels = [_]u8{ 1, 1, 1 };
    const span = try fillSpan(&labels, width, 1, .{ .x = 1, .y = 0 }, 1, 7);
    try std.testing.expectEqual(@as(i32, 0), span.left);
    try std.testing.expectEqual(@as(i32, 2), span.right);
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 7 }, &labels);
}

test "fill from seed labels one connected component" {
    var labels = [_]u8{
        1, 1, 9, 0,
        9, 1, 9, 0,
        1, 1, 1, 0,
    };
    var stack: [8]StackFrame = undefined;

    const area = try fillFromSeed(&labels, 4, 3, .{ .x = 0, .y = 0 }, 1, 7, &stack);

    try std.testing.expectEqual(@as(u32, 6), area);
    try std.testing.expectEqualSlices(u8, &.{
        7, 7, 9, 0,
        9, 7, 9, 0,
        7, 7, 7, 0,
    }, &labels);
}

test "stack depth helper matches upstream bound" {
    try std.testing.expectEqual(@as(usize, 1), stackDepthForHeight(0));
    try std.testing.expectEqual(@as(usize, 1), stackDepthForHeight(1));
    try std.testing.expectEqual(@as(usize, 2), stackDepthForHeight(3));
    try std.testing.expectEqual(@as(usize, 4), stackDepthForHeight(6));
    try std.testing.expectEqual(@as(usize, 154), stackDepthForHeight(232));
}

test "tight stack depth handles rotated ring style region" {
    const width = 51;
    const height = 51;
    var labels = [_]u8{0} ** (width * height);
    const center: i32 = 25;

    for (0..height) |y| {
        const yi: i32 = @intCast(y);
        const abs_dy: i32 = @intCast(@abs(yi - center));
        if (abs_dy > 8) continue;
        const dx_outer: i32 = 8 - abs_dy;
        const dx_inner: i32 = 5 - abs_dy;

        const left_outer: usize = @intCast(center - dx_outer);
        const right_outer: usize = @intCast(center + dx_outer);
        for (left_outer..right_outer + 1) |x| {
            labels[y * width + x] = 1;
        }

        if (dx_inner >= 0) {
            const left_inner: usize = @intCast(center - dx_inner);
            const right_inner: usize = @intCast(center + dx_inner);
            for (left_inner..right_inner + 1) |x| {
                labels[y * width + x] = 0;
            }
        }
    }

    var tight_stack: [stackDepthForHeight(height)]StackFrame = undefined;
    var wide_stack: [height * 2]StackFrame = undefined;

    var tight_labels = labels;
    const tight_area = try fillFromSeed(&tight_labels, width, height, .{ .x = center, .y = center - 8 }, 1, 7, &tight_stack);

    var wide_labels = labels;
    const wide_area = try fillFromSeed(&wide_labels, width, height, .{ .x = center, .y = center - 8 }, 1, 7, &wide_stack);

    try std.testing.expectEqual(wide_area, tight_area);
    try std.testing.expectEqualSlices(u8, &wide_labels, &tight_labels);
}
