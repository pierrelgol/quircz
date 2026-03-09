const std = @import("std");
const Decode = @import("Decode.zig");
const Detect = @import("Detect.zig");
const Spec = @import("internal/Spec.zig");
const VersionDb = @import("internal/VersionDb.zig");

pub const EccLevel = enum {
    l,
    m,
    q,
    h,
};

pub const Mode = enum {
    auto,
    numeric,
    alphanumeric,
    byte,
};

pub const Mask = enum {
    auto,
    m0,
    m1,
    m2,
    m3,
    m4,
    m5,
    m6,
    m7,
};

pub const Options = struct {
    mode: Mode = .auto,
    ecc_level: EccLevel = .m,
    version: ?u8 = null,
    mask: Mask = .auto,
    quiet_zone_modules: u8 = 4,
};

pub const Result = struct {
    modules: []u8,
    side_modules: u16,
    symbol_modules: u16,
    quiet_zone_modules: u8,
    version: u8,
    ecc_level: EccLevel,
    mode: Mode,
    mask: u3,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.modules);
        self.* = undefined;
    }

    pub fn moduleAt(self: Result, x: usize, y: usize) u1 {
        std.debug.assert(x < self.side_modules);
        std.debug.assert(y < self.side_modules);
        return @intCast(self.modules[y * self.side_modules + x]);
    }

    pub fn symbolModuleAt(self: Result, x: usize, y: usize) u1 {
        std.debug.assert(x < self.symbol_modules);
        std.debug.assert(y < self.symbol_modules);
        const q = self.quiet_zone_modules;
        return self.moduleAt(x + q, y + q);
    }
};

pub const Error = error{
    PayloadTooLarge,
    UnsupportedMode,
    InvalidVersion,
    InvalidMask,
    InvalidQuietZone,
    DataOverflow,
    AllocatorFailure,
};

const alphanumeric_charset = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";
const format_poly: u16 = 0x537;
const format_mask: u16 = 0x5412;
const version_poly: u32 = 0x1f25;
const max_data_codewords = 2956;
const max_block_bytes = 256;
const max_ecc_codewords = 30;

const Gf = struct {
    exp: [512]u8,
    log: [256]u8,
};

const Matrix = struct {
    modules: []u8,
    is_function: []u8,

    fn deinit(self: *Matrix, allocator: std.mem.Allocator) void {
        allocator.free(self.modules);
        allocator.free(self.is_function);
        self.* = undefined;
    }
};

const BitWriter = struct {
    bytes: []u8,
    bit_len: usize = 0,

    fn init(bytes: []u8) BitWriter {
        @memset(bytes, 0);
        return .{ .bytes = bytes };
    }

    fn appendBits(self: *BitWriter, value: u32, bit_count: u8) Error!void {
        if (bit_count == 0) return;
        var shift: i32 = bit_count - 1;
        while (shift >= 0) : (shift -= 1) {
            if (self.bit_len >= self.bytes.len * 8) return error.DataOverflow;
            const bit = (value >> @as(u5, @intCast(shift))) & 1;
            if (bit != 0) {
                self.bytes[self.bit_len >> 3] |= @as(u8, 0x80) >> @as(u3, @intCast(self.bit_len & 7));
            }
            self.bit_len += 1;
        }
    }

    fn alignToByte(self: *BitWriter) Error!void {
        while ((self.bit_len & 7) != 0) {
            try self.appendBits(0, 1);
        }
    }
};

