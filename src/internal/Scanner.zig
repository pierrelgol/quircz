const std = @import("std");
const Detect = @import("../Detect.zig");
const Capstone = @import("Capstone.zig");
const FloodFill = @import("FloodFill.zig");
const Grid = @import("Grid.zig");
const Histogram = @import("Histogram.zig");
const Image = @import("Image.zig");
const Region = @import("Region.zig");
const Spec = @import("Spec.zig");

const Scanner = @This();

fba: ?*std.heap.FixedBufferAllocator = null,
detections: []const Detect.Detection = &.{},
labels: []u8 = &.{},
regions: []Region = &.{},
region_count: u16 = 0,
flood_fill_stack: []FloodFill.StackFrame = &.{},
capstones: []Capstone = &.{},
capstone_count: u16 = 0,
grids: []Grid = &.{},
grid_count: u16 = 0,
width: u32 = 0,
height: u32 = 0,
finder_match_count: u32 = 0,
candidate_count: u32 = 0,

pub fn init() Scanner {
    return .{};
}

pub fn reset(self: *Scanner, fba: *std.heap.FixedBufferAllocator) void {
    self.fba = fba;
    self.detections = &.{};
    self.labels = &.{};
    self.regions = &.{};
    self.region_count = 0;
    self.flood_fill_stack = &.{};
    self.capstones = &.{};
    self.capstone_count = 0;
    self.grids = &.{};
    self.grid_count = 0;
    self.width = 0;
    self.height = 0;
    self.finder_match_count = 0;
    self.candidate_count = 0;
}

pub fn scan(
    self: *Scanner,
    image: *const Image,
    out_detections: []Detect.Detection,
) Detect.Error![]const Detect.Detection {
    self.width = image.width;
    self.height = image.height;
    try image.validate();
    try self.allocateWorkspace(image);
    try self.threshold(image);
    try self.findCapstones(image);
    try self.groupGrids();

    self.detections = self.writeDetections(out_detections);
    return self.detections;
}

pub fn extract(
    self: *Scanner,
    image: *const Image,
    detection: *const Detect.Detection,
) Detect.ExtractError!Detect.Code {
    _ = image;

    if (self.labels.len == 0 or self.width == 0 or self.height == 0) {
        return error.InvalidDetection;
    }
    if (detection.grid_size < 21 or ((detection.grid_size - 17) % 4) != 0) {
        return error.InvalidDetection;
    }

    var code = Detect.Code{
        .corners = detection.corners,
        .size = detection.grid_size,
    };

    if (code.size > Spec.max_grid_size) {
        return error.GridTooLarge;
    }

    var bit_index: usize = 0;
    for (0..code.size) |y| {
        for (0..code.size) |x| {
            const point = detection.perspective.map(
                @as(f64, @floatFromInt(x)) + 0.5,
                @as(f64, @floatFromInt(y)) + 0.5,
            );
            if (point.y < 0 or point.y >= self.height or point.x < 0 or point.x >= self.width) {
                bit_index += 1;
                continue;
            }

            if (self.isBlackAt(@intCast(point.x), @intCast(point.y))) {
                code.cells[bit_index >> 3] |= @as(u8, 1) << @as(u3, @intCast(bit_index & 7));
            }
            bit_index += 1;
        }
    }

    return code;
}

fn allocateWorkspace(self: *Scanner, image: *const Image) Detect.Error!void {
    const scratch_allocator = if (self.fba) |fba| fba.allocator() else return error.ScratchTooSmall;
    const pixel_count = image.pixelCount();
    const flood_fill_depth = FloodFill.stackDepthForHeight(image.height);

    self.labels = scratch_allocator.alloc(u8, pixel_count) catch return error.ScratchTooSmall;
    self.regions = scratch_allocator.alloc(Region, Spec.max_regions) catch return error.ScratchTooSmall;
    self.flood_fill_stack = scratch_allocator.alloc(FloodFill.StackFrame, flood_fill_depth) catch return error.ScratchTooSmall;
    self.capstones = scratch_allocator.alloc(Capstone, Spec.max_capstones) catch return error.ScratchTooSmall;
    self.grids = scratch_allocator.alloc(Grid, Spec.max_grids) catch return error.ScratchTooSmall;
}

