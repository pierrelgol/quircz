const std = @import("std");
const Detect = @import("Detect.zig");
const BitStream = @import("internal/BitStream.zig");
const ReedSolomon = @import("internal/ReedSolomon.zig");
const Spec = @import("internal/Spec.zig");
const VersionDb = @import("internal/VersionDb.zig");

const primary_format_xs = [_]usize{ 8, 8, 8, 8, 8, 8, 8, 8, 7, 5, 4, 3, 2, 1, 0 };
const primary_format_ys = [_]usize{ 0, 1, 2, 3, 4, 5, 7, 8, 8, 8, 8, 8, 8, 8, 8 };
const alpha_map = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

pub const EccLevel = enum(u2) {
    m = 0,
    l = 1,
    h = 2,
    q = 3,
};

pub const Mask = enum(u3) {
    m0 = 0,
    m1 = 1,
    m2 = 2,
    m3 = 3,
    m4 = 4,
    m5 = 5,
    m6 = 6,
    m7 = 7,
};

pub const Mode = enum(u4) {
    numeric = 1,
    alpha = 2,
    byte = 4,
    kanji = 8,
    eci = 7,
};

pub const Result = struct {
    version: u8 = 0,
    ecc_level: EccLevel = .m,
    mask: Mask = .m0,
    mode: ?Mode = null,
    eci: ?u32 = null,
    payload_len: u16 = 0,

    pub const FormatInfo = struct {
        ecc_level: EccLevel,
        mask: Mask,
    };

    pub fn readFormat(code: *const Detect.Code) Error!FormatInfo {
        return readFormatImpl(code);
    }

    pub fn decodePayload(
        version: u8,
        stream: *BitStream,
        out_payload: []u8,
    ) Error!Result {
        return decodePayloadImpl(version, stream, out_payload);
    }
};

pub const Error = error{
    InvalidGridSize,
    InvalidVersion,
    FormatEcc,
    DataEcc,
    UnknownDataType,
    DataOverflow,
    DataUnderflow,
    OutputTooSmall,
};

pub fn decode(
    code: *const Detect.Code,
    out_payload: []u8,
) Error!Result {
    const version = try VersionDb.versionForGridSize(code.size);
    const format = try readFormatImpl(code);
    var stream = try readDataWithVersion(code, version, format.mask);
    var corrected_storage: [Spec.max_payload_bytes]u8 = undefined;
    try stream.applyEcc(version, format.ecc_level, &corrected_storage);

    var result = try decodePayloadImpl(version, &stream, out_payload);
    result.version = version;
    result.ecc_level = format.ecc_level;
    result.mask = format.mask;
    return result;
}

pub fn readData(code: *const Detect.Code, mask: Mask) Error!BitStream {
    const version = try VersionDb.versionForGridSize(code.size);
    return readDataWithVersion(code, version, mask);
}

fn readDataWithVersion(code: *const Detect.Code, version: u8, mask: Mask) Error!BitStream {
    var stream = BitStream.initForVersion(version);

    var y: i32 = @intCast(code.size - 1);
    var x: i32 = @intCast(code.size - 1);
    var direction: i32 = -1;

    while (x > 0) {
        if (x == 6) {
            x -= 1;
        }

        if (!reservedCell(version, y, x)) {
            try readBit(code, mask, &stream, y, x);
        }

        if (!reservedCell(version, y, x - 1)) {
            try readBit(code, mask, &stream, y, x - 1);
        }

        y += direction;
        if (y < 0 or y >= code.size) {
            direction = -direction;
            x -= 2;
            y += direction;
        }
    }

    return stream;
}

fn readFormatImpl(code: *const Detect.Code) Error!Result.FormatInfo {
    const format0 = readFormatBits(code, false) ^ 0x5412;
    const format1 = readFormatBits(code, true) ^ 0x5412;

    const corrected0 = ReedSolomon.correctFormat(format0) catch null;
    const corrected1 = ReedSolomon.correctFormat(format1) catch null;
    const corrected = corrected0 orelse corrected1 orelse return error.FormatEcc;
    const format_data = corrected >> 10;

    return .{
        .ecc_level = @enumFromInt((format_data >> 3) & 0x3),
        .mask = @enumFromInt(format_data & 0x7),
    };
}

