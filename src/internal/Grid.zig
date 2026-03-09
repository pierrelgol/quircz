const std = @import("std");
const Capstone = @import("Capstone.zig");
const FloodFill = @import("FloodFill.zig");
const Perspective = @import("Perspective.zig");
const Region = @import("Region.zig");
const Spec = @import("Spec.zig");
const VersionDb = @import("VersionDb.zig");

const Grid = @This();

capstones: [3]u16 = @splat(0),
alignment_region: ?u8 = null,
alignment_corner: Perspective.PixelPoint = .{},
timing_pattern_endpoints: [3]Perspective.PixelPoint = @splat(Perspective.PixelPoint.zero),
grid_size: u16 = 0,
perspective: Perspective = .{},

const Neighbour = struct {
    index: u16,
    distance: Perspective.Scalar,
};

const column_coeffs = [_]usize{ 0, 3, 6 };

const JiggleContext = struct {
    grid: *const Grid,
    kernel: *FitnessKernel,
};

const FitnessState = struct {
    grid: *const Grid,
    perspective: Perspective,
    labels: []const u8,
    width: u32,
    height: u32,
};

const FitnessKernel = struct {
    const axis_offsets = [_]Perspective.Scalar{ 0.3, 0.5, 0.7 };
    const CellOffset = struct {
        dx: i8,
        dy: i8,
    };
    const ring_1_offsets = [_]CellOffset{
        .{ .dx = -1, .dy = -1 },
        .{ .dx = -1, .dy = 1 },
        .{ .dx = 1, .dy = -1 },
        .{ .dx = 1, .dy = 1 },
        .{ .dx = 0, .dy = -1 },
        .{ .dx = -1, .dy = 0 },
        .{ .dx = 1, .dy = 0 },
        .{ .dx = 0, .dy = 1 },
    };
    const ring_2_offsets = [_]CellOffset{
        .{ .dx = -2, .dy = -2 },
        .{ .dx = -2, .dy = 2 },
        .{ .dx = 2, .dy = -2 },
        .{ .dx = 2, .dy = 2 },
        .{ .dx = -1, .dy = -2 },
        .{ .dx = -2, .dy = 1 },
        .{ .dx = 2, .dy = -1 },
        .{ .dx = 1, .dy = 2 },
        .{ .dx = 0, .dy = -2 },
        .{ .dx = -2, .dy = 0 },
        .{ .dx = 2, .dy = 0 },
        .{ .dx = 0, .dy = 2 },
        .{ .dx = 1, .dy = -2 },
        .{ .dx = -2, .dy = -1 },
        .{ .dx = 2, .dy = 1 },
        .{ .dx = -1, .dy = 2 },
    };
    const ring_3_offsets = [_]CellOffset{
        .{ .dx = -3, .dy = -3 },
        .{ .dx = -3, .dy = 3 },
        .{ .dx = 3, .dy = -3 },
        .{ .dx = 3, .dy = 3 },
        .{ .dx = -2, .dy = -3 },
        .{ .dx = -3, .dy = 2 },
        .{ .dx = 3, .dy = -2 },
        .{ .dx = 2, .dy = 3 },
        .{ .dx = -1, .dy = -3 },
        .{ .dx = -3, .dy = 1 },
        .{ .dx = 3, .dy = -1 },
        .{ .dx = 1, .dy = 3 },
        .{ .dx = 0, .dy = -3 },
        .{ .dx = -3, .dy = 0 },
        .{ .dx = 3, .dy = 0 },
        .{ .dx = 0, .dy = 3 },
        .{ .dx = 1, .dy = -3 },
        .{ .dx = -3, .dy = -1 },
        .{ .dx = 3, .dy = 1 },
        .{ .dx = -1, .dy = 3 },
        .{ .dx = 2, .dy = -3 },
        .{ .dx = -3, .dy = -2 },
        .{ .dx = 3, .dy = 2 },
        .{ .dx = -2, .dy = 3 },
    };
    const vec_width = 4;
    const FVec = @Vector(vec_width, f32);
    const ColumnTerms = struct { x_num: FVec, y_num: FVec, den_num: FVec };
    const RowTerms = struct { x_term: FVec, y_term: FVec, den_term: FVec };

    labels: []const u8,
    width_u32: u32,
    height_u32: u32,
    row_stride: usize,
    column_terms: [Spec.max_grid_size]ColumnTerms,
    row_terms: [Spec.max_grid_size]RowTerms,

    fn initColumns(self: *FitnessKernel, grid_size: u16, coeffs: [Spec.perspective_parameter_count]Perspective.Scalar) void {
        var x_acc: FVec = .{
            @floatCast(coeffs[0] * 0.3), @floatCast(coeffs[0] * 0.5), @floatCast(coeffs[0] * 0.7), 0,
        };
        var y_acc: FVec = .{
            @floatCast(coeffs[3] * 0.3), @floatCast(coeffs[3] * 0.5), @floatCast(coeffs[3] * 0.7), 0,
        };
        var d_acc: FVec = .{
            @floatCast(coeffs[6] * 0.3), @floatCast(coeffs[6] * 0.5), @floatCast(coeffs[6] * 0.7), 1,
        };
        const x_step: FVec = .{ @floatCast(coeffs[0]), @floatCast(coeffs[0]), @floatCast(coeffs[0]), 0 };
        const y_step: FVec = .{ @floatCast(coeffs[3]), @floatCast(coeffs[3]), @floatCast(coeffs[3]), 0 };
        const d_step: FVec = .{ @floatCast(coeffs[6]), @floatCast(coeffs[6]), @floatCast(coeffs[6]), 0 };
        for (0..grid_size) |x| {
            self.column_terms[x] = .{ .x_num = x_acc, .y_num = y_acc, .den_num = d_acc };
            x_acc += x_step;
            y_acc += y_step;
            d_acc += d_step;
        }
    }

    fn initRows(self: *FitnessKernel, grid_size: u16, coeffs: [Spec.perspective_parameter_count]Perspective.Scalar) void {
        var x_acc: FVec = .{
            @floatCast(coeffs[1] * 0.3 + coeffs[2]), @floatCast(coeffs[1] * 0.5 + coeffs[2]), @floatCast(coeffs[1] * 0.7 + coeffs[2]), 0,
        };
        var y_acc: FVec = .{
            @floatCast(coeffs[4] * 0.3 + coeffs[5]), @floatCast(coeffs[4] * 0.5 + coeffs[5]), @floatCast(coeffs[4] * 0.7 + coeffs[5]), 0,
        };
        var d_acc: FVec = .{
            @floatCast(coeffs[7] * 0.3 + 1.0), @floatCast(coeffs[7] * 0.5 + 1.0), @floatCast(coeffs[7] * 0.7 + 1.0), 0,
        };
        const x_step: FVec = .{ @floatCast(coeffs[1]), @floatCast(coeffs[1]), @floatCast(coeffs[1]), 0 };
        const y_step: FVec = .{ @floatCast(coeffs[4]), @floatCast(coeffs[4]), @floatCast(coeffs[4]), 0 };
        const d_step: FVec = .{ @floatCast(coeffs[7]), @floatCast(coeffs[7]), @floatCast(coeffs[7]), 0 };
        for (0..grid_size) |y| {
            self.row_terms[y] = .{ .x_term = x_acc, .y_term = y_acc, .den_term = d_acc };
            x_acc += x_step;
            y_acc += y_step;
            d_acc += d_step;
        }
    }

    fn init(
        self: *FitnessKernel,
        grid_size: u16,
        perspective: Perspective,
        labels: []const u8,
        width: u32,
        height: u32,
    ) void {
        self.* = .{
            .labels = labels,
            .width_u32 = width,
            .height_u32 = height,
            .row_stride = width,
            .column_terms = undefined,
            .row_terms = undefined,
        };
        self.initColumns(grid_size, perspective.coeffs);
        self.initRows(grid_size, perspective.coeffs);
    }

    fn computeScore(self: *const FitnessKernel, column: ColumnTerms, row: RowTerms) i32 {
        const magic: FVec = @splat(12582912.0);
        var score: i32 = 0;
        inline for (0..axis_offsets.len) |row_index| {
            const row_x: FVec = @splat(row.x_term[row_index]);
            const row_y: FVec = @splat(row.y_term[row_index]);
            const row_den: FVec = @splat(row.den_term[row_index]);
            const den_inv = @as(FVec, @splat(1.0)) / (column.den_num + row_den);
            const px_vec = (column.x_num + row_x) * den_inv;
            const py_vec = (column.y_num + row_y) * den_inv;
            const px_rounded = (px_vec + magic) - magic;
            const py_rounded = (py_vec + magic) - magic;
            inline for (0..axis_offsets.len) |col_index| {
                score += self.sampleScore(
                    @intFromFloat(px_rounded[col_index]),
                    @intFromFloat(py_rounded[col_index]),
                );
            }
        }
        return score;
    }

    fn cell(self: *const FitnessKernel, x: u16, y: u16) i32 {
        return self.computeScore(self.column_terms[x], self.row_terms[y]);
    }

    fn ring(self: *const FitnessKernel, cx: u16, cy: u16, comptime radius: u16) i32 {
        const span = radius * 2 + 1;
        var cols: [span]ColumnTerms = undefined;
        var rows: [span]RowTerms = undefined;
        const base_x = @as(usize, cx) - radius;
        const base_y = @as(usize, cy) - radius;
        inline for (0..span) |k| {
            cols[k] = self.column_terms[base_x + k];
            rows[k] = self.row_terms[base_y + k];
        }
        const offsets: []const CellOffset = comptime switch (radius) {
            1 => &ring_1_offsets,
            2 => &ring_2_offsets,
            3 => &ring_3_offsets,
            else => @compileError("unsupported ring radius"),
        };
        var score: i32 = 0;
        inline for (offsets) |offset| {
            const col_k: usize = @intCast(@as(i32, offset.dx) + @as(i32, radius));
            const row_k: usize = @intCast(@as(i32, offset.dy) + @as(i32, radius));
            score += self.computeScore(cols[col_k], rows[row_k]);
        }
        return score;
    }

    fn alignmentPattern(self: *const FitnessKernel, cx: u16, cy: u16) i32 {
        return self.cell(cx, cy) -
            self.ring(cx, cy, 1) +
            self.ring(cx, cy, 2);
    }

    fn capstone(self: *const FitnessKernel, x: u16, y: u16) i32 {
        const cx = x + 3;
        const cy = y + 3;

        return self.cell(cx, cy) +
            self.ring(cx, cy, 1) -
            self.ring(cx, cy, 2) +
            self.ring(cx, cy, 3);
    }

    fn all(self: *const FitnessKernel, grid: *const Grid) i32 {
        var score: i32 = 0;
        const version = VersionDb.versionForGridSize(grid.grid_size) catch null;

        var i: u16 = 0;
        while (i < grid.grid_size - 14) : (i += 1) {
            const expect: i32 = if ((i & 1) != 0) 1 else -1;
            score += self.cell(i + 7, 6) * expect;
            score += self.cell(6, i + 7) * expect;
        }

        score += self.capstone(0, 0);
        score += self.capstone(grid.grid_size - 7, 0);
        score += self.capstone(0, grid.grid_size - 7);

        if (version) |v| {
            const alignment_positions = VersionDb.versions[v].alignmentPositions();

            if (alignment_positions.len > 0) {
                if (alignment_positions.len > 2) {
                    for (alignment_positions[1 .. alignment_positions.len - 1]) |pos| {
                        score += self.alignmentPattern(6, pos);
                        score += self.alignmentPattern(pos, 6);
                    }
                }

                for (alignment_positions[1..]) |y| {
                    for (alignment_positions[1..]) |x| {
                        score += self.alignmentPattern(x, y);
                    }
                }
            }
        }

        return score;
    }

    inline fn sampleScore(self: *const FitnessKernel, px: i32, py: i32) i32 {
        const px_u: u32 = @bitCast(px);
        const py_u: u32 = @bitCast(py);
        if (px_u >= self.width_u32 or py_u >= self.height_u32) {
            @branchHint(.unlikely);
            return 0;
        }

        const pixel_index = @as(usize, py_u) * self.row_stride + @as(usize, px_u);
        const white = @as(i32, @intFromBool(self.labels[pixel_index] == Region.white));
        return 1 - (white << 1);
    }
};

