const std = @import("std");
const Decode = @import("../Decode.zig");

const max_poly = 64;
const format_max_error = 3;
const format_syndromes = format_max_error * 2;
const format_bits = 15;

const GaloisField = struct {
    p: usize,
    log: []const u8,
    exp: []const u8,
};

const gf16_exp = [_]u8{
    0x01, 0x02, 0x04, 0x08, 0x03, 0x06, 0x0c, 0x0b,
    0x05, 0x0a, 0x07, 0x0e, 0x0f, 0x0d, 0x09, 0x01,
};

const gf16_log = [_]u8{
    0x00, 0x0f, 0x01, 0x04, 0x02, 0x08, 0x05, 0x0a,
    0x03, 0x0e, 0x09, 0x07, 0x06, 0x0d, 0x0b, 0x0c,
};

const gf16 = GaloisField{
    .p = 15,
    .log = &gf16_log,
    .exp = &gf16_exp,
};

const gf256_exp = [_]u8{
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80,
    0x1d, 0x3a, 0x74, 0xe8, 0xcd, 0x87, 0x13, 0x26,
    0x4c, 0x98, 0x2d, 0x5a, 0xb4, 0x75, 0xea, 0xc9,
    0x8f, 0x03, 0x06, 0x0c, 0x18, 0x30, 0x60, 0xc0,
    0x9d, 0x27, 0x4e, 0x9c, 0x25, 0x4a, 0x94, 0x35,
    0x6a, 0xd4, 0xb5, 0x77, 0xee, 0xc1, 0x9f, 0x23,
    0x46, 0x8c, 0x05, 0x0a, 0x14, 0x28, 0x50, 0xa0,
    0x5d, 0xba, 0x69, 0xd2, 0xb9, 0x6f, 0xde, 0xa1,
    0x5f, 0xbe, 0x61, 0xc2, 0x99, 0x2f, 0x5e, 0xbc,
    0x65, 0xca, 0x89, 0x0f, 0x1e, 0x3c, 0x78, 0xf0,
    0xfd, 0xe7, 0xd3, 0xbb, 0x6b, 0xd6, 0xb1, 0x7f,
    0xfe, 0xe1, 0xdf, 0xa3, 0x5b, 0xb6, 0x71, 0xe2,
    0xd9, 0xaf, 0x43, 0x86, 0x11, 0x22, 0x44, 0x88,
    0x0d, 0x1a, 0x34, 0x68, 0xd0, 0xbd, 0x67, 0xce,
    0x81, 0x1f, 0x3e, 0x7c, 0xf8, 0xed, 0xc7, 0x93,
    0x3b, 0x76, 0xec, 0xc5, 0x97, 0x33, 0x66, 0xcc,
    0x85, 0x17, 0x2e, 0x5c, 0xb8, 0x6d, 0xda, 0xa9,
    0x4f, 0x9e, 0x21, 0x42, 0x84, 0x15, 0x2a, 0x54,
    0xa8, 0x4d, 0x9a, 0x29, 0x52, 0xa4, 0x55, 0xaa,
    0x49, 0x92, 0x39, 0x72, 0xe4, 0xd5, 0xb7, 0x73,
    0xe6, 0xd1, 0xbf, 0x63, 0xc6, 0x91, 0x3f, 0x7e,
    0xfc, 0xe5, 0xd7, 0xb3, 0x7b, 0xf6, 0xf1, 0xff,
    0xe3, 0xdb, 0xab, 0x4b, 0x96, 0x31, 0x62, 0xc4,
    0x95, 0x37, 0x6e, 0xdc, 0xa5, 0x57, 0xae, 0x41,
    0x82, 0x19, 0x32, 0x64, 0xc8, 0x8d, 0x07, 0x0e,
    0x1c, 0x38, 0x70, 0xe0, 0xdd, 0xa7, 0x53, 0xa6,
    0x51, 0xa2, 0x59, 0xb2, 0x79, 0xf2, 0xf9, 0xef,
    0xc3, 0x9b, 0x2b, 0x56, 0xac, 0x45, 0x8a, 0x09,
    0x12, 0x24, 0x48, 0x90, 0x3d, 0x7a, 0xf4, 0xf5,
    0xf7, 0xf3, 0xfb, 0xeb, 0xcb, 0x8b, 0x0b, 0x16,
    0x2c, 0x58, 0xb0, 0x7d, 0xfa, 0xe9, 0xcf, 0x83,
    0x1b, 0x36, 0x6c, 0xd8, 0xad, 0x47, 0x8e, 0x01,
};