pub fn encode(
    allocator: std.mem.Allocator,
    payload: []const u8,
    options: Options,
) Error!Result {
    const mode = try resolveMode(payload, options.mode);
    const version = try resolveVersion(payload, mode, options);
    const symbol_modules = try VersionDb.gridSizeForVersion(version);
    const mask_id = resolveMaskIndex(options.mask);
    const quiet_zone_modules = try validateQuietZone(options.quiet_zone_modules, symbol_modules);
    const data_codewords_len = dataCodewordsFor(version, options.ecc_level);
    const total_codewords_len = VersionDb.versions[version].total_data_bytes;

    const data_codewords = allocator.alloc(u8, data_codewords_len) catch return error.AllocatorFailure;
    defer allocator.free(data_codewords);
    try makeDataCodewords(payload, mode, version, options.ecc_level, data_codewords);

    const codewords = allocator.alloc(u8, total_codewords_len) catch return error.AllocatorFailure;
    defer allocator.free(codewords);
    try makeCodewords(data_codewords, version, options.ecc_level, codewords);

    var base = try makeBaseMatrix(allocator, version);
    defer base.deinit(allocator);
    drawCodewords(base.modules, base.is_function, symbol_modules, codewords);

    const working = allocator.alloc(u8, base.modules.len) catch return error.AllocatorFailure;
    defer allocator.free(working);

    const chosen_mask = if (mask_id) |fixed_mask| blk: {
        break :blk fixed_mask;
    } else blk: {
        var best_mask: u3 = 0;
        var best_score: ?i32 = null;
        for (0..8) |candidate| {
            @memcpy(working, base.modules);
            applyMask(working, base.is_function, symbol_modules, @intCast(candidate));
            drawFormatBits(working, symbol_modules, options.ecc_level, @intCast(candidate));
            if (version >= 7) drawVersionBits(working, symbol_modules, version);

            const score = penaltyScore(working, symbol_modules);
            if (best_score == null or score < best_score.?) {
                best_score = score;
                best_mask = @intCast(candidate);
            }
        }
        break :blk best_mask;
    };

    const side_modules = symbol_modules + quiet_zone_modules * 2;
    const modules = allocator.alloc(u8, @as(usize, side_modules) * side_modules) catch return error.AllocatorFailure;
    @memset(modules, 0);

    @memcpy(working, base.modules);
    applyMask(working, base.is_function, symbol_modules, chosen_mask);
    drawFormatBits(working, symbol_modules, options.ecc_level, chosen_mask);
    if (version >= 7) drawVersionBits(working, symbol_modules, version);

    for (0..symbol_modules) |y| {
        const dst_row = (y + quiet_zone_modules) * side_modules + quiet_zone_modules;
        const src_row = y * symbol_modules;
        @memcpy(modules[dst_row .. dst_row + symbol_modules], working[src_row .. src_row + symbol_modules]);
    }

    return .{
        .modules = modules,
        .side_modules = side_modules,
        .symbol_modules = symbol_modules,
        .quiet_zone_modules = quiet_zone_modules,
        .version = version,
        .ecc_level = options.ecc_level,
        .mode = mode,
        .mask = chosen_mask,
    };
}

fn validateQuietZone(quiet_zone_modules: u8, symbol_modules: u16) Error!u8 {
    const total = @as(u32, symbol_modules) + @as(u32, quiet_zone_modules) * 2;
    if (total > std.math.maxInt(u16)) return error.InvalidQuietZone;
    return quiet_zone_modules;
}

fn resolveMode(payload: []const u8, requested: Mode) Error!Mode {
    return switch (requested) {
        .auto => blk: {
            if (isNumeric(payload)) break :blk .numeric;
            if (isAlphanumeric(payload)) break :blk .alphanumeric;
            break :blk .byte;
        },
        .numeric => if (isNumeric(payload)) .numeric else error.UnsupportedMode,
        .alphanumeric => if (isAlphanumeric(payload)) .alphanumeric else error.UnsupportedMode,
        .byte => .byte,
    };
}

fn resolveVersion(payload: []const u8, mode: Mode, options: Options) Error!u8 {
    if (options.version) |version| {
        if (version == 0 or version > Spec.max_version) return error.InvalidVersion;
        if (!fitsInVersion(payload, mode, version, options.ecc_level)) return error.PayloadTooLarge;
        return version;
    }

    for (1..Spec.max_version + 1) |candidate| {
        if (fitsInVersion(payload, mode, @intCast(candidate), options.ecc_level)) {
            return @intCast(candidate);
        }
    }

    return error.PayloadTooLarge;
}

fn resolveMaskIndex(mask: Mask) ?u3 {
    return switch (mask) {
        .auto => null,
        .m0 => 0,
        .m1 => 1,
        .m2 => 2,
        .m3 => 3,
        .m4 => 4,
        .m5 => 5,
        .m6 => 6,
        .m7 => 7,
    };
}

fn fitsInVersion(payload: []const u8, mode: Mode, version: u8, ecc_level: EccLevel) bool {
    const required = requiredDataBits(payload, mode, version) catch return false;
    const capacity = dataCodewordsFor(version, ecc_level) * 8;
    return required <= capacity;
}

fn requiredDataBits(payload: []const u8, mode: Mode, version: u8) Error!usize {
    var bit_count: usize = 4;
    bit_count += characterCountBits(mode, version);
    bit_count += switch (mode) {
        .numeric => numericPayloadBits(payload.len),
        .alphanumeric => alphanumericPayloadBits(payload.len),
        .byte => payload.len * 8,
        .auto => unreachable,
    };
    return bit_count;
}