fn threshold(self: *Scanner, image: *const Image) Detect.Error!void {
    var histogram: Histogram = .empty;
    histogram.fromImageChannel(image);
    const t = image.computeAdaptiveThreshold(&histogram);
    image.thresholdIntoLabels(t, self.labels, Region.unlabeled, Region.white) catch return error.ScratchTooSmall;
}

fn findCapstones(self: *Scanner, image: *const Image) Detect.Error!void {
    self.region_count = 0;
    self.capstone_count = 0;
    for (0..image.height) |y| {
        Capstone.scanFinderRow(self.labels, image.width, @intCast(y), self, onFinderMatch);
    }
}

fn groupGrids(self: *Scanner) Detect.Error!void {
    self.grid_count = 0;
    for (0..self.capstone_count) |index| {
        try self.testGrouping(index);
    }
}

fn testGrouping(self: *Scanner, index: usize) Detect.Error!void {
    const Neighbour = struct {
        index: u16,
        distance: f64,
    };

    var hlist: [32]Neighbour = undefined;
    var vlist: [32]Neighbour = undefined;
    var hcount: usize = 0;
    var vcount: usize = 0;

    const capstones = self.capstones[0..self.capstone_count];
    const c1 = &capstones[index];

    for (capstones, 0..) |*c2, j| {
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
            if (self.grid_count >= self.grids.len) return error.TooManyGrids;

            self.grids[self.grid_count] = Grid.record(capstones, hn.index, @intCast(index), vn.index) catch continue;
            const current_grid = self.grid_count;
            self.grid_count += 1;
            const grid = &self.grids[current_grid];

            capstones[hn.index].grid_index = current_grid;
            capstones[index].grid_index = current_grid;
            capstones[vn.index].grid_index = current_grid;

            self.findAlignmentPattern(grid);
            grid.setupPerspective(
                capstones,
                self.labels,
                self.width,
                self.height,
            );
        }
    }
}

fn writeDetections(self: *Scanner, out_detections: []Detect.Detection) []const Detect.Detection {
    const count = @min(out_detections.len, self.grid_count);

    for (0..count) |i| {
        const grid = self.grids[i];
        out_detections[i] = .{
            .corners = .{
                grid.perspective.map(0.0, 0.0),
                grid.perspective.map(@floatFromInt(grid.grid_size), 0.0),
                grid.perspective.map(@floatFromInt(grid.grid_size), @floatFromInt(grid.grid_size)),
                grid.perspective.map(0.0, @floatFromInt(grid.grid_size)),
            },
            .grid_size = grid.grid_size,
            .perspective = grid.perspective,
        };
    }

    return out_detections[0..count];
}

fn onFinderMatch(self: *Scanner, match: Capstone.Match) void {
    self.finder_match_count += 1;
    const candidate = self.testCandidate(match) catch return orelse return;
    self.candidate_count += 1;

    if (self.capstone_count >= self.capstones.len) {
        @branchHint(.unlikely);
        return;
    }

    self.capstones[self.capstone_count] = Capstone.record(
        self.regions[0..self.region_count],
        candidate.ring_region,
        candidate.stone_region,
        self.capstone_count,
        self.labels,
        self.width,
        self.height,
        self.flood_fill_stack,
    ) catch return;
    self.capstone_count += 1;
}

fn regionCode(self: *Scanner, x: i32, y: i32) Detect.Error!?u8 {
    return Region.labelRegionAt(
        self.labels,
        self.width,
        self.height,
        x,
        y,
        self.flood_fill_stack,
        self.regions,
        &self.region_count,
    );
}

fn isBlackAt(self: *const Scanner, x: i32, y: i32) bool {
    return self.labels[@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))] != Region.white;
}