pub fn groupCapstones(
    capstones: []Capstone,
    capstone_count: usize,
    grids: []Grid,
    grid_count: *u16,
) error{TooManyGrids}!void {
    for (0..capstone_count) |index| {
        try testGrouping(capstones, index, grids, grid_count);
    }
}

pub fn testGrouping(
    capstones: []Capstone,
    index: usize,
    grids: []Grid,
    grid_count: *u16,
) error{TooManyGrids}!void {
    var hlist: [32]Neighbour = undefined;
    var vlist: [32]Neighbour = undefined;
    var hcount: usize = 0;
    var vcount: usize = 0;

    const c1 = &capstones[index];

    for (capstones[0..@min(capstones.len, 32)], 0..) |*c2, j| {
        if (j == index) continue;

        const uv = c1.perspective.unmap(c2.center);
        const u = @abs(uv.x - 3.5);
        const v = @abs(uv.y - 3.5);

        if (u < 0.2 * v and hcount < hlist.len) {
            hlist[hcount] = .{ .index = @intCast(j), .distance = v };
            hcount += 1;
        }

        if (v < 0.2 * u and vcount < vlist.len) {
            vlist[vcount] = .{ .index = @intCast(j), .distance = u };
            vcount += 1;
        }
    }

    if (hcount == 0 or vcount == 0) return;

    for (hlist[0..hcount]) |hn| {
        for (vlist[0..vcount]) |vn| {
            const squareness = @abs(1.0 - hn.distance / vn.distance);
            if (squareness >= 0.2) continue;
            if (grid_count.* >= grids.len) return error.TooManyGrids;

            grids[grid_count.*] = record(capstones, hn.index, @intCast(index), vn.index) catch continue;
            const current_grid = grid_count.*;
            grid_count.* += 1;

            capstones[hn.index].grid_index = current_grid;
            capstones[index].grid_index = current_grid;
            capstones[vn.index].grid_index = current_grid;
        }
    }
}

