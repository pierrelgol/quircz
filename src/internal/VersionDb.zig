const std = @import("std");
const Spec = @import("Spec.zig");

pub const RsBlockLayout = struct {
    block_bytes: u16,
    data_bytes: u16,
    small_block_count: u8,
};

pub const VersionInfo = struct {
    total_data_bytes: u16,
    alignment_positions: [7]u8,
    ecc: [4]RsBlockLayout,

    pub fn alignmentCount(self: VersionInfo) usize {
        var count: usize = 0;
        while (count < self.alignment_positions.len and self.alignment_positions[count] != 0) : (count += 1) {}
        return count;
    }

    pub fn alignmentPositions(self: *const VersionInfo) []const u8 {
        return self.alignment_positions[0..self.alignmentCount()];
    }
};

pub const max_block_bytes: usize = blk: {
    var max: usize = 0;
    for (versions[1..]) |info| {
        for (info.ecc) |layout| {
            max = @max(max, layout.block_bytes);
        }
    }
    break :blk max;
};

pub fn gridSizeForVersion(version: u8) error{InvalidVersion}!u16 {
    if (version == 0 or version > Spec.max_version) {
        return error.InvalidVersion;
    }

    return @as(u16, version) * 4 + 17;
}

pub fn versionForGridSize(grid_size: u16) error{ InvalidGridSize, InvalidVersion }!u8 {
    if (grid_size > Spec.max_grid_size or grid_size < 21) {
        return error.InvalidGridSize;
    }
    if ((grid_size - 17) % 4 != 0) {
        return error.InvalidGridSize;
    }

    const version = @as(u8, @intCast((grid_size - 17) / 4));
    if (version == 0 or version > Spec.max_version) {
        return error.InvalidVersion;
    }

    return version;
}

fn isReservedCell(version: u8, i: i32, j: i32) bool {
    const info = &versions[version];
    const size = @as(i32, version) * 4 + 17;

    if (i < 9 and j < 9) return true;
    if (i + 8 >= size and j < 9) return true;
    if (i < 9 and j + 8 >= size) return true;
    if (i == 6 or j == 6) return true;

    if (version >= 7) {
        if (i < 6 and j + 11 >= size) return true;
        if (i + 11 >= size and j < 6) return true;
    }

    var ai: i32 = -1;
    var aj: i32 = -1;
    var a: i32 = 0;
    for (info.alignment_positions, 0..) |position, idx| {
        if (position == 0) break;
        const p: i32 = position;
        if (@abs(p - i) < 3) ai = @intCast(idx);
        if (@abs(p - j) < 3) aj = @intCast(idx);
        a += 1;
    }

    if (ai >= 0 and aj >= 0) {
        a -= 1;
        if (ai > 0 and ai < a) return true;
        if (aj > 0 and aj < a) return true;
        if (aj == a and ai == a) return true;
    }

    return false;
}

fn rawBitCountForVersionComptime(version: u8) u16 {
    const size = @as(i32, version) * 4 + 17;
    var count: u16 = 0;
    var y: i32 = size - 1;
    var x: i32 = size - 1;
    var direction: i32 = -1;

    while (x > 0) {
        if (x == 6) {
            x -= 1;
        }

        if (!isReservedCell(version, y, x)) {
            count += 1;
        }

        if (!isReservedCell(version, y, x - 1)) {
            count += 1;
        }

        y += direction;
        if (y < 0 or y >= size) {
            direction = -direction;
            x -= 2;
            y += direction;
        }
    }

    return count;
}

pub const raw_bit_counts: [41]u16 = blk: {
    @setEvalBranchQuota(5_000_000);
    var counts: [41]u16 = undefined;
    counts[0] = 0;
    for (1..counts.len) |version| {
        counts[version] = rawBitCountForVersionComptime(@intCast(version));
    }
    break :blk counts;
};

pub const raw_byte_capacities: [41]u16 = blk: {
    var capacities: [41]u16 = undefined;
    capacities[0] = 0;
    for (1..capacities.len) |version| {
        const bit_count = raw_bit_counts[version];
        capacities[version] = @intCast((bit_count + 7) / 8);
    }
    break :blk capacities;
};