fn testCandidate(self: *Scanner, match: Capstone.Match) Detect.Error!?struct {
    ring_region: u8,
    stone_region: u8,
} {
    const runs = match.runs;
    const span = runs[0] + runs[1] + runs[2] + runs[3] + runs[4];
    if (match.x < span) {
        return null;
    }

    const y: i32 = @intCast(match.y);
    const ring_right = try self.regionCode(@intCast(match.x - runs[4]), y) orelse return null;
    const stone = try self.regionCode(@intCast(match.x - runs[4] - runs[3] - runs[2]), y) orelse return null;
    const ring_left = try self.regionCode(@intCast(match.x - runs[4] - runs[3] - runs[2] - runs[1] - runs[0]), y) orelse return null;

    if (ring_left != ring_right or ring_left == stone) {
        return null;
    }

    const stone_region = Region.byLabel(self.regions[0..self.region_count], stone) orelse return null;
    const ring_region = Region.byLabel(self.regions[0..self.region_count], ring_left) orelse return null;

    if (stone_region.capstone_index != null or ring_region.capstone_index != null) {
        return null;
    }

    const ratio = @as(u32, @intCast(stone_region.area * 100 / @max(ring_region.area, 1)));
    if (ratio < 10 or ratio > 70) {
        return null;
    }

    return .{
        .ring_region = ring_left,
        .stone_region = stone,
    };
}

fn findAlignmentPattern(self: *Scanner, grid: *Grid) void {
    if (grid.grid_size <= 21) return;

    const c0 = self.capstones[grid.capstones[0]];
    const c2 = self.capstones[grid.capstones[2]];

    var probe = grid.alignment_corner;

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
            const found_label = self.regionCode(probe.x, probe.y) catch return orelse {
                probe.x += dx_map[dir];
                probe.y += dy_map[dir];
                continue;
            };
            const region = Region.byLabelConst(self.regions[0..self.region_count], found_label) orelse {
                probe.x += dx_map[dir];
                probe.y += dy_map[dir];
                continue;
            };

            if (region.area >= @as(u32, @intCast(@divFloor(size_estimate, 2))) and
                region.area <= @as(u32, @intCast(size_estimate * 2)))
            {
                grid.alignment_region = found_label;
                grid.alignment_corner = region.seed;
                grid.alignment_corner = Grid.findLeftmostToLine(
                    self.labels,
                    self.width,
                    self.height,
                    region.seed,
                    found_label,
                    .{
                        .x = self.capstones[grid.capstones[2]].center.x - self.capstones[grid.capstones[0]].center.x,
                        .y = self.capstones[grid.capstones[2]].center.y - self.capstones[grid.capstones[0]].center.y,
                    },
                    self.flood_fill_stack,
                ) orelse region.seed;
                return;
            }

            probe.x += dx_map[dir];
            probe.y += dy_map[dir];
        }

        dir = (dir + 1) % 4;
        if ((dir & 1) == 0) step_size += 1;
    }
}

test "regionCode builds connected black regions lazily" {
    const pixels = [_]u8{
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
    };
    const binary = [_]u8{
        1, 1, 0, 0,
        1, 0, 0, 1,
        0, 0, 1, 1,
    };
    var scratch: [Detect.scratchBytesForImage(4, 3)]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var scanner = Scanner.init();
    scanner.reset(&fba);
    const image = Image.init(&pixels, 4, 3);
    scanner.width = image.width;
    scanner.height = image.height;
    try scanner.allocateWorkspace(&image);

    for (binary, 0..) |pixel, i| {
        scanner.labels[i] = if (pixel == 0) Region.white else Region.unlabeled;
    }

    for (0..image.height) |y| {
        for (0..image.width) |x| {
            _ = try scanner.regionCode(@intCast(x), @intCast(y));
        }
    }

    try std.testing.expectEqual(@as(u16, 2), scanner.region_count);
    try std.testing.expectEqual(@as(u32, 3), scanner.regions[0].area);
    try std.testing.expectEqual(@as(u32, 3), scanner.regions[1].area);
}

test "extract rejects invalid detection before scan" {
    var scratch: [Detect.scratchBytesForImage(21, 21)]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var scanner = Scanner.init();
    scanner.reset(&fba);

    const image = Image.init(&[_]u8{0} ** (21 * 21), 21, 21);
    const detection = Detect.Detection{ .grid_size = 20 };

    try std.testing.expectError(error.InvalidDetection, scanner.extract(&image, &detection));
}