fn characterCountBits(mode: Mode, version: u8) usize {
    return switch (mode) {
        .numeric => if (version < 10) 10 else if (version < 27) 12 else 14,
        .alphanumeric => if (version < 10) 9 else if (version < 27) 11 else 13,
        .byte => if (version < 10) 8 else 16,
        .auto => unreachable,
    };
}

fn numericPayloadBits(len: usize) usize {
    const remainder_bits: usize = switch (len % 3) {
        0 => 0,
        1 => 4,
        2 => 7,
        else => unreachable,
    };
    return (len / 3) * 10 + remainder_bits;
}

fn alphanumericPayloadBits(len: usize) usize {
    const tail_bits: usize = if ((len & 1) != 0) 6 else 0;
    return (len / 2) * 11 + tail_bits;
}

fn dataCodewordsFor(version: u8, ecc_level: EccLevel) usize {
    const info = VersionDb.versions[version];
    const layout = info.ecc[eccIndex(ecc_level)];
    const small_blocks = layout.small_block_count;
    const large_blocks = largeBlockCount(info, layout);
    return @as(usize, layout.data_bytes) * small_blocks + @as(usize, layout.data_bytes + 1) * large_blocks;
}

fn largeBlockCount(info: VersionDb.VersionInfo, layout: VersionDb.RsBlockLayout) usize {
    return @as(usize, info.total_data_bytes - layout.block_bytes * layout.small_block_count) / @as(usize, layout.block_bytes + 1);
}

fn eccIndex(ecc_level: EccLevel) usize {
    return switch (ecc_level) {
        .m => 0,
        .l => 1,
        .h => 2,
        .q => 3,
    };
}

fn makeDataCodewords(
    payload: []const u8,
    mode: Mode,
    version: u8,
    ecc_level: EccLevel,
    out: []u8,
) Error!void {
    var writer = BitWriter.init(out);
    try writer.appendBits(modeIndicator(mode), 4);
    try writer.appendBits(@intCast(payload.len), @intCast(characterCountBits(mode, version)));

    switch (mode) {
        .numeric => try encodeNumeric(&writer, payload),
        .alphanumeric => try encodeAlphanumeric(&writer, payload),
        .byte => try encodeBytes(&writer, payload),
        .auto => unreachable,
    }

    const capacity_bits = dataCodewordsFor(version, ecc_level) * 8;
    if (writer.bit_len > capacity_bits) return error.DataOverflow;

    const terminator = @min(@as(usize, 4), capacity_bits - writer.bit_len);
    try writer.appendBits(0, @intCast(terminator));
    try writer.alignToByte();

    const pad_bytes = [_]u8{ 0xEC, 0x11 };
    var pad_index: usize = 0;
    while (writer.bit_len < capacity_bits) : (pad_index += 1) {
        try writer.appendBits(pad_bytes[pad_index & 1], 8);
    }
}

fn modeIndicator(mode: Mode) u32 {
    return switch (mode) {
        .numeric => 0x1,
        .alphanumeric => 0x2,
        .byte => 0x4,
        .auto => unreachable,
    };
}

fn encodeNumeric(writer: *BitWriter, payload: []const u8) Error!void {
    var cursor: usize = 0;
    while (cursor < payload.len) {
        const remaining = payload.len - cursor;
        const chunk_len = @min(remaining, 3);
        var value: u32 = 0;
        for (payload[cursor .. cursor + chunk_len]) |digit| {
            value = value * 10 + (digit - '0');
        }
        try writer.appendBits(value, switch (chunk_len) {
            1 => 4,
            2 => 7,
            3 => 10,
            else => unreachable,
        });
        cursor += chunk_len;
    }
}

fn encodeAlphanumeric(writer: *BitWriter, payload: []const u8) Error!void {
    var cursor: usize = 0;
    while (cursor + 1 < payload.len) : (cursor += 2) {
        const first = alphanumericIndex(payload[cursor]) orelse return error.UnsupportedMode;
        const second = alphanumericIndex(payload[cursor + 1]) orelse return error.UnsupportedMode;
        try writer.appendBits(first * 45 + second, 11);
    }

    if (cursor < payload.len) {
        const value = alphanumericIndex(payload[cursor]) orelse return error.UnsupportedMode;
        try writer.appendBits(value, 6);
    }
}