pub fn record(
    capstones: []Capstone,
    a_in: u16,
    b: u16,
    c_in: u16,
) error{InvalidGrid}!Grid {
    var a = a_in;
    var c = c_in;
    const h0 = capstones[a].center;
    var hd = Perspective.PixelPoint{
        .x = capstones[c].center.x - capstones[a].center.x,
        .y = capstones[c].center.y - capstones[a].center.y,
    };

    if (@as(i64, capstones[b].center.x - h0.x) * -hd.y +
        @as(i64, capstones[b].center.y - h0.y) * hd.x > 0)
    {
        const swap = a;
        a = c;
        c = swap;
        hd.x = -hd.x;
        hd.y = -hd.y;
    }

    var grid = Grid{
        .capstones = .{ a, b, c },
        .alignment_region = null,
    };

    for (grid.capstones) |capstone_index| {
        capstones[capstone_index].rotateForGrid(h0, hd);
    }

    grid.measureSize(capstones);
    grid.alignment_corner = lineIntersect(
        capstones[a].corners[0],
        capstones[a].corners[1],
        capstones[c].corners[0],
        capstones[c].corners[3],
    ) orelse return error.InvalidGrid;

    grid.timing_pattern_endpoints = .{
        capstones[a].corners[0],
        capstones[b].corners[0],
        capstones[c].corners[0],
    };

    return grid;
}