const gf256_log = [_]u8{
    0x00, 0xff, 0x01, 0x19, 0x02, 0x32, 0x1a, 0xc6,
    0x03, 0xdf, 0x33, 0xee, 0x1b, 0x68, 0xc7, 0x4b,
    0x04, 0x64, 0xe0, 0x0e, 0x34, 0x8d, 0xef, 0x81,
    0x1c, 0xc1, 0x69, 0xf8, 0xc8, 0x08, 0x4c, 0x71,
    0x05, 0x8a, 0x65, 0x2f, 0xe1, 0x24, 0x0f, 0x21,
    0x35, 0x93, 0x8e, 0xda, 0xf0, 0x12, 0x82, 0x45,
    0x1d, 0xb5, 0xc2, 0x7d, 0x6a, 0x27, 0xf9, 0xb9,
    0xc9, 0x9a, 0x09, 0x78, 0x4d, 0xe4, 0x72, 0xa6,
    0x06, 0xbf, 0x8b, 0x62, 0x66, 0xdd, 0x30, 0xfd,
    0xe2, 0x98, 0x25, 0xb3, 0x10, 0x91, 0x22, 0x88,
    0x36, 0xd0, 0x94, 0xce, 0x8f, 0x96, 0xdb, 0xbd,
    0xf1, 0xd2, 0x13, 0x5c, 0x83, 0x38, 0x46, 0x40,
    0x1e, 0x42, 0xb6, 0xa3, 0xc3, 0x48, 0x7e, 0x6e,
    0x6b, 0x3a, 0x28, 0x54, 0xfa, 0x85, 0xba, 0x3d,
    0xca, 0x5e, 0x9b, 0x9f, 0x0a, 0x15, 0x79, 0x2b,
    0x4e, 0xd4, 0xe5, 0xac, 0x73, 0xf3, 0xa7, 0x57,
    0x07, 0x70, 0xc0, 0xf7, 0x8c, 0x80, 0x63, 0x0d,
    0x67, 0x4a, 0xde, 0xed, 0x31, 0xc5, 0xfe, 0x18,
    0xe3, 0xa5, 0x99, 0x77, 0x26, 0xb8, 0xb4, 0x7c,
    0x11, 0x44, 0x92, 0xd9, 0x23, 0x20, 0x89, 0x2e,
    0x37, 0x3f, 0xd1, 0x5b, 0x95, 0xbc, 0xcf, 0xcd,
    0x90, 0x87, 0x97, 0xb2, 0xdc, 0xfc, 0xbe, 0x61,
    0xf2, 0x56, 0xd3, 0xab, 0x14, 0x2a, 0x5d, 0x9e,
    0x84, 0x3c, 0x39, 0x53, 0x47, 0x6d, 0x41, 0xa2,
    0x1f, 0x2d, 0x43, 0xd8, 0xb7, 0x7b, 0xa4, 0x76,
    0xc4, 0x17, 0x49, 0xec, 0x7f, 0x0c, 0x6f, 0xf6,
    0x6c, 0xa1, 0x3b, 0x52, 0x29, 0x9d, 0x55, 0xaa,
    0xfb, 0x60, 0x86, 0xb1, 0xbb, 0xcc, 0x3e, 0x5a,
    0xcb, 0x59, 0x5f, 0xb0, 0x9c, 0xa9, 0xa0, 0x51,
    0x0b, 0xf5, 0x16, 0xeb, 0x7a, 0x75, 0x2c, 0xd7,
    0x4f, 0xae, 0xd5, 0xe9, 0xe6, 0xe7, 0xad, 0xe8,
    0x74, 0xd6, 0xf4, 0xea, 0xa8, 0x50, 0x58, 0xaf,
};

const gf256 = GaloisField{
    .p = 255,
    .log = &gf256_log,
    .exp = &gf256_exp,
};

pub fn correctFormat(format_value: u16) Decode.Error!u16 {
    var value = format_value;
    var syndromes: [max_poly]u8 = @splat(0);
    var sigma: [max_poly]u8 = @splat(0);

    if (!formatSyndromes(value, &syndromes)) {
        return value;
    }

    berlekampMassey(syndromes[0..format_syndromes], &gf16, &sigma);

    for (0..format_bits) |i| {
        if (polyEval(&sigma, gf16_exp[15 - i], &gf16) == 0) {
            value ^= @as(u16, 1) << @as(u4, @intCast(i));
        }
    }

    if (formatSyndromes(value, &syndromes)) {
        return error.FormatEcc;
    }

    return value;
}