pub fn rawBitCount(version: u8) error{InvalidVersion}!u16 {
    if (version == 0 or version > Spec.max_version) {
        return error.InvalidVersion;
    }

    return raw_bit_counts[version];
}

pub fn rawByteCapacity(version: u8) error{InvalidVersion}!usize {
    if (version == 0 or version > Spec.max_version) {
        return error.InvalidVersion;
    }

    return raw_byte_capacities[version];
}

pub const versions: [41]VersionInfo = .{
    .{
        .total_data_bytes = 0,
        .alignment_positions = .{ 0, 0, 0, 0, 0, 0, 0 },
        .ecc = @splat(.{
            .block_bytes = 0,
            .data_bytes = 0,
            .small_block_count = 0,
        }),
    },
    .{
        .total_data_bytes = 26,
        .alignment_positions = .{ 0, 0, 0, 0, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 26, .data_bytes = 16, .small_block_count = 1 },
            .{ .block_bytes = 26, .data_bytes = 19, .small_block_count = 1 },
            .{ .block_bytes = 26, .data_bytes = 9, .small_block_count = 1 },
            .{ .block_bytes = 26, .data_bytes = 13, .small_block_count = 1 },
        },
    },
    .{
        .total_data_bytes = 44,
        .alignment_positions = .{ 6, 18, 0, 0, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 44, .data_bytes = 28, .small_block_count = 1 },
            .{ .block_bytes = 44, .data_bytes = 34, .small_block_count = 1 },
            .{ .block_bytes = 44, .data_bytes = 16, .small_block_count = 1 },
            .{ .block_bytes = 44, .data_bytes = 22, .small_block_count = 1 },
        },
    },
    .{
        .total_data_bytes = 70,
        .alignment_positions = .{ 6, 22, 0, 0, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 70, .data_bytes = 44, .small_block_count = 1 },
            .{ .block_bytes = 70, .data_bytes = 55, .small_block_count = 1 },
            .{ .block_bytes = 35, .data_bytes = 13, .small_block_count = 2 },
            .{ .block_bytes = 35, .data_bytes = 17, .small_block_count = 2 },
        },
    },
    .{
        .total_data_bytes = 100,
        .alignment_positions = .{ 6, 26, 0, 0, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 50, .data_bytes = 32, .small_block_count = 2 },
            .{ .block_bytes = 100, .data_bytes = 80, .small_block_count = 1 },
            .{ .block_bytes = 25, .data_bytes = 9, .small_block_count = 4 },
            .{ .block_bytes = 50, .data_bytes = 24, .small_block_count = 2 },
        },
    },
    .{
        .total_data_bytes = 134,
        .alignment_positions = .{ 6, 30, 0, 0, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 67, .data_bytes = 43, .small_block_count = 2 },
            .{ .block_bytes = 134, .data_bytes = 108, .small_block_count = 1 },
            .{ .block_bytes = 33, .data_bytes = 11, .small_block_count = 2 },
            .{ .block_bytes = 33, .data_bytes = 15, .small_block_count = 2 },
        },
    },
    .{
        .total_data_bytes = 172,
        .alignment_positions = .{ 6, 34, 0, 0, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 43, .data_bytes = 27, .small_block_count = 4 },
            .{ .block_bytes = 86, .data_bytes = 68, .small_block_count = 2 },
            .{ .block_bytes = 43, .data_bytes = 15, .small_block_count = 4 },
            .{ .block_bytes = 43, .data_bytes = 19, .small_block_count = 4 },
        },
    },
    .{
        .total_data_bytes = 196,
        .alignment_positions = .{ 6, 22, 38, 0, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 49, .data_bytes = 31, .small_block_count = 4 },
            .{ .block_bytes = 98, .data_bytes = 78, .small_block_count = 2 },
            .{ .block_bytes = 39, .data_bytes = 13, .small_block_count = 4 },
            .{ .block_bytes = 32, .data_bytes = 14, .small_block_count = 2 },
        },
    },
    .{
        .total_data_bytes = 242,
        .alignment_positions = .{ 6, 24, 42, 0, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 60, .data_bytes = 38, .small_block_count = 2 },
            .{ .block_bytes = 121, .data_bytes = 97, .small_block_count = 2 },
            .{ .block_bytes = 40, .data_bytes = 14, .small_block_count = 4 },
            .{ .block_bytes = 40, .data_bytes = 18, .small_block_count = 4 },
        },
    },
    .{
        .total_data_bytes = 292,
        .alignment_positions = .{ 6, 26, 46, 0, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 58, .data_bytes = 36, .small_block_count = 3 },
            .{ .block_bytes = 146, .data_bytes = 116, .small_block_count = 2 },
            .{ .block_bytes = 36, .data_bytes = 12, .small_block_count = 4 },
            .{ .block_bytes = 36, .data_bytes = 16, .small_block_count = 4 },
        },
    },
    .{
        .total_data_bytes = 346,
        .alignment_positions = .{ 6, 28, 50, 0, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 69, .data_bytes = 43, .small_block_count = 4 },
            .{ .block_bytes = 86, .data_bytes = 68, .small_block_count = 2 },
            .{ .block_bytes = 43, .data_bytes = 15, .small_block_count = 6 },
            .{ .block_bytes = 43, .data_bytes = 19, .small_block_count = 6 },
        },
    },
    .{
        .total_data_bytes = 404,
        .alignment_positions = .{ 6, 30, 54, 0, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 80, .data_bytes = 50, .small_block_count = 1 },
            .{ .block_bytes = 101, .data_bytes = 81, .small_block_count = 4 },
            .{ .block_bytes = 36, .data_bytes = 12, .small_block_count = 3 },
            .{ .block_bytes = 50, .data_bytes = 22, .small_block_count = 4 },
        },
    },
    .{
        .total_data_bytes = 466,
        .alignment_positions = .{ 6, 32, 58, 0, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 58, .data_bytes = 36, .small_block_count = 6 },
            .{ .block_bytes = 116, .data_bytes = 92, .small_block_count = 2 },
            .{ .block_bytes = 42, .data_bytes = 14, .small_block_count = 7 },
            .{ .block_bytes = 46, .data_bytes = 20, .small_block_count = 4 },
        },
    },
    .{
        .total_data_bytes = 532,
        .alignment_positions = .{ 6, 34, 62, 0, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 59, .data_bytes = 37, .small_block_count = 8 },
            .{ .block_bytes = 133, .data_bytes = 107, .small_block_count = 4 },
            .{ .block_bytes = 33, .data_bytes = 11, .small_block_count = 12 },
            .{ .block_bytes = 44, .data_bytes = 20, .small_block_count = 8 },
        },
    },
    .{
        .total_data_bytes = 581,
        .alignment_positions = .{ 6, 26, 46, 66, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 64, .data_bytes = 40, .small_block_count = 4 },
            .{ .block_bytes = 145, .data_bytes = 115, .small_block_count = 3 },
            .{ .block_bytes = 36, .data_bytes = 12, .small_block_count = 11 },
            .{ .block_bytes = 36, .data_bytes = 16, .small_block_count = 11 },
        },
    },
    .{
        .total_data_bytes = 655,
        .alignment_positions = .{ 6, 26, 48, 70, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 65, .data_bytes = 41, .small_block_count = 5 },
            .{ .block_bytes = 109, .data_bytes = 87, .small_block_count = 5 },
            .{ .block_bytes = 36, .data_bytes = 12, .small_block_count = 11 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 5 },
        },
    },
    .{
        .total_data_bytes = 733,
        .alignment_positions = .{ 6, 26, 50, 74, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 73, .data_bytes = 45, .small_block_count = 7 },
            .{ .block_bytes = 122, .data_bytes = 98, .small_block_count = 5 },
            .{ .block_bytes = 45, .data_bytes = 15, .small_block_count = 3 },
            .{ .block_bytes = 43, .data_bytes = 19, .small_block_count = 15 },
        },
    },
    .{
        .total_data_bytes = 815,
        .alignment_positions = .{ 6, 30, 54, 78, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 74, .data_bytes = 46, .small_block_count = 10 },
            .{ .block_bytes = 135, .data_bytes = 107, .small_block_count = 1 },
            .{ .block_bytes = 42, .data_bytes = 14, .small_block_count = 2 },
            .{ .block_bytes = 50, .data_bytes = 22, .small_block_count = 1 },
        },
    },
    .{
        .total_data_bytes = 901,
        .alignment_positions = .{ 6, 30, 56, 82, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 69, .data_bytes = 43, .small_block_count = 9 },
            .{ .block_bytes = 150, .data_bytes = 120, .small_block_count = 5 },
            .{ .block_bytes = 42, .data_bytes = 14, .small_block_count = 2 },
            .{ .block_bytes = 50, .data_bytes = 22, .small_block_count = 17 },
        },
    },
    .{
        .total_data_bytes = 991,
        .alignment_positions = .{ 6, 30, 58, 86, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 70, .data_bytes = 44, .small_block_count = 3 },
            .{ .block_bytes = 141, .data_bytes = 113, .small_block_count = 3 },
            .{ .block_bytes = 39, .data_bytes = 13, .small_block_count = 9 },
            .{ .block_bytes = 47, .data_bytes = 21, .small_block_count = 17 },
        },
    },
    .{
        .total_data_bytes = 1085,
        .alignment_positions = .{ 6, 34, 62, 90, 0, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 67, .data_bytes = 41, .small_block_count = 3 },
            .{ .block_bytes = 135, .data_bytes = 107, .small_block_count = 3 },
            .{ .block_bytes = 43, .data_bytes = 15, .small_block_count = 15 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 15 },
        },
    },
    .{
        .total_data_bytes = 1156,
        .alignment_positions = .{ 6, 28, 50, 72, 92, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 68, .data_bytes = 42, .small_block_count = 17 },
            .{ .block_bytes = 144, .data_bytes = 116, .small_block_count = 4 },
            .{ .block_bytes = 46, .data_bytes = 16, .small_block_count = 19 },
            .{ .block_bytes = 50, .data_bytes = 22, .small_block_count = 17 },
        },
    },
    .{
        .total_data_bytes = 1258,
        .alignment_positions = .{ 6, 26, 50, 74, 98, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 74, .data_bytes = 46, .small_block_count = 17 },
            .{ .block_bytes = 139, .data_bytes = 111, .small_block_count = 2 },
            .{ .block_bytes = 37, .data_bytes = 13, .small_block_count = 34 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 7 },
        },
    },
    .{
        .total_data_bytes = 1364,
        .alignment_positions = .{ 6, 30, 54, 78, 102, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 75, .data_bytes = 47, .small_block_count = 4 },
            .{ .block_bytes = 151, .data_bytes = 121, .small_block_count = 4 },
            .{ .block_bytes = 45, .data_bytes = 15, .small_block_count = 16 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 11 },
        },
    },
    .{
        .total_data_bytes = 1474,
        .alignment_positions = .{ 6, 28, 54, 80, 106, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 73, .data_bytes = 45, .small_block_count = 6 },
            .{ .block_bytes = 147, .data_bytes = 117, .small_block_count = 6 },
            .{ .block_bytes = 46, .data_bytes = 16, .small_block_count = 30 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 11 },
        },
    },
    .{
        .total_data_bytes = 1588,
        .alignment_positions = .{ 6, 32, 58, 84, 110, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 75, .data_bytes = 47, .small_block_count = 8 },
            .{ .block_bytes = 132, .data_bytes = 106, .small_block_count = 8 },
            .{ .block_bytes = 45, .data_bytes = 15, .small_block_count = 22 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 7 },
        },
    },
    .{
        .total_data_bytes = 1706,
        .alignment_positions = .{ 6, 30, 58, 86, 114, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 74, .data_bytes = 46, .small_block_count = 19 },
            .{ .block_bytes = 142, .data_bytes = 114, .small_block_count = 10 },
            .{ .block_bytes = 46, .data_bytes = 16, .small_block_count = 33 },
            .{ .block_bytes = 50, .data_bytes = 22, .small_block_count = 28 },
        },
    },
    .{
        .total_data_bytes = 1828,
        .alignment_positions = .{ 6, 34, 62, 90, 118, 0, 0 },
        .ecc = .{
            .{ .block_bytes = 73, .data_bytes = 45, .small_block_count = 22 },
            .{ .block_bytes = 152, .data_bytes = 122, .small_block_count = 8 },
            .{ .block_bytes = 45, .data_bytes = 15, .small_block_count = 12 },
            .{ .block_bytes = 53, .data_bytes = 23, .small_block_count = 8 },
        },
    },
    .{
        .total_data_bytes = 1921,
        .alignment_positions = .{ 6, 26, 50, 74, 98, 122, 0 },
        .ecc = .{
            .{ .block_bytes = 73, .data_bytes = 45, .small_block_count = 3 },
            .{ .block_bytes = 147, .data_bytes = 117, .small_block_count = 3 },
            .{ .block_bytes = 45, .data_bytes = 15, .small_block_count = 11 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 4 },
        },
    },
    .{
        .total_data_bytes = 2051,
        .alignment_positions = .{ 6, 30, 54, 78, 102, 126, 0 },
        .ecc = .{
            .{ .block_bytes = 73, .data_bytes = 45, .small_block_count = 21 },
            .{ .block_bytes = 146, .data_bytes = 116, .small_block_count = 7 },
            .{ .block_bytes = 45, .data_bytes = 15, .small_block_count = 19 },
            .{ .block_bytes = 53, .data_bytes = 23, .small_block_count = 1 },
        },
    },
    .{
        .total_data_bytes = 2185,
        .alignment_positions = .{ 6, 26, 52, 78, 104, 130, 0 },
        .ecc = .{
            .{ .block_bytes = 75, .data_bytes = 47, .small_block_count = 19 },
            .{ .block_bytes = 145, .data_bytes = 115, .small_block_count = 5 },
            .{ .block_bytes = 45, .data_bytes = 15, .small_block_count = 23 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 15 },
        },
    },
    .{
        .total_data_bytes = 2323,
        .alignment_positions = .{ 6, 30, 56, 82, 108, 134, 0 },
        .ecc = .{
            .{ .block_bytes = 74, .data_bytes = 46, .small_block_count = 2 },
            .{ .block_bytes = 145, .data_bytes = 115, .small_block_count = 13 },
            .{ .block_bytes = 45, .data_bytes = 15, .small_block_count = 23 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 42 },
        },
    },
    .{
        .total_data_bytes = 2465,
        .alignment_positions = .{ 6, 34, 60, 86, 112, 138, 0 },
        .ecc = .{
            .{ .block_bytes = 74, .data_bytes = 46, .small_block_count = 10 },
            .{ .block_bytes = 145, .data_bytes = 115, .small_block_count = 17 },
            .{ .block_bytes = 45, .data_bytes = 15, .small_block_count = 19 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 10 },
        },
    },
    .{
        .total_data_bytes = 2611,
        .alignment_positions = .{ 6, 30, 58, 86, 114, 142, 0 },
        .ecc = .{
            .{ .block_bytes = 74, .data_bytes = 46, .small_block_count = 14 },
            .{ .block_bytes = 145, .data_bytes = 115, .small_block_count = 17 },
            .{ .block_bytes = 45, .data_bytes = 15, .small_block_count = 11 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 29 },
        },
    },
    .{
        .total_data_bytes = 2761,
        .alignment_positions = .{ 6, 34, 62, 90, 118, 146, 0 },
        .ecc = .{
            .{ .block_bytes = 74, .data_bytes = 46, .small_block_count = 14 },
            .{ .block_bytes = 145, .data_bytes = 115, .small_block_count = 13 },
            .{ .block_bytes = 46, .data_bytes = 16, .small_block_count = 59 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 44 },
        },
    },
    .{
        .total_data_bytes = 2876,
        .alignment_positions = .{ 6, 30, 54, 78, 102, 126, 150 },
        .ecc = .{
            .{ .block_bytes = 75, .data_bytes = 47, .small_block_count = 12 },
            .{ .block_bytes = 151, .data_bytes = 121, .small_block_count = 12 },
            .{ .block_bytes = 45, .data_bytes = 15, .small_block_count = 22 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 39 },
        },
    },
    .{
        .total_data_bytes = 3034,
        .alignment_positions = .{ 6, 24, 50, 76, 102, 128, 154 },
        .ecc = .{
            .{ .block_bytes = 75, .data_bytes = 47, .small_block_count = 6 },
            .{ .block_bytes = 151, .data_bytes = 121, .small_block_count = 6 },
            .{ .block_bytes = 45, .data_bytes = 15, .small_block_count = 2 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 46 },
        },
    },
    .{
        .total_data_bytes = 3196,
        .alignment_positions = .{ 6, 28, 54, 80, 106, 132, 158 },
        .ecc = .{
            .{ .block_bytes = 74, .data_bytes = 46, .small_block_count = 29 },
            .{ .block_bytes = 152, .data_bytes = 122, .small_block_count = 17 },
            .{ .block_bytes = 45, .data_bytes = 15, .small_block_count = 24 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 49 },
        },
    },
    .{
        .total_data_bytes = 3362,
        .alignment_positions = .{ 6, 32, 58, 84, 110, 136, 162 },
        .ecc = .{
            .{ .block_bytes = 74, .data_bytes = 46, .small_block_count = 13 },
            .{ .block_bytes = 152, .data_bytes = 122, .small_block_count = 4 },
            .{ .block_bytes = 45, .data_bytes = 15, .small_block_count = 42 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 48 },
        },
    },
    .{
        .total_data_bytes = 3532,
        .alignment_positions = .{ 6, 26, 54, 82, 110, 138, 166 },
        .ecc = .{
            .{ .block_bytes = 75, .data_bytes = 47, .small_block_count = 40 },
            .{ .block_bytes = 147, .data_bytes = 117, .small_block_count = 20 },
            .{ .block_bytes = 45, .data_bytes = 15, .small_block_count = 10 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 43 },
        },
    },
    .{
        .total_data_bytes = 3706,
        .alignment_positions = .{ 6, 30, 58, 86, 114, 142, 170 },
        .ecc = .{
            .{ .block_bytes = 75, .data_bytes = 47, .small_block_count = 18 },
            .{ .block_bytes = 148, .data_bytes = 118, .small_block_count = 19 },
            .{ .block_bytes = 45, .data_bytes = 15, .small_block_count = 20 },
            .{ .block_bytes = 54, .data_bytes = 24, .small_block_count = 34 },
        },
    },
};