pub fn measureSize(self: *Grid, capstones: []const Capstone) void {
    const a = capstones[self.capstones[0]];
    const b = capstones[self.capstones[1]];
    const c = capstones[self.capstones[2]];

    const ab = segmentLength(b.corners[0], a.corners[3]);
    const capstone_ab_size = (segmentLength(b.corners[0], b.corners[3]) + segmentLength(a.corners[0], a.corners[3])) / 2.0;
    const ver_grid = 7.0 * ab / capstone_ab_size;

    const bc = segmentLength(b.corners[0], c.corners[1]);
    const capstone_bc_size = (segmentLength(b.corners[0], b.corners[1]) + segmentLength(c.corners[0], c.corners[1])) / 2.0;
    const hor_grid = 7.0 * bc / capstone_bc_size;

    const estimate = (ver_grid + hor_grid) * 0.5;
    const version = @as(i32, @intFromFloat((estimate - 15.0) * 0.25));
    self.grid_size = @intCast(4 * version + 17);
}

pub fn findAlignmentPattern(
    self: *Grid,
    capstones: []const Capstone,
    regions: []const Region,
    labels: []u8,
    width: u32,
    height: u32,
    stack: []FloodFill.StackFrame,
) void {
    if (self.grid_size <= 21) return;

    const c0 = capstones[self.capstones[0]];
    const c2 = capstones[self.capstones[2]];

    var probe = self.alignment_corner;

    const uv0 = c0.perspective.unmap(probe);
    const a = c0.perspective.map(uv0.x, uv0.y + 1.0);

    const uv2 = c2.perspective.unmap(probe);
    const c = c2.perspective.map(uv2.x + 1.0, uv2.y);

    const size_estimate = @abs((a.x - probe.x) * -(c.y - probe.y) + (a.y - probe.y) * (c.x - probe.x));

    var step_size: i32 = 1;
    var dir: usize = 0;
    const dx_map = [_]i32{ 1, 0, -1, 0 };
    const dy_map = [_]i32{ 0, -1, 0, 1 };

    while (step_size * step_size < size_estimate * 100) {
        for (0..@intCast(step_size)) |_| {
            const label = Region.labelAt(labels, width, height, probe.x, probe.y);
            if (label) |found_label| {
                if (Region.byLabelConst(regions, found_label)) |region| {
                    if (region.area >= @as(u32, @intCast(@divFloor(size_estimate, 2))) and
                        region.area <= @as(u32, @intCast(size_estimate * 2)))
                    {
                        self.alignment_region = found_label;
                        self.alignment_corner = region.seed;
                        self.alignment_corner = findLeftmostToLine(labels, width, height, region.seed, found_label, .{
                            .x = capstones[self.capstones[2]].center.x - capstones[self.capstones[0]].center.x,
                            .y = capstones[self.capstones[2]].center.y - capstones[self.capstones[0]].center.y,
                        }, stack) orelse region.seed;
                        return;
                    }
                }
            }

            probe.x += dx_map[dir];
            probe.y += dy_map[dir];
        }

        dir = (dir + 1) % 4;
        if ((dir & 1) == 0) step_size += 1;
    }
}