pub fn correctBlock(block: []u8, data_words: usize) Decode.Error!void {
    const block_size = block.len;
    const parity_words = block_size - data_words;
    var syndromes: [max_poly]u8 = @splat(0);
    var sigma: [max_poly]u8 = @splat(0);
    var sigma_derivative: [max_poly]u8 = @splat(0);
    var omega: [max_poly]u8 = @splat(0);

    if (!blockSyndromes(block, parity_words, &syndromes)) {
        return;
    }

    berlekampMassey(syndromes[0..parity_words], &gf256, &sigma);

    @memset(&sigma_derivative, 0);
    for (0..(max_poly - 1) / 2) |i| {
        const even_index = i * 2;
        if (even_index + 1 >= max_poly) break;
        sigma_derivative[even_index] = sigma[even_index + 1];
    }

    errorLocatorEvaluator(syndromes[0..], sigma[0..], omega[0..parity_words], parity_words - 1);

    for (0..block_size) |index| {
        const xinv = gf256_exp[255 - index];

        if (polyEval(&sigma, xinv, &gf256) == 0) {
            const sd_x = polyEval(&sigma_derivative, xinv, &gf256);
            const omega_x = polyEval(&omega, xinv, &gf256);
            const magnitude = fieldDiv(omega_x, sd_x, &gf256);
            block[block_size - index - 1] ^= magnitude;
        }
    }

    if (blockSyndromes(block, parity_words, &syndromes)) {
        return error.DataEcc;
    }
}

pub fn blockSyndromes(block: []const u8, parity_words: usize, syndromes: []u8) bool {
    std.debug.assert(parity_words <= syndromes.len);
    std.debug.assert(block.len > 0);
    @memset(syndromes, 0);
    var nonzero = false;
    for (0..parity_words) |i| {
        var acc: u8 = 0;
        var j: usize = 0;
        while (j < block.len) : (j += 1) {
            if (acc != 0) acc = gf256_exp[(@as(usize, gf256_log[acc]) + i) % 255];
            acc ^= block[j];
        }
        syndromes[i] = acc;
        if (acc != 0) nonzero = true;
    }
    return nonzero;
}

pub fn berlekampMassey(syndromes: []const u8, gf: *const GaloisField, sigma: []u8) void {
    std.debug.assert(syndromes.len > 0);
    std.debug.assert(sigma.len >= syndromes.len);
    var c: [max_poly]u8 = @splat(0);
    var b: [max_poly]u8 = @splat(0);
    var length: usize = 0;
    var shift: usize = 1;
    var discrepancy_scale: u8 = 1;

    b[0] = 1;
    c[0] = 1;

    for (0..syndromes.len) |n| {
        var discrepancy = syndromes[n];

        var i: usize = 1;
        while (i <= length) : (i += 1) {
            if (c[i] == 0 or syndromes[n - i] == 0) continue;
            discrepancy ^= fieldMul(c[i], syndromes[n - i], gf);
        }

        if (discrepancy == 0) {
            shift += 1;
            continue;
        }

        const mult = fieldDiv(discrepancy, discrepancy_scale, gf);
        if (length * 2 <= n) {
            const t = c;
            polyAdd(&c, &b, mult, shift, gf);
            b = t;
            length = n + 1 - length;
            discrepancy_scale = discrepancy;
            shift = 1;
        } else {
            polyAdd(&c, &b, mult, shift, gf);
            shift += 1;
        }
    }

    std.mem.copyForwards(u8, sigma, c[0..sigma.len]);
}

pub fn errorLocatorEvaluator(syndromes: []const u8, sigma: []const u8, omega: []u8, parity_words: usize) void {
    @memset(omega, 0);

    for (0..parity_words) |i| {
        const a = sigma[i];
        if (a == 0) continue;

        var j: usize = 0;
        while (j + 1 < max_poly) : (j += 1) {
            if (i + j >= parity_words) break;
            const b = syndromes[j + 1];
            if (b == 0) continue;
            omega[i + j] ^= fieldMul(a, b, &gf256);
        }
    }
}