fn encodeBytes(writer: *BitWriter, payload: []const u8) Error!void {
    for (payload) |byte| {
        try writer.appendBits(byte, 8);
    }
}

fn alphanumericIndex(byte: u8) ?u32 {
    const index = std.mem.indexOfScalar(u8, alphanumeric_charset, byte) orelse return null;
    return @intCast(index);
}

fn isNumeric(payload: []const u8) bool {
    for (payload) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    return payload.len != 0;
}

fn isAlphanumeric(payload: []const u8) bool {
    for (payload) |byte| {
        if (alphanumericIndex(byte) == null) return false;
    }
    return payload.len != 0;
}

fn makeCodewords(data_codewords: []const u8, version: u8, ecc_level: EccLevel, out: []u8) Error!void {
    const info = VersionDb.versions[version];
    const layout = info.ecc[eccIndex(ecc_level)];
    const small_blocks = layout.small_block_count;
    const large_blocks = largeBlockCount(info, layout);
    const block_count = small_blocks + large_blocks;
    const ec_codewords = layout.block_bytes - layout.data_bytes;
    const large_data_words = layout.data_bytes + 1;

    var blocks: [160][max_block_bytes]u8 = undefined;
    var data_lengths: [160]u16 = @splat(0);
    var data_offset: usize = 0;

    for (0..block_count) |block_index| {
        const data_words: u16 = if (block_index < small_blocks) layout.data_bytes else large_data_words;
        const block_bytes: u16 = data_words + ec_codewords;
        data_lengths[block_index] = data_words;
        @memset(blocks[block_index][0..block_bytes], 0);
        @memcpy(blocks[block_index][0..data_words], data_codewords[data_offset .. data_offset + data_words]);
        data_offset += data_words;

        const ecc = blocks[block_index][data_words..block_bytes];
        makeErrorCodewords(blocks[block_index][0..data_words], ecc);
    }

    var out_index: usize = 0;
    for (0..large_data_words) |i| {
        for (0..block_count) |block_index| {
            if (i < data_lengths[block_index]) {
                out[out_index] = blocks[block_index][i];
                out_index += 1;
            }
        }
    }
    for (0..ec_codewords) |i| {
        for (0..block_count) |block_index| {
            out[out_index] = blocks[block_index][data_lengths[block_index] + i];
            out_index += 1;
        }
    }

    std.debug.assert(out_index == out.len);
}

fn makeErrorCodewords(data: []const u8, ecc_out: []u8) void {
    const generator = makeGeneratorPoly(ecc_out.len);

    @memset(ecc_out, 0);
    for (data) |datum| {
        const factor = datum ^ ecc_out[0];
        std.mem.copyForwards(u8, ecc_out[0 .. ecc_out.len - 1], ecc_out[1..]);
        ecc_out[ecc_out.len - 1] = 0;
        for (generator[1 .. ecc_out.len + 1], 0..) |coefficient, i| {
            ecc_out[i] ^= gfMul(coefficient, factor);
        }
    }
}

fn polyMul(left: []const u8, right: []const u8, out: []u8) []const u8 {
    @memset(out, 0);
    for (left, 0..) |left_value, i| {
        for (right, 0..) |right_value, j| {
            out[i + j] ^= gfMul(left_value, right_value);
        }
    }
    return out[0 .. left.len + right.len - 1];
}

fn makeGeneratorPoly(ecc_codewords: usize) [max_ecc_codewords + 1]u8 {
    var current: [max_ecc_codewords + 1]u8 = @splat(0);
    var scratch: [max_ecc_codewords + 1]u8 = @splat(0);
    var factor: [2]u8 = undefined;

    current[0] = 1;
    var current_len: usize = 1;

    for (0..ecc_codewords) |degree| {
        factor = .{ 1, gf.exp[degree] };
        const next = polyMul(current[0..current_len], &factor, scratch[0 .. current_len + 1]);
        @memcpy(current[0..next.len], next);
        current_len = next.len;
    }

    return current;
}