pub fn setupPerspective(
    self: *Grid,
    capstones: []const Capstone,
    labels: []const u8,
    width: u32,
    height: u32,
) void {
    const rect: Perspective.Rectangle = .{
        capstones[self.capstones[1]].corners[0],
        capstones[self.capstones[2]].corners[0],
        self.alignment_corner,
        capstones[self.capstones[0]].corners[0],
    };
    self.perspective = Perspective.init(rect, @floatFromInt(self.grid_size - 7), @floatFromInt(self.grid_size - 7));

    var kernel: FitnessKernel = undefined;
    kernel.labels = labels;
    kernel.width_u32 = width;
    kernel.height_u32 = height;
    kernel.row_stride = width;
    self.perspective.jiggleInformed(JiggleContext{
        .grid = self,
        .kernel = &kernel,
    }, fitnessForPerspectiveInformed);
}

pub fn fitnessAll(
    self: *const Grid,
    labels: []const u8,
    width: u32,
    height: u32,
) i32 {
    return self.fitnessAllForPerspective(self.perspective, labels, width, height);
}

fn fitnessAllForPerspective(
    self: *const Grid,
    perspective: Perspective,
    labels: []const u8,
    width: u32,
    height: u32,
) i32 {
    var kernel: FitnessKernel = undefined;
    kernel.init(self.grid_size, perspective, labels, width, height);
    return kernel.all(self);
}

pub fn validationScore(
    self: *const Grid,
    labels: []const u8,
    width: u32,
    height: u32,
) i32 {
    return self.fitnessAll(labels, width, height);
}

fn fitnessCellFast(
    perspective: Perspective,
    labels: []const u8,
    width: u32,
    height: u32,
    x: u16,
    y: u16,
) i32 {
    var kernel: FitnessKernel = undefined;
    kernel.init(@max(x, y) + 1, perspective, labels, width, height);
    return kernel.cell(x, y);
}

fn fitnessAllWith(
    state: FitnessState,
    comptime cellScoreFn: fn (FitnessState, u16, u16) i32,
) i32 {
    var score: i32 = 0;
    const version = VersionDb.versionForGridSize(state.grid.grid_size) catch null;

    var i: u16 = 0;
    while (i < state.grid.grid_size - 14) : (i += 1) {
        const expect: i32 = if ((i & 1) != 0) 1 else -1;
        score += cellScoreFn(state, i + 7, 6) * expect;
        score += cellScoreFn(state, 6, i + 7) * expect;
    }

    score += fitnessCapstoneWith(state, 0, 0, cellScoreFn);
    score += fitnessCapstoneWith(state, state.grid.grid_size - 7, 0, cellScoreFn);
    score += fitnessCapstoneWith(state, 0, state.grid.grid_size - 7, cellScoreFn);

    if (version) |v| {
        const alignment_positions = VersionDb.versions[v].alignmentPositions();

        if (alignment_positions.len > 0) {
            if (alignment_positions.len > 2) {
                for (alignment_positions[1 .. alignment_positions.len - 1]) |pos| {
                    score += fitnessAlignmentPatternWith(state, 6, pos, cellScoreFn);
                    score += fitnessAlignmentPatternWith(state, pos, 6, cellScoreFn);
                }
            }

            for (alignment_positions[1..]) |y| {
                for (alignment_positions[1..]) |x| {
                    score += fitnessAlignmentPatternWith(state, x, y, cellScoreFn);
                }
            }
        }
    }

    return score;
}

fn fitnessRingWith(
    state: FitnessState,
    cx: u16,
    cy: u16,
    radius: u16,
    comptime cellScoreFn: fn (FitnessState, u16, u16) i32,
) i32 {
    var score: i32 = 0;

    for (0..radius * 2) |i| {
        const offset: u16 = @intCast(i);
        score += cellScoreFn(state, cx - radius + offset, cy - radius);
        score += cellScoreFn(state, cx - radius, cy + radius - offset);
        score += cellScoreFn(state, cx + radius, cy - radius + offset);
        score += cellScoreFn(state, cx + radius - offset, cy + radius);
    }

    return score;
}
fn fitnessAlignmentPatternWith(
    state: FitnessState,
    cx: u16,
    cy: u16,
    comptime cellScoreFn: fn (FitnessState, u16, u16) i32,
) i32 {
    return cellScoreFn(state, cx, cy) -
        fitnessRingWith(state, cx, cy, 1, cellScoreFn) +
        fitnessRingWith(state, cx, cy, 2, cellScoreFn);
}