fn readFormatBits(code: *const Detect.Code, which: bool) u16 {
    var format: u16 = 0;

    if (which) {
        for (0..7) |i| {
            format = (format << 1) | code.gridBit(8, code.size - 1 - i);
        }
        for (0..8) |i| {
            format = (format << 1) | code.gridBit(code.size - 8 + i, 8);
        }
    } else {
        var i = primary_format_xs.len;
        while (i > 0) {
            i -= 1;
            format = (format << 1) | code.gridBit(primary_format_xs[i], primary_format_ys[i]);
        }
    }

    return format;
}

fn maskBit(mask: Mask, i: i32, j: i32) bool {
    return switch (mask) {
        .m0 => @mod(i + j, 2) == 0,
        .m1 => @mod(i, 2) == 0,
        .m2 => @mod(j, 3) == 0,
        .m3 => @mod(i + j, 3) == 0,
        .m4 => @mod(@divTrunc(i, 2) + @divTrunc(j, 3), 2) == 0,
        .m5 => @mod(i * j, 2) + @mod(i * j, 3) == 0,
        .m6 => @mod(@mod(i * j, 2) + @mod(i * j, 3), 2) == 0,
        .m7 => @mod(@mod(i * j, 3) + @mod(i + j, 2), 2) == 0,
    };
}