fn makeBaseMatrix(allocator: std.mem.Allocator, version: u8) Error!Matrix {
    const side_modules = try VersionDb.gridSizeForVersion(version);
    const len = @as(usize, side_modules) * side_modules;
    const modules = allocator.alloc(u8, len) catch return error.AllocatorFailure;
    errdefer allocator.free(modules);
    const is_function = allocator.alloc(u8, len) catch return error.AllocatorFailure;
    @memset(modules, 0);
    @memset(is_function, 0);

    drawFinder(modules, is_function, side_modules, 0, 0);
    drawFinder(modules, is_function, side_modules, side_modules - 7, 0);
    drawFinder(modules, is_function, side_modules, 0, side_modules - 7);
    drawTimingPatterns(modules, is_function, side_modules);
    drawAlignmentPatterns(modules, is_function, version, side_modules);
    reserveFormatAreas(modules, is_function, side_modules);
    if (version >= 7) reserveVersionAreas(modules, is_function, side_modules);
    setModule(modules, is_function, side_modules, 8, side_modules - 8, true);

    return .{
        .modules = modules,
        .is_function = is_function,
    };
}

fn setModule(modules: []u8, is_function: []u8, side: u16, x: usize, y: usize, value: bool) void {
    if (x >= side or y >= side) return;
    modules[y * side + x] = @intFromBool(value);
    is_function[y * side + x] = 1;
}

fn setModuleValue(modules: []u8, side: u16, x: usize, y: usize, value: bool) void {
    modules[y * side + x] = @intFromBool(value);
}

fn drawFinder(modules: []u8, is_function: []u8, side: u16, x0: usize, y0: usize) void {
    var dy: i32 = -1;
    while (dy <= 7) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 7) : (dx += 1) {
            const x = @as(i32, @intCast(x0)) + dx;
            const y = @as(i32, @intCast(y0)) + dy;
            if (x < 0 or y < 0 or x >= side or y >= side) continue;

            const in_core = dx >= 0 and dx <= 6 and dy >= 0 and dy <= 6;
            const value = in_core and (dx == 0 or dx == 6 or dy == 0 or dy == 6 or (dx >= 2 and dx <= 4 and dy >= 2 and dy <= 4));
            setModule(modules, is_function, side, @intCast(x), @intCast(y), value);
        }
    }
}

fn drawTimingPatterns(modules: []u8, is_function: []u8, side: u16) void {
    for (8..side - 8) |i| {
        setModule(modules, is_function, side, 6, i, (i & 1) == 0);
        setModule(modules, is_function, side, i, 6, (i & 1) == 0);
    }
}

fn drawAlignmentPatterns(modules: []u8, is_function: []u8, version: u8, side: u16) void {
    const positions = VersionDb.versions[version].alignmentPositions();
    if (positions.len == 0) return;

    for (positions, 0..) |row, row_index| {
        for (positions, 0..) |col, col_index| {
            if ((row_index == 0 and col_index == 0) or
                (row_index == 0 and col_index == positions.len - 1) or
                (row_index == positions.len - 1 and col_index == 0))
            {
                continue;
            }

            drawAlignment(modules, is_function, side, col, row);
        }
    }
}

fn drawAlignment(modules: []u8, is_function: []u8, side: u16, cx: usize, cy: usize) void {
    var dy: i32 = -2;
    while (dy <= 2) : (dy += 1) {
        var dx: i32 = -2;
        while (dx <= 2) : (dx += 1) {
            const x = @as(i32, @intCast(cx)) + dx;
            const y = @as(i32, @intCast(cy)) + dy;
            const value = @abs(dx) == 2 or @abs(dy) == 2 or (dx == 0 and dy == 0);
            setModule(modules, is_function, side, @intCast(x), @intCast(y), value);
        }
    }
}

fn reserveFormatAreas(modules: []u8, is_function: []u8, side: u16) void {
    for (0..9) |i| {
        if (i != 6) {
            setModule(modules, is_function, side, 8, i, false);
            setModule(modules, is_function, side, i, 8, false);
        }
    }

    for (0..8) |i| {
        setModule(modules, is_function, side, side - 1 - i, 8, false);
        if (i < 7) {
            setModule(modules, is_function, side, 8, side - 1 - i, false);
        }
    }
}

fn reserveVersionAreas(modules: []u8, is_function: []u8, side: u16) void {
    for (0..6) |y| {
        for (0..3) |x| {
            setModule(modules, is_function, side, side - 11 + x, y, false);
            setModule(modules, is_function, side, y, side - 11 + x, false);
        }
    }
}