fn fitnessCapstoneWith(
    state: FitnessState,
    x: u16,
    y: u16,
    comptime cellScoreFn: fn (FitnessState, u16, u16) i32,
) i32 {
    const cx = x + 3;
    const cy = y + 3;

    return cellScoreFn(state, cx, cy) +
        fitnessRingWith(state, cx, cy, 1, cellScoreFn) -
        fitnessRingWith(state, cx, cy, 2, cellScoreFn) +
        fitnessRingWith(state, cx, cy, 3, cellScoreFn);
}

fn fitnessForPerspectiveInformed(context: JiggleContext, perspective: Perspective, coeff_index: usize) i32 {
    const is_column_coeff = for (column_coeffs) |c| {
        if (c == coeff_index) break true;
    } else false;

    if (coeff_index >= Spec.perspective_parameter_count) {
        context.kernel.initColumns(context.grid.grid_size, perspective.coeffs);
        context.kernel.initRows(context.grid.grid_size, perspective.coeffs);
    } else if (is_column_coeff) {
        context.kernel.initColumns(context.grid.grid_size, perspective.coeffs);
    } else {
        context.kernel.initRows(context.grid.grid_size, perspective.coeffs);
    }
    return context.kernel.all(context.grid);
}

fn fitnessAllReference(
    grid: *const Grid,
    perspective: Perspective,
    labels: []const u8,
    width: u32,
    height: u32,
) i32 {
    return fitnessAllWith(.{
        .grid = grid,
        .perspective = perspective,
        .labels = labels,
        .width = width,
        .height = height,
    }, referenceFitnessCell);
}

fn referenceFitnessCell(state: FitnessState, x: u16, y: u16) i32 {
    var score: i32 = 0;
    const offsets = [_]Perspective.Scalar{ 0.3, 0.5, 0.7 };

    for (offsets) |vy| {
        for (offsets) |ux| {
            const p = state.perspective.map(
                @as(Perspective.Scalar, @floatFromInt(x)) + ux,
                @as(Perspective.Scalar, @floatFromInt(y)) + vy,
            );
            if (p.y < 0 or p.y >= state.height or p.x < 0 or p.x >= state.width) continue;

            if (state.labels[@as(usize, @intCast(p.y)) * state.width + @as(usize, @intCast(p.x))] != Region.white) {
                score += 1;
            } else {
                score -= 1;
            }
        }
    }

    return score;
}

fn lineIntersect(
    p0: Perspective.PixelPoint,
    p1: Perspective.PixelPoint,
    q0: Perspective.PixelPoint,
    q1: Perspective.PixelPoint,
) ?Perspective.PixelPoint {
    const a = -(p1.y - p0.y);
    const b = p1.x - p0.x;
    const c = -(q1.y - q0.y);
    const d = q1.x - q0.x;
    const e = a * p1.x + b * p1.y;
    const f = c * q1.x + d * q1.y;
    const det = a * d - b * c;
    if (det == 0) return null;

    return .{
        .x = @divTrunc(d * e - b * f, det),
        .y = @divTrunc(-c * e + a * f, det),
    };
}

fn segmentLength(a: Perspective.PixelPoint, b: Perspective.PixelPoint) Perspective.Scalar {
    const x: Perspective.Scalar = @floatFromInt(@abs(a.x - b.x) + 1);
    const y: Perspective.Scalar = @floatFromInt(@abs(a.y - b.y) + 1);
    return @sqrt(x * x + y * y);
}

pub fn findLeftmostToLine(
    labels: []u8,
    width: u32,
    height: u32,
    seed: Perspective.PixelPoint,
    label: u8,
    reference: Perspective.PixelPoint,
    stack: []FloodFill.StackFrame,
) ?Perspective.PixelPoint {
    var best = seed;
    var best_score: i64 = -@as(i64, reference.y) * seed.x + @as(i64, reference.x) * seed.y;
    var context = LeftmostContext{
        .reference = reference,
        .best = &best,
        .best_score = &best_score,
    };

    _ = FloodFill.fillFromSeedWithCallback(
        labels,
        width,
        height,
        seed,
        label,
        Region.unlabeled,
        stack,
        LeftmostContext,
        LeftmostContext.onSpan,
        &context,
    ) catch return null;
    _ = FloodFill.fillFromSeed(
        labels,
        width,
        height,
        seed,
        Region.unlabeled,
        label,
        stack,
    ) catch return null;

    return best;
}