fn polyAdd(dst: *[max_poly]u8, src: *const [max_poly]u8, coefficient: u8, shift: usize, gf: *const GaloisField) void {
    if (coefficient == 0) return;

    for (0..max_poly) |i| {
        const value = src[i];
        const position = i + shift;
        if (position >= max_poly) break;
        if (value == 0) continue;

        dst[position] ^= fieldMul(value, coefficient, gf);
    }
}

fn fieldMul(left: u8, right: u8, gf: *const GaloisField) u8 {
    if (left == 0 or right == 0) return 0;
    return gf.exp[(@as(usize, gf.log[left]) + @as(usize, gf.log[right])) % gf.p];
}

fn fieldDiv(numerator: u8, denominator: u8, gf: *const GaloisField) u8 {
    std.debug.assert(denominator != 0);
    if (numerator == 0) return 0;
    return gf.exp[(gf.p - @as(usize, gf.log[denominator]) + @as(usize, gf.log[numerator])) % gf.p];
}

fn polyEval(polynomial: *const [max_poly]u8, x: u8, gf: *const GaloisField) u8 {
    if (x == 0) return polynomial[0];
    const log_x: usize = gf.log[x];
    var acc: u8 = 0;
    var i: usize = max_poly;
    while (i > 0) {
        i -= 1;
        if (acc != 0) acc = gf.exp[(@as(usize, gf.log[acc]) + log_x) % gf.p];
        acc ^= polynomial[i];
    }
    return acc;
}

fn formatSyndromes(value: u16, syndromes: *[max_poly]u8) bool {
    @memset(syndromes, 0);
    var nonzero = false;

    for (0..format_syndromes) |i| {
        for (0..format_bits) |j| {
            if ((value & (@as(u16, 1) << @as(u4, @intCast(j)))) != 0) {
                syndromes[i] ^= gf16_exp[((i + 1) * j) % 15];
            }
        }
        if (syndromes[i] != 0) {
            nonzero = true;
        }
    }

    return nonzero;
}

test "correct format leaves known codeword unchanged" {
    try std.testing.expectEqual(@as(u16, 0), try correctFormat(0));
}

test "correct format repairs up to three flipped bits on zero codeword" {
    try std.testing.expectEqual(@as(u16, 0), try correctFormat(0b1));
    try std.testing.expectEqual(@as(u16, 0), try correctFormat(0b101));
    try std.testing.expectEqual(@as(u16, 0), try correctFormat(0b100101));
}

test "correct format rejects four flipped bits on zero codeword" {
    try std.testing.expectError(error.FormatEcc, correctFormat(0b1111));
}

test "blockSyndromes is stable across two identical calls" {
    var syndromes1: [max_poly]u8 = @splat(0);
    var syndromes2: [max_poly]u8 = @splat(0);
    const block = [_]u8{ 1, 2, 3, 4, 5, 6, 7 };
    _ = blockSyndromes(&block, 4, &syndromes1);
    _ = blockSyndromes(&block, 4, &syndromes2);
    try std.testing.expectEqualSlices(u8, &syndromes1, &syndromes2);
}

test "polyEval zero polynomial returns 0" {
    const poly: [max_poly]u8 = @splat(0);
    try std.testing.expectEqual(@as(u8, 0), polyEval(&poly, 5, &gf256));
    try std.testing.expectEqual(@as(u8, 0), polyEval(&poly, 0, &gf256));
}

test "polyEval constant-only polynomial returns constant for any x" {
    var poly: [max_poly]u8 = @splat(0);
    poly[0] = 42;
    try std.testing.expectEqual(@as(u8, 42), polyEval(&poly, 0, &gf256));
    try std.testing.expectEqual(@as(u8, 42), polyEval(&poly, 7, &gf256));
    try std.testing.expectEqual(@as(u8, 42), polyEval(&poly, 255, &gf256));
}

test "block syndromes distinguish clean and dirty all-zero blocks" {
    var syndromes: [max_poly]u8 = @splat(0);
    const clean = [_]u8{ 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expect(!blockSyndromes(&clean, 4, &syndromes));

    const dirty = [_]u8{ 0, 0, 1, 0, 0, 0, 0 };
    try std.testing.expect(blockSyndromes(&dirty, 4, &syndromes));
}

test "correct block repairs a single error in an all-zero codeword" {
    var block = [_]u8{ 0, 0, 0, 0, 0, 0, 0 };
    block[2] = 1;

    try correctBlock(&block, 3);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0 }, &block);
}