fn drawCodewords(modules: []u8, is_function: []u8, side: u16, codewords: []const u8) void {
    var bit_index: usize = 0;
    var right: i32 = side - 1;

    while (right >= 1) : (right -= 2) {
        if (right == 6) right -= 1;

        for (0..side) |vert| {
            const upward = (((right + 1) & 2) == 0);
            const y = if (upward) side - 1 - vert else vert;

            for (0..2) |dx| {
                const x = @as(usize, @intCast(right)) - dx;
                if (is_function[y * side + x] != 0) continue;

                var bit: u1 = 0;
                if (bit_index < codewords.len * 8) {
                    const byte = codewords[bit_index >> 3];
                    bit = @intCast((byte >> @as(u3, @intCast(7 - (bit_index & 7)))) & 1);
                }
                modules[y * side + x] = bit;
                bit_index += 1;
            }
        }
    }
}

fn applyMask(modules: []u8, is_function: []const u8, side: u16, mask: u3) void {
    for (0..side) |y| {
        for (0..side) |x| {
            if (is_function[y * side + x] != 0) continue;
            if (maskBit(mask, @intCast(y), @intCast(x))) {
                modules[y * side + x] ^= 1;
            }
        }
    }
}

fn drawFormatBits(modules: []u8, side: u16, ecc_level: EccLevel, mask: u3) void {
    const bits = computeFormatBits(ecc_level, mask);

    for (0..6) |i| setModuleValue(modules, side, 8, i, ((bits >> @as(u4, @intCast(i))) & 1) != 0);
    setModuleValue(modules, side, 8, 7, ((bits >> 6) & 1) != 0);
    setModuleValue(modules, side, 8, 8, ((bits >> 7) & 1) != 0);
    setModuleValue(modules, side, 7, 8, ((bits >> 8) & 1) != 0);
    for (9..15) |i| setModuleValue(modules, side, 14 - i, 8, ((bits >> @as(u4, @intCast(i))) & 1) != 0);

    for (0..8) |i| setModuleValue(modules, side, side - 1 - i, 8, ((bits >> @as(u4, @intCast(i))) & 1) != 0);
    for (8..15) |i| setModuleValue(modules, side, 8, side - 15 + i, ((bits >> @as(u4, @intCast(i))) & 1) != 0);
    setModuleValue(modules, side, 8, side - 8, true);
}

fn drawVersionBits(modules: []u8, side: u16, version: u8) void {
    const bits = computeVersionBits(version);
    for (0..18) |i| {
        const bit = ((bits >> @as(u5, @intCast(i))) & 1) != 0;
        const a = side - 11 + (i % 3);
        const b = i / 3;
        setModuleValue(modules, side, a, b, bit);
        setModuleValue(modules, side, b, a, bit);
    }
}

fn computeFormatBits(ecc_level: EccLevel, mask: u3) u16 {
    const ecc_bits: u16 = switch (ecc_level) {
        .l => 0b01,
        .m => 0b00,
        .q => 0b11,
        .h => 0b10,
    };

    const data = (ecc_bits << 3) | mask;
    var bits = data << 10;
    var shift: i32 = 14;
    while (shift >= 10) : (shift -= 1) {
        if (((bits >> @as(u4, @intCast(shift))) & 1) != 0) {
            bits ^= format_poly << @as(u4, @intCast(shift - 10));
        }
    }
    return ((data << 10) | bits) ^ format_mask;
}

fn computeVersionBits(version: u8) u32 {
    var bits: u32 = @as(u32, version) << 12;
    var shift: i32 = 17;
    while (shift >= 12) : (shift -= 1) {
        if (((bits >> @as(u5, @intCast(shift))) & 1) != 0) {
            bits ^= version_poly << @as(u5, @intCast(shift - 12));
        }
    }
    return (@as(u32, version) << 12) | bits;
}

fn maskBit(mask: u3, i: i32, j: i32) bool {
    return switch (mask) {
        0 => @mod(i + j, 2) == 0,
        1 => @mod(i, 2) == 0,
        2 => @mod(j, 3) == 0,
        3 => @mod(i + j, 3) == 0,
        4 => @mod(@divTrunc(i, 2) + @divTrunc(j, 3), 2) == 0,
        5 => @mod(i * j, 2) + @mod(i * j, 3) == 0,
        6 => @mod(@mod(i * j, 2) + @mod(i * j, 3), 2) == 0,
        7 => @mod(@mod(i * j, 3) + @mod(i + j, 2), 2) == 0,
    };
}

fn penaltyScore(modules: []const u8, side: u16) i32 {
    var score: i32 = 0;
    score += penaltyRuns(modules, side);
    score += penaltyBlocks(modules, side);
    score += penaltyPatterns(modules, side);
    score += penaltyBalance(modules, side);
    return score;
}