const LeftmostContext = struct {
    reference: Perspective.PixelPoint,
    best: *Perspective.PixelPoint,
    best_score: *i64,

    fn onSpan(self: *LeftmostContext, y: i32, left: i32, right: i32) void {
        const xs = [_]i32{ left, right };
        for (xs) |x| {
            const score = -@as(i64, self.reference.y) * x + @as(i64, self.reference.x) * y;
            if (score < self.best_score.*) {
                self.best_score.* = score;
                self.best.* = .{ .x = x, .y = y };
            }
        }
    }
};

test "validation score is positive on a simple timing pattern" {
    var labels: [21 * 21]u8 = @splat(Region.white);
    for (0..7) |i| {
        labels[3 * 21 + i] = Region.unlabeled;
        labels[i * 21 + 3] = Region.unlabeled;
    }
    for (0..7) |i| {
        labels[3 * 21 + (14 + i)] = Region.unlabeled;
        labels[(14 + i) * 21 + 3] = Region.unlabeled;
    }

    var grid = Grid{
        .grid_size = 21,
        .perspective = Perspective.init(.{
            .{ .x = 0, .y = 0 },
            .{ .x = 20, .y = 0 },
            .{ .x = 20, .y = 20 },
            .{ .x = 0, .y = 20 },
        }, 20.0, 20.0),
        .alignment_corner = .{ .x = 20, .y = 20 },
    };

    try std.testing.expect(grid.validationScore(&labels, 21, 21) != 0);
}

test "alignment search is a no-op for version 1 sized grids" {
    const capstones = [_]Capstone{
        .{}, .{}, .{},
    };
    const regions = [_]Region{};
    var labels = [_]u8{};
    var stack: [1]FloodFill.StackFrame = undefined;

    var grid = Grid{
        .capstones = .{ 0, 1, 2 },
        .grid_size = 21,
        .alignment_corner = .{ .x = 11, .y = 11 },
    };

    grid.findAlignmentPattern(&capstones, &regions, &labels, 0, 0, &stack);

    try std.testing.expectEqual(@as(?u8, null), grid.alignment_region);
    try std.testing.expectEqual(Perspective.PixelPoint{ .x = 11, .y = 11 }, grid.alignment_corner);
}

test "validation score drops for perturbed perspective" {
    var labels: [21 * 21]u8 = @splat(Region.white);
    for (0..7) |i| {
        labels[3 * 21 + i] = Region.unlabeled;
        labels[i * 21 + 3] = Region.unlabeled;
    }
    for (0..7) |i| {
        labels[3 * 21 + (14 + i)] = Region.unlabeled;
        labels[(14 + i) * 21 + 3] = Region.unlabeled;
    }

    const good = Grid{
        .grid_size = 21,
        .perspective = Perspective.init(.{
            .{ .x = 0, .y = 0 },
            .{ .x = 20, .y = 0 },
            .{ .x = 20, .y = 20 },
            .{ .x = 0, .y = 20 },
        }, 20.0, 20.0),
        .alignment_corner = .{ .x = 20, .y = 20 },
    };

    const bad = Grid{
        .grid_size = 21,
        .perspective = Perspective.init(.{
            .{ .x = 2, .y = 0 },
            .{ .x = 20, .y = 1 },
            .{ .x = 19, .y = 20 },
            .{ .x = 0, .y = 18 },
        }, 20.0, 20.0),
        .alignment_corner = .{ .x = 20, .y = 20 },
    };

    try std.testing.expect(good.validationScore(&labels, 21, 21) > bad.validationScore(&labels, 21, 21));
}

test "optimized fitnessCell matches reference implementation" {
    var labels: [21 * 21]u8 = @splat(Region.white);
    for (0..labels.len) |i| {
        if ((i % 3) == 0 or (i % 7) == 0) labels[i] = Region.unlabeled;
    }

    const perspectives = [_]Perspective{
        Perspective.init(.{
            .{ .x = 0, .y = 0 },
            .{ .x = 20, .y = 0 },
            .{ .x = 20, .y = 20 },
            .{ .x = 0, .y = 20 },
        }, 20.0, 20.0),
        Perspective.init(.{
            .{ .x = 2, .y = 1 },
            .{ .x = 20, .y = 0 },
            .{ .x = 19, .y = 20 },
            .{ .x = 0, .y = 18 },
        }, 20.0, 20.0),
    };

    const grid = Grid{
        .grid_size = 21,
        .perspective = perspectives[0],
        .alignment_corner = .{ .x = 20, .y = 20 },
    };

    for (perspectives) |perspective| {
        for ([_]u16{ 0, 1, 6, 10, 13, 20 }) |y| {
            for ([_]u16{ 0, 2, 6, 9, 14, 20 }) |x| {
                try std.testing.expectEqual(
                    referenceFitnessCell(.{
                        .grid = &grid,
                        .perspective = perspective,
                        .labels = &labels,
                        .width = 21,
                        .height = 21,
                    }, x, y),
                    fitnessCellFast(perspective, &labels, 21, 21, x, y),
                );
            }
        }
    }
}

