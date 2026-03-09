const std = @import("std");

const Decode = @import("../Decode.zig");
const ReedSolomon = @import("ReedSolomon.zig");
const Spec = @import("Spec.zig");
const VersionDb = @import("VersionDb.zig");
const max_block_bytes = VersionDb.max_block_bytes;

const BitStream = @This();

const Storage = enum {
    raw,
    corrected,
};

raw_storage: [Spec.max_payload_bytes]u8 = @splat(0),
storage: Storage = .raw,
raw_len: usize = 0,
active_len: usize = 0,
corrected_storage: ?[*]u8 = null,
bit_len: u32 = 0,
bit_offset: u32 = 0,

pub fn init(byte_len: usize) BitStream {
    var self: BitStream = .{};
    self.raw_len = byte_len;
    self.active_len = byte_len;
    @memset(self.raw_storage[0..byte_len], 0);
    return self;
}

pub fn initForVersion(version: u8) BitStream {
    return init(VersionDb.raw_byte_capacities[version]);
}

pub fn bytes(self: *BitStream) []u8 {
    return self.activeStorage()[0..self.activeLen()];
}

pub fn bytesConst(self: *const BitStream) []const u8 {
    return self.activeStorageConst()[0..self.activeLen()];
}

fn activeLen(self: *const BitStream) usize {
    return self.active_len;
}

pub fn bitsRemaining(self: *const BitStream) u32 {
    return self.bit_len -| self.bit_offset;
}

fn activeStorage(self: *BitStream) []u8 {
    return switch (self.storage) {
        .raw => &self.raw_storage,
        .corrected => self.corrected_storage.?[0..Spec.max_payload_bytes],
    };
}

fn activeStorageConst(self: *const BitStream) []const u8 {
    return switch (self.storage) {
        .raw => &self.raw_storage,
        .corrected => self.corrected_storage.?[0..Spec.max_payload_bytes],
    };
}

pub fn takeBits(self: *BitStream, bit_count: u5) Decode.Error!u32 {
    if (bit_count == 0) {
        return 0;
    }

    const remaining = self.bitsRemaining();
    if (remaining < bit_count) {
        self.bit_offset = self.bit_len;
        return error.DataUnderflow;
    }

    const active_bytes = self.bytesConst();
    const byte_index = self.bit_offset >> 3;
    const bit_in_byte: u5 = @intCast(self.bit_offset & 7);
    const needed_bits = bit_in_byte + bit_count;
    const needed_bytes = @as(usize, @intCast((needed_bits + 7) >> 3));
    var acc: u32 = 0;

    for (0..needed_bytes) |i| {
        acc = (acc << 8) | active_bytes[byte_index + i];
    }

    const total_bits = needed_bytes * 8;
    const shift = total_bits - bit_in_byte - bit_count;
    const mask = (@as(u32, 1) << bit_count) - 1;
    self.bit_offset += bit_count;
    return (acc >> @as(u5, @intCast(shift))) & mask;
}

pub fn applyEcc(
    self: *BitStream,
    version: u8,
    ecc_level: Decode.EccLevel,
    corrected_storage: []u8,
) Decode.Error!void {
    const info = VersionDb.versions[version];
    std.debug.assert(corrected_storage.len >= info.total_data_bytes);
    const small = info.ecc[@intFromEnum(ecc_level)];
    const large_block_count = (info.total_data_bytes - small.block_bytes * small.small_block_count) / (small.block_bytes + 1);
    const block_count = large_block_count + small.small_block_count;
    const ecc_offset = small.data_bytes * block_count + large_block_count;
    const raw = self.bytesConst();
    var dst_offset: usize = 0;
    var block: [max_block_bytes]u8 = undefined;

    for (0..small.small_block_count) |block_index| {
        try correctInterleavedBlock(
            raw,
            corrected_storage,
            &dst_offset,
            &block,
            block_count,
            ecc_offset,
            block_index,
            small.block_bytes,
            small.data_bytes,
        );
    }

    if (large_block_count != 0) {
        const large_block_bytes = small.block_bytes + 1;
        const large_data_bytes = small.data_bytes + 1;
        for (0..large_block_count) |large_index| {
            try correctInterleavedBlock(
                raw,
                corrected_storage,
                &dst_offset,
                &block,
                block_count,
                ecc_offset,
                small.small_block_count + large_index,
                large_block_bytes,
                large_data_bytes,
            );
        }
    }

    self.setCorrected(corrected_storage, dst_offset);
}