fn penaltyRuns(modules: []const u8, side: u16) i32 {
    var score: i32 = 0;

    for (0..side) |y| {
        score += penaltyRuns1D(modules[y * side .. y * side + side]);
    }

    var column: [177]u8 = undefined;
    for (0..side) |x| {
        for (0..side) |y| column[y] = modules[y * side + x];
        score += penaltyRuns1D(column[0..side]);
    }

    return score;
}

fn penaltyRuns1D(line: []const u8) i32 {
    std.debug.assert(line.len > 0);

    var score: i32 = 0;
    var run_color = line[0];
    var run_len: usize = 1;
    for (line[1..]) |value| {
        if (value == run_color) {
            run_len += 1;
            continue;
        }
        if (run_len >= 5) score += 3 + @as(i32, @intCast(run_len - 5));
        run_color = value;
        run_len = 1;
    }
    if (run_len >= 5) score += 3 + @as(i32, @intCast(run_len - 5));
    return score;
}

fn penaltyBlocks(modules: []const u8, side: u16) i32 {
    var score: i32 = 0;
    for (0..side - 1) |y| {
        for (0..side - 1) |x| {
            const color = modules[y * side + x];
            if (modules[y * side + x + 1] == color and
                modules[(y + 1) * side + x] == color and
                modules[(y + 1) * side + x + 1] == color)
            {
                score += 3;
            }
        }
    }
    return score;
}

fn penaltyPatterns(modules: []const u8, side: u16) i32 {
    var score: i32 = 0;
    const pattern_a = [_]u8{ 1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0 };
    const pattern_b = [_]u8{ 0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1 };

    for (0..side) |y| {
        for (0..side - 10) |x| {
            const row = modules[y * side + x .. y * side + x + 11];
            if (std.mem.eql(u8, row, &pattern_a) or std.mem.eql(u8, row, &pattern_b)) score += 40;
        }
    }

    var column: [177]u8 = undefined;
    for (0..side) |x| {
        for (0..side) |y| column[y] = modules[y * side + x];
        for (0..side - 10) |y| {
            const slice = column[y .. y + 11];
            if (std.mem.eql(u8, slice, &pattern_a) or std.mem.eql(u8, slice, &pattern_b)) score += 40;
        }
    }

    return score;
}

fn penaltyBalance(modules: []const u8, _: u16) i32 {
    var dark: usize = 0;
    for (modules) |module| dark += module;
    const total = modules.len;
    const dark_pct_times_100 = (dark * 10000) / total;
    const deviation = if (dark_pct_times_100 > 5000) dark_pct_times_100 - 5000 else 5000 - dark_pct_times_100;
    const k: i32 = @intCast(deviation / 500);
    return k * 10;
}

const gf = makeGf();

fn makeGf() Gf {
    var exp: [512]u8 = @splat(0);
    var log: [256]u8 = @splat(0);
    var value: u16 = 1;
    for (0..255) |i| {
        exp[i] = @intCast(value);
        log[value] = @intCast(i);
        value <<= 1;
        if ((value & 0x100) != 0) value ^= 0x11D;
    }
    for (255..512) |i| exp[i] = exp[i - 255];
    return .{ .exp = exp, .log = log };
}

fn gfMul(left: u8, right: u8) u8 {
    if (left == 0 or right == 0) return 0;
    return gf.exp[@as(usize, gf.log[left]) + @as(usize, gf.log[right])];
}

fn makeCodeFromResult(result: Result) Detect.Code {
    var code: Detect.Code = .{ .size = result.symbol_modules };
    var bit_index: usize = 0;
    for (0..result.symbol_modules) |y| {
        for (0..result.symbol_modules) |x| {
            if (result.symbolModuleAt(x, y) != 0) {
                code.cells[bit_index >> 3] |= @as(u8, 1) << @as(u3, @intCast(bit_index & 7));
            }
            bit_index += 1;
        }
    }
    return code;
}

fn rasterizeModules(allocator: std.mem.Allocator, result: Result, scale: usize) ![]u8 {
    const side_pixels = @as(usize, result.side_modules) * scale;
    const pixels = try allocator.alloc(u8, side_pixels * side_pixels);
    @memset(pixels, 0xFF);

    for (0..result.side_modules) |y| {
        for (0..result.side_modules) |x| {
            const color: u8 = if (result.moduleAt(x, y) != 0) 0 else 0xFF;
            const x0 = x * scale;
            const y0 = y * scale;
            for (0..scale) |dy| {
                const row = (y0 + dy) * side_pixels;
                @memset(pixels[row + x0 .. row + x0 + scale], color);
            }
        }
    }

    return pixels;
}