test "fitness kernel cell matches optimized and reference paths" {
    var labels: [21 * 21]u8 = @splat(Region.white);
    for (0..labels.len) |i| {
        if ((i % 5) == 0 or (i % 11) == 0) labels[i] = Region.unlabeled;
    }

    const perspective = Perspective.init(.{
        .{ .x = 2, .y = 1 },
        .{ .x = 20, .y = 0 },
        .{ .x = 19, .y = 20 },
        .{ .x = 0, .y = 18 },
    }, 20.0, 20.0);
    var kernel: FitnessKernel = undefined;
    kernel.init(21, perspective, &labels, 21, 21);
    const grid = Grid{
        .grid_size = 21,
        .perspective = perspective,
        .alignment_corner = .{ .x = 20, .y = 20 },
    };

    for ([_]u16{ 0, 1, 6, 10, 13, 20 }) |y| {
        for ([_]u16{ 0, 2, 6, 9, 14, 20 }) |x| {
            const expected = referenceFitnessCell(.{
                .grid = &grid,
                .perspective = perspective,
                .labels = &labels,
                .width = 21,
                .height = 21,
            }, x, y);
            try std.testing.expectEqual(expected, kernel.cell(x, y));
            try std.testing.expectEqual(expected, fitnessCellFast(perspective, &labels, 21, 21, x, y));
        }
    }
}

test "optimized fitnessCell matches reference with out-of-bounds samples" {
    var labels: [21 * 21]u8 = @splat(Region.white);
    labels[0] = Region.unlabeled;
    labels[20] = Region.unlabeled;
    labels[20 * 21] = Region.unlabeled;
    labels[20 * 21 + 20] = Region.unlabeled;

    const perspective = Perspective.init(.{
        .{ .x = -5, .y = -3 },
        .{ .x = 22, .y = 1 },
        .{ .x = 25, .y = 24 },
        .{ .x = -2, .y = 19 },
    }, 20.0, 20.0);
    const grid = Grid{
        .grid_size = 21,
        .perspective = perspective,
        .alignment_corner = .{ .x = 20, .y = 20 },
    };

    for ([_]u16{ 0, 1, 10, 19, 20 }) |y| {
        for ([_]u16{ 0, 1, 10, 19, 20 }) |x| {
            try std.testing.expectEqual(
                referenceFitnessCell(.{
                    .grid = &grid,
                    .perspective = perspective,
                    .labels = &labels,
                    .width = 21,
                    .height = 21,
                }, x, y),
                fitnessCellFast(perspective, &labels, 21, 21, x, y),
            );
        }
    }
}

test "optimized validation score matches reference implementation" {
    var labels: [21 * 21]u8 = @splat(Region.white);
    for (0..7) |i| {
        labels[3 * 21 + i] = Region.unlabeled;
        labels[i * 21 + 3] = Region.unlabeled;
    }
    for (0..7) |i| {
        labels[3 * 21 + (14 + i)] = Region.unlabeled;
        labels[(14 + i) * 21 + 3] = Region.unlabeled;
    }

    const grid = Grid{
        .grid_size = 21,
        .perspective = Perspective.init(.{
            .{ .x = 1, .y = 0 },
            .{ .x = 20, .y = 1 },
            .{ .x = 19, .y = 20 },
            .{ .x = 0, .y = 19 },
        }, 20.0, 20.0),
        .alignment_corner = .{ .x = 20, .y = 20 },
    };

    try std.testing.expectEqual(
        fitnessAllReference(&grid, grid.perspective, &labels, 21, 21),
        grid.validationScore(&labels, 21, 21),
    );
}

test "fitness kernel all matches reference on skewed out-of-bounds case" {
    var labels: [21 * 21]u8 = @splat(Region.white);
    for (0..labels.len) |i| {
        if ((i % 4) == 0 or (i % 9) == 0) labels[i] = Region.unlabeled;
    }

    const perspective = Perspective.init(.{
        .{ .x = -5, .y = -3 },
        .{ .x = 22, .y = 1 },
        .{ .x = 25, .y = 24 },
        .{ .x = -2, .y = 19 },
    }, 20.0, 20.0);
    const grid = Grid{
        .grid_size = 21,
        .perspective = perspective,
        .alignment_corner = .{ .x = 20, .y = 20 },
    };
    var kernel: FitnessKernel = undefined;
    kernel.init(21, perspective, &labels, 21, 21);

    try std.testing.expectEqual(
        fitnessAllReference(&grid, perspective, &labels, 21, 21),
        kernel.all(&grid),
    );
}