test "version count matches spec" {
    try std.testing.expectEqual(@as(usize, 41), versions.len);
}

test "selected version metadata matches quirc" {
    try std.testing.expectEqual(@as(u16, 26), versions[1].total_data_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 6, 22, 38, 0, 0, 0, 0 }, &versions[7].alignment_positions);
    try std.testing.expectEqual(@as(u16, 75), versions[40].ecc[0].block_bytes);
    try std.testing.expectEqual(@as(u8, 34), versions[40].ecc[3].small_block_count);
    try std.testing.expectEqual(@as(usize, 152), max_block_bytes);
    try std.testing.expectEqual(@as(u16, 208), try rawBitCount(1));
    try std.testing.expectEqual(@as(usize, 26), try rawByteCapacity(1));
    try std.testing.expectEqual(@as(u16, 807), try rawBitCount(4));
    try std.testing.expectEqual(@as(usize, 101), try rawByteCapacity(4));
}

test "version helpers" {
    try std.testing.expectEqual(@as(usize, 0), versions[1].alignmentCount());
    try std.testing.expectEqual(@as(usize, 3), versions[7].alignmentCount());
    try std.testing.expectEqualSlices(u8, &.{ 6, 22, 38 }, versions[7].alignmentPositions());
    try std.testing.expectEqual(@as(u16, 21), try gridSizeForVersion(1));
    try std.testing.expectEqual(@as(u8, 7), try versionForGridSize(45));
}