test "encode roundtrips through decode for numeric alphanumeric and byte" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        payload: []const u8,
        options: Options,
    }{
        .{ .payload = "01234567", .options = .{ .mode = .numeric, .ecc_level = .l, .version = 1, .mask = .m0 } },
        .{ .payload = "HELLO WORLD", .options = .{ .mode = .alphanumeric, .ecc_level = .m } },
        .{ .payload = "quirc-v1", .options = .{ .mode = .byte, .ecc_level = .q } },
    };

    for (cases) |case| {
        var result = try encode(allocator, case.payload, case.options);
        defer result.deinit(allocator);

        const code = makeCodeFromResult(result);
        var zig_payload: [Spec.max_payload_bytes]u8 = undefined;
        const zig_decoded = try Decode.decode(&code, &zig_payload);
        try std.testing.expectEqualStrings(case.payload, zig_payload[0..zig_decoded.payload_len]);
    }
}

test "encode roundtrips through detect extract and decode" {
    const allocator = std.testing.allocator;
    var result = try encode(allocator, "QUIRC TEST", .{
        .mode = .alphanumeric,
        .ecc_level = .m,
        .quiet_zone_modules = 4,
    });
    defer result.deinit(allocator);

    const grayscale = try rasterizeModules(allocator, result, 8);
    defer allocator.free(grayscale);

    const scratch = try allocator.alloc(u8, Detect.scratchBytesForImage(@intCast(result.side_modules * 8), @intCast(result.side_modules * 8)));
    defer allocator.free(scratch);

    var zig_payload: [Spec.max_payload_bytes]u8 = undefined;
    const zig_decoded = try Detect.scanFirst(
        grayscale,
        scratch,
        @intCast(result.side_modules * 8),
        @intCast(result.side_modules * 8),
        &zig_payload,
    );

    try std.testing.expectEqualStrings("QUIRC TEST", zig_decoded);
}

test "auto version grows beyond version 1 capacity" {
    const allocator = std.testing.allocator;
    var result = try encode(allocator, "ABCDEFGHIJKLMNOPQR", .{
        .mode = .byte,
        .ecc_level = .l,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.version > 1);
}

test "mode resolution prefers numeric then alphanumeric then byte" {
    try std.testing.expectEqual(Mode.numeric, try resolveMode("12345", .auto));
    try std.testing.expectEqual(Mode.alphanumeric, try resolveMode("HELLO WORLD", .auto));
    try std.testing.expectEqual(Mode.byte, try resolveMode("hello-world", .auto));
    try std.testing.expectError(error.UnsupportedMode, resolveMode("hello", .numeric));
}

test "encode accepts empty byte payload and decodes back to empty" {
    const allocator = std.testing.allocator;
    var result = try encode(allocator, "", .{
        .mode = .byte,
        .ecc_level = .m,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(Mode.byte, result.mode);

    const code = makeCodeFromResult(result);
    var payload: [Spec.max_payload_bytes]u8 = undefined;
    const decoded = try Decode.decode(&code, &payload);
    try std.testing.expectEqual(@as(u16, 0), decoded.payload_len);
}

test "encode rejects invalid version and oversized explicit version" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidVersion, encode(allocator, "123", .{
        .mode = .numeric,
        .version = 0,
    }));

    try std.testing.expectError(error.PayloadTooLarge, encode(allocator, "ABCDEFGHIJKLMNOPQR", .{
        .mode = .byte,
        .ecc_level = .l,
        .version = 1,
    }));
}

test "fixed masks are honored and produce distinct module layouts" {
    const allocator = std.testing.allocator;
    var m0 = try encode(allocator, "MASK TEST", .{
        .mode = .alphanumeric,
        .ecc_level = .m,
        .version = 1,
        .mask = .m0,
    });
    defer m0.deinit(allocator);

    var m1 = try encode(allocator, "MASK TEST", .{
        .mode = .alphanumeric,
        .ecc_level = .m,
        .version = 1,
        .mask = .m1,
    });
    defer m1.deinit(allocator);

    try std.testing.expectEqual(@as(u3, 0), m0.mask);
    try std.testing.expectEqual(@as(u3, 1), m1.mask);
    try std.testing.expect(!std.mem.eql(u8, m0.modules, m1.modules));
}