fn correctInterleavedBlock(
    raw: []const u8,
    corrected_storage: []u8,
    dst_offset: *usize,
    block: *[max_block_bytes]u8,
    block_count: usize,
    ecc_offset: usize,
    block_index: usize,
    block_bytes: usize,
    data_bytes: usize,
) Decode.Error!void {
    const ec_words = block_bytes - data_bytes;

    var src_index = block_index;
    for (0..data_bytes) |j| {
        block[j] = raw[src_index];
        src_index += block_count;
    }

    src_index = ecc_offset + block_index;
    for (0..ec_words) |j| {
        block[data_bytes + j] = raw[src_index];
        src_index += block_count;
    }

    try ReedSolomon.correctBlock(block[0..block_bytes], data_bytes);

    @memcpy(corrected_storage[dst_offset.* .. dst_offset.* + data_bytes], block[0..data_bytes]);
    dst_offset.* += data_bytes;
}

fn setCorrected(self: *BitStream, corrected_storage: []u8, corrected_len: usize) void {
    self.corrected_storage = corrected_storage.ptr;
    self.storage = .corrected;
    self.active_len = corrected_len;
    self.bit_len = @intCast(corrected_len * 8);
    self.bit_offset = 0;
}

test "bitsRemaining saturates when offset exceeds length" {
    var stream = BitStream.init(1);
    stream.bit_len = 3;
    stream.bit_offset = 10;

    try std.testing.expectEqual(@as(u32, 0), stream.bitsRemaining());
}

test "init constrains raw slice to requested byte length" {
    var stream = BitStream.init(3);
    try std.testing.expectEqual(@as(usize, 3), stream.bytesConst().len);
    for (stream.bytesConst()) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "takeBits crosses byte boundaries and zero-bit reads are no-ops" {
    var stream = BitStream.init(2);
    const raw = stream.bytes();
    raw[0] = 0b1010_1100;
    raw[1] = 0b0110_0000;
    stream.bit_len = 12;

    try std.testing.expectEqual(@as(u32, 0), try stream.takeBits(0));
    try std.testing.expectEqual(@as(u32, 0b1010), try stream.takeBits(4));
    try std.testing.expectEqual(@as(u32, 0b11000110), try stream.takeBits(8));
    try std.testing.expectEqual(@as(u32, 12), stream.bit_offset);
}

test "takeBits handles aligned byte and mixed-width reads" {
    var stream = BitStream.init(4);
    const raw = stream.bytes();
    raw[0] = 0xAB;
    raw[1] = 0xCD;
    raw[2] = 0xE0;
    stream.bit_len = 20;

    try std.testing.expectEqual(@as(u32, 0xAB), try stream.takeBits(8));
    try std.testing.expectEqual(@as(u32, 0xCDE), try stream.takeBits(12));
    try std.testing.expectEqual(@as(u32, 20), stream.bit_offset);
}

test "takeBits underflow consumes available bits then errors" {
    var stream = BitStream.init(1);
    stream.bytes()[0] = 0b1100_0000;
    stream.bit_len = 2;

    try std.testing.expectError(error.DataUnderflow, stream.takeBits(3));
    try std.testing.expectEqual(@as(u32, 2), stream.bit_offset);
}

test "applyEcc on all-zero codewords shrinks to version data bytes and resets offsets" {
    var stream = BitStream.init(VersionDb.versions[1].total_data_bytes);
    stream.bit_len = @as(u32, VersionDb.versions[1].total_data_bytes) * 8;
    stream.bit_offset = 13;
    var corrected: [Spec.max_payload_bytes]u8 = undefined;

    try stream.applyEcc(1, .l, &corrected);

    try std.testing.expectEqual(@as(u32, 0), stream.bit_offset);
    try std.testing.expectEqual(@as(u32, 19 * 8), stream.bit_len);
    try std.testing.expectEqual(@as(usize, 19), stream.bytesConst().len);
    for (stream.bytesConst()) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "initForVersion uses version raw byte capacity" {
    var stream = BitStream.initForVersion(1);
    try std.testing.expectEqual(try VersionDb.rawByteCapacity(1), stream.raw_len);
    try std.testing.expectEqual(try VersionDb.rawByteCapacity(1), stream.bytesConst().len);
}

test "corrected view length is independent from raw length" {
    var stream = BitStream.init(26);
    var corrected: [Spec.max_payload_bytes]u8 = @splat(0);
    corrected[0] = 0xAB;
    corrected[1] = 0xCD;
    stream.setCorrected(&corrected, 2);

    try std.testing.expectEqual(@as(usize, 26), stream.raw_len);
    try std.testing.expectEqual(@as(usize, 2), stream.bytesConst().len);
    try std.testing.expectEqualSlices(u8, &.{ 0xAB, 0xCD }, stream.bytesConst());
}