fn reservedCell(version: u8, i: i32, j: i32) bool {
    const info = &VersionDb.versions[version];
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
    for (info.alignmentPositions(), 0..) |position, idx| {
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

fn readBit(code: *const Detect.Code, mask: Mask, stream: *BitStream, i: i32, j: i32) Error!void {
    const bit_pos = stream.bit_len & 7;
    const byte_pos = stream.bit_len >> 3;
    const raw = stream.bytes();
    if (byte_pos >= raw.len) return error.DataOverflow;
    var value = code.gridBit(@intCast(j), @intCast(i));

    if (maskBit(mask, i, j)) {
        value ^= 1;
    }

    if (value != 0) {
        raw[byte_pos] |= @as(u8, 0x80) >> @as(u3, @intCast(bit_pos));
    }

    stream.bit_len += 1;
}

fn decodePayloadImpl(version: u8, stream: *BitStream, out_payload: []u8) Error!Result {
    var result: Result = .{ .version = version };

    while (stream.bitsRemaining() >= 4) {
        const mode_value: u4 = @intCast(try stream.takeBits(4));
        if (mode_value == 0) break;

        const mode = decodeModeValue(mode_value) orelse break;

        switch (mode) {
            .numeric => try decodeNumeric(version, stream, out_payload, &result),
            .alpha => try decodeAlpha(version, stream, out_payload, &result),
            .byte => try decodeByte(version, stream, out_payload, &result),
            .kanji => try decodeKanji(version, stream, out_payload, &result),
            .eci => try decodeEci(stream, &result),
        }

        updateResultMode(&result, mode);
    }

    if (result.payload_len < out_payload.len) {
        out_payload[result.payload_len] = 0;
    }

    return result;
}

fn decodeModeValue(mode_value: u4) ?Mode {
    return switch (mode_value) {
        1 => .numeric,
        2 => .alpha,
        4 => .byte,
        7 => .eci,
        8 => .kanji,
        else => null,
    };
}

fn updateResultMode(result: *Result, mode: Mode) void {
    if (mode == .eci) return;
    if (result.mode == null or @intFromEnum(mode) > @intFromEnum(result.mode.?)) {
        result.mode = mode;
    }
}

fn characterCountBits(mode: Mode, version: u8) u5 {
    return switch (mode) {
        .numeric => if (version < 10) 10 else if (version < 27) 12 else 14,
        .alpha => if (version < 10) 9 else if (version < 27) 11 else 13,
        .byte => if (version < 10) 8 else 16,
        .kanji => if (version < 10) 8 else if (version < 27) 10 else 12,
        .eci => 0,
    };
}

fn ensurePayloadCapacity(result: *const Result, out_payload: []u8, additional_len: usize) Error!void {
    if (result.payload_len + additional_len + 1 > out_payload.len) return error.OutputTooSmall;
}

fn decodeNumeric(version: u8, stream: *BitStream, out_payload: []u8, result: *Result) Error!void {
    const count_bits = characterCountBits(.numeric, version);
    var count = try stream.takeBits(count_bits);
    try ensurePayloadCapacity(result, out_payload, count);

    while (count >= 3) : (count -= 3) {
        try numericTuple(stream, out_payload, result, 10, 3);
    }
    if (count >= 2) {
        try numericTuple(stream, out_payload, result, 7, 2);
        count -= 2;
    }
    if (count == 1) {
        try numericTuple(stream, out_payload, result, 4, 1);
    }
}

fn numericTuple(stream: *BitStream, out_payload: []u8, result: *Result, bits: u5, digits: usize) Error!void {
    var tuple = try stream.takeBits(bits);
    var i: usize = digits;
    while (i > 0) {
        i -= 1;
        out_payload[result.payload_len + i] = @as(u8, @intCast(tuple % 10)) + '0';
        tuple /= 10;
    }
    result.payload_len += @intCast(digits);
}

fn decodeAlpha(version: u8, stream: *BitStream, out_payload: []u8, result: *Result) Error!void {
    const count_bits = characterCountBits(.alpha, version);
    var count = try stream.takeBits(count_bits);
    try ensurePayloadCapacity(result, out_payload, count);

    while (count >= 2) : (count -= 2) {
        try alphaTuple(stream, out_payload, result, 11, 2);
    }
    if (count == 1) {
        try alphaTuple(stream, out_payload, result, 6, 1);
    }
}

fn alphaTuple(stream: *BitStream, out_payload: []u8, result: *Result, bits: u5, digits: usize) Error!void {
    var tuple = try stream.takeBits(bits);

    for (0..digits) |i| {
        out_payload[result.payload_len + digits - i - 1] = alpha_map[tuple % 45];
        tuple /= 45;
    }

    result.payload_len += @intCast(digits);
}

fn decodeByte(version: u8, stream: *BitStream, out_payload: []u8, result: *Result) Error!void {
    const count_bits = characterCountBits(.byte, version);
    const count = try stream.takeBits(count_bits);
    try ensurePayloadCapacity(result, out_payload, count);
    if (stream.bitsRemaining() < count * 8) return error.DataUnderflow;

    for (0..count) |_| {
        out_payload[result.payload_len] = @intCast(try stream.takeBits(8));
        result.payload_len += 1;
    }
}

fn decodeKanji(version: u8, stream: *BitStream, out_payload: []u8, result: *Result) Error!void {
    const count_bits = characterCountBits(.kanji, version);
    const count = try stream.takeBits(count_bits);
    try ensurePayloadCapacity(result, out_payload, count * 2);
    if (stream.bitsRemaining() < count * 13) return error.DataUnderflow;

    for (0..count) |_| {
        const d = try stream.takeBits(13);
        const msb = d / 0xc0;
        const lsb = d % 0xc0;
        const intermediate = (msb << 8) | lsb;
        const shift_jis: u16 = if (intermediate + 0x8140 <= 0x9ffc)
            @intCast(intermediate + 0x8140)
        else
            @intCast(intermediate + 0xc140);

        out_payload[result.payload_len] = @intCast(shift_jis >> 8);
        out_payload[result.payload_len + 1] = @intCast(shift_jis & 0xff);
        result.payload_len += 2;
    }
}

fn decodeEci(stream: *BitStream, result: *Result) Error!void {
    if (stream.bitsRemaining() < 8) return error.DataUnderflow;

    var eci = try stream.takeBits(8);
    if ((eci & 0xc0) == 0x80) {
        if (stream.bitsRemaining() < 8) return error.DataUnderflow;
        eci = (eci << 8) | try stream.takeBits(8);
    } else if ((eci & 0xe0) == 0xc0) {
        if (stream.bitsRemaining() < 16) return error.DataUnderflow;
        eci = (eci << 16) | try stream.takeBits(16);
    }

    result.eci = eci;
}

fn appendBitsToStream(stream: *BitStream, value: u32, bit_count: u8) void {
    if (bit_count == 0) return;

    var shift: i32 = bit_count - 1;
    while (shift >= 0) : (shift -= 1) {
        const bit = (value >> @as(u5, @intCast(shift))) & 1;
        if (bit != 0) {
            stream.bytes()[stream.bit_len >> 3] |= @as(u8, 0x80) >> @as(u3, @intCast(stream.bit_len & 7));
        }
        stream.bit_len += 1;
    }
}

test "read data rejects invalid grid size" {
    const code: Detect.Code = .{ .size = 22 };
    try std.testing.expectError(error.InvalidGridSize, readData(&code, .m0));
}

test "read data includes QR remainder bits beyond version data bytes" {
    var code: Detect.Code = .{ .size = 21 };
    const stream = try readData(&code, .m0);
    try std.testing.expectEqual(try VersionDb.rawByteCapacity(1), stream.raw_len);
    try std.testing.expectEqual(@as(u32, try VersionDb.rawBitCount(1)), stream.bit_len);
}

test "read data uses version raw byte capacity" {
    var code: Detect.Code = .{ .size = 33 };
    const stream = try readData(&code, .m0);
    try std.testing.expectEqual(try VersionDb.rawByteCapacity(4), stream.raw_len);
    try std.testing.expectEqual(@as(u32, try VersionDb.rawBitCount(4)), stream.bit_len);
    try std.testing.expect(stream.bit_len > VersionDb.versions[4].total_data_bytes * 8);
}

test "format bit reader reads both format locations" {
    var code: Detect.Code = .{ .size = 21 };
    const format_bits: u16 = 0x1234;

    for (0..15) |idx| {
        const bit = (format_bits >> @as(u4, @intCast(idx))) & 1;
        const offset = primary_format_ys[idx] * code.size + primary_format_xs[idx];
        if (bit != 0) code.cells[offset >> 3] |= @as(u8, 1) << @as(u3, @intCast(offset & 7));
    }

    try std.testing.expectEqual(format_bits, readFormatBits(&code, false));
}

test "public readFormat decodes format info" {
    var encoded = try @import("Encode.zig").encode(std.testing.allocator, "01234567", .{
        .mode = .numeric,
        .ecc_level = .l,
        .version = 1,
        .mask = .m0,
    });
    defer encoded.deinit(std.testing.allocator);

    const code = blk: {
        var matrix: Detect.Code = .{ .size = encoded.symbol_modules };
        var bit_index: usize = 0;
        for (0..encoded.symbol_modules) |y| {
            for (0..encoded.symbol_modules) |x| {
                if (encoded.symbolModuleAt(x, y) != 0) {
                    matrix.cells[bit_index >> 3] |= @as(u8, 1) << @as(u3, @intCast(bit_index & 7));
                }
                bit_index += 1;
            }
        }
        break :blk matrix;
    };

    const format = try Result.readFormat(&code);
    try std.testing.expectEqual(EccLevel.l, format.ecc_level);
    try std.testing.expectEqual(Mask.m0, format.mask);
}

test "decode payload parses numeric payload with mixed tuple widths" {
    var stream = BitStream.init(8);
    appendBitsToStream(&stream, 0x1, 4);
    appendBitsToStream(&stream, 5, 10);
    appendBitsToStream(&stream, 123, 10);
    appendBitsToStream(&stream, 45, 7);
    appendBitsToStream(&stream, 0, 4);

    var out: [16]u8 = @splat(0);
    const result = try decodePayloadImpl(1, &stream, &out);

    try std.testing.expectEqual(@as(?Mode, .numeric), result.mode);
    try std.testing.expectEqual(@as(u16, 5), result.payload_len);
    try std.testing.expectEqualStrings("12345", out[0..result.payload_len]);
}

test "decode payload records ECI and byte payload in one stream" {
    var stream = BitStream.init(8);
    appendBitsToStream(&stream, 0x7, 4);
    appendBitsToStream(&stream, 26, 8);
    appendBitsToStream(&stream, 0x4, 4);
    appendBitsToStream(&stream, 3, 8);
    appendBitsToStream(&stream, 'A', 8);
    appendBitsToStream(&stream, 'B', 8);
    appendBitsToStream(&stream, 'C', 8);
    appendBitsToStream(&stream, 0, 4);

    var out: [16]u8 = @splat(0);
    const result = try decodePayloadImpl(1, &stream, &out);

    try std.testing.expectEqual(@as(?u32, 26), result.eci);
    try std.testing.expectEqual(@as(?Mode, .byte), result.mode);
    try std.testing.expectEqualStrings("ABC", out[0..result.payload_len]);
}

test "decode payload rejects unknown mode and output overflow" {
    var unknown = BitStream.init(2);
    appendBitsToStream(&unknown, 0xF, 4);
    var out: [8]u8 = @splat(0);
    const unknown_result = try decodePayloadImpl(1, &unknown, &out);
    try std.testing.expectEqual(@as(usize, 0), unknown_result.payload_len);

    var too_small = BitStream.init(8);
    appendBitsToStream(&too_small, 0x4, 4);
    appendBitsToStream(&too_small, 2, 8);
    appendBitsToStream(&too_small, 'O', 8);
    appendBitsToStream(&too_small, 'K', 8);
    appendBitsToStream(&too_small, 0, 4);
    var short: [1]u8 = @splat(0);
    try std.testing.expectError(error.OutputTooSmall, decodePayloadImpl(1, &too_small, &short));
}
