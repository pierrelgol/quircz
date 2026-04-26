const std = @import("std");
const quircz = @import("quircz");

const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

const max_grids = 64;
const max_payload_bytes = 8896;
const max_zip_comment_len = 0xffff;

const ZipEntry = struct {
    name: []const u8,
    method: u16,
    compressed_size: u32,
    uncompressed_size: u32,
    local_header_offset: u32,
};

pub fn main(init: std.process.Init) !void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.skip(); // program name
    const path = args_iter.next() orelse "demo/zen.zip";

    const zip_data = try Dir.cwd().readFileAlloc(init.io, path, init.gpa, .unlimited);
    defer init.gpa.free(zip_data);

    const data = try readZipEntryAlloc(init.gpa, zip_data, "zen.bmp");
    defer init.gpa.free(data);

    if (data.len < 54 or data[0] != 'B' or data[1] != 'M') {
        return error.InvalidBmp;
    }

    const pixel_offset = std.mem.readInt(u32, data[10..14], .little);
    const width_i = std.mem.readInt(i32, data[18..22], .little);
    const height_i = std.mem.readInt(i32, data[22..26], .little);
    const bit_count = std.mem.readInt(u16, data[28..30], .little);

    if (bit_count != 24 and bit_count != 32) return error.UnsupportedBitDepth;

    const width: u32 = @intCast(width_i);
    const height: u32 = @intCast(if (height_i < 0) -height_i else height_i);
    const top_down = height_i < 0;
    const bytes_per_pixel: u32 = bit_count / 8;
    const row_stride: u32 = (width * bytes_per_pixel + 3) & ~@as(u32, 3);

    const grayscale = try init.gpa.alloc(u8, @as(usize, width) * height);
    defer init.gpa.free(grayscale);

    for (0..height) |y| {
        const src_y: usize = if (top_down) y else height - 1 - y;
        const row_start = pixel_offset + src_y * row_stride;
        const src_row = data[row_start .. row_start + width * bytes_per_pixel];
        const dst_row = grayscale[y * width ..][0..width];
        for (0..width) |x| {
            const b = src_row[x * bytes_per_pixel + 0];
            const g = src_row[x * bytes_per_pixel + 1];
            const r = src_row[x * bytes_per_pixel + 2];
            dst_row[x] = @intCast((@as(u32, r) * 77 + @as(u32, g) * 150 + @as(u32, b) * 29) >> 8);
        }
    }

    const scratch = try init.gpa.alloc(u8, quircz.scratchBytesForImage(width, height));
    defer init.gpa.free(scratch);

    var detect = quircz.Detect.init(grayscale, scratch, width, height);
    var detections: [max_grids]quircz.Detect.Detection = undefined;
    const found = try detect.scan(&detections);

    var out_buf: [4096]u8 = undefined;
    var stdout = File.stdout().writer(init.io, &out_buf);
    defer stdout.flush() catch {};

    if (found.len == 0) {
        try stdout.interface.print("no QR codes found in {s}\n", .{path});
        return;
    }

    try stdout.interface.print("found {} QR code(s) in {s}\n\n", .{ found.len, path });

    var payload: [max_payload_bytes]u8 = undefined;

    for (found, 0..) |*detection, i| {
        const code = detect.extract(detection) catch |err| {
            try stdout.interface.print("[{}] extract failed: {}\n", .{ i + 1, err });
            continue;
        };
        const result = quircz.Decode.decode(&code, &payload) catch |err| {
            try stdout.interface.print("[{}] decode failed: {}\n", .{ i + 1, err });
            continue;
        };
        try stdout.interface.print("[{}] {s}\n", .{ i + 1, payload[0..result.payload_len] });
    }
}

fn readZipEntryAlloc(allocator: std.mem.Allocator, zip_data: []const u8, entry_name: []const u8) ![]u8 {
    const entry = try findZipEntry(zip_data, entry_name);
    const compressed = try zipEntryData(zip_data, entry);

    const data = try allocator.alloc(u8, entry.uncompressed_size);
    errdefer allocator.free(data);

    switch (entry.method) {
        0 => {
            if (compressed.len != data.len) return error.ZipSizeMismatch;
            @memcpy(data, compressed);
        },
        8 => {
            var compressed_reader: Io.Reader = .fixed(compressed);
            var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress: std.compress.flate.Decompress = .init(&compressed_reader, .raw, &flate_buffer);
            var data_writer: Io.Writer = .fixed(data);
            decompress.reader.streamExact64(&data_writer, entry.uncompressed_size) catch |err| switch (err) {
                error.ReadFailed => return decompress.err.?,
                error.WriteFailed => return error.ZipSizeMismatch,
                else => |e| return e,
            };
            if (data_writer.end != data.len) return error.ZipSizeMismatch;
        },
        else => return error.UnsupportedZipCompression,
    }

    return data;
}

fn findZipEntry(zip_data: []const u8, entry_name: []const u8) !ZipEntry {
    const eocd_offset = try findEndOfCentralDirectory(zip_data);
    const record = zip_data[eocd_offset..];
    const entry_count = readU16(record, 10);
    const central_dir_size = readU32(record, 12);
    const central_dir_offset = readU32(record, 16);

    const cd_start: usize = central_dir_offset;
    const cd_size: usize = central_dir_size;
    if (cd_start > zip_data.len or cd_size > zip_data.len - cd_start) return error.ZipTruncated;

    var offset = cd_start;
    for (0..entry_count) |_| {
        if (offset + 46 > zip_data.len) return error.ZipTruncated;
        const header = zip_data[offset..];
        if (!std.mem.eql(u8, header[0..4], "PK\x01\x02")) return error.InvalidZip;

        const method = readU16(header, 10);
        const compressed_size = readU32(header, 20);
        const uncompressed_size = readU32(header, 24);
        const name_len = readU16(header, 28);
        const extra_len = readU16(header, 30);
        const comment_len = readU16(header, 32);
        const local_header_offset = readU32(header, 42);

        const name_start = offset + 46;
        const name_end = name_start + name_len;
        if (name_end > zip_data.len) return error.ZipTruncated;

        if (std.mem.eql(u8, zip_data[name_start..name_end], entry_name)) {
            return .{
                .name = zip_data[name_start..name_end],
                .method = method,
                .compressed_size = compressed_size,
                .uncompressed_size = uncompressed_size,
                .local_header_offset = local_header_offset,
            };
        }

        offset = name_end + extra_len + comment_len;
        if (offset > zip_data.len) return error.ZipTruncated;
    }

    return error.ZipEntryNotFound;
}

fn zipEntryData(zip_data: []const u8, entry: ZipEntry) ![]const u8 {
    const offset: usize = entry.local_header_offset;
    if (offset + 30 > zip_data.len) return error.ZipTruncated;

    const header = zip_data[offset..];
    if (!std.mem.eql(u8, header[0..4], "PK\x03\x04")) return error.InvalidZip;
    const name_len = readU16(header, 26);
    const extra_len = readU16(header, 28);

    const data_start = offset + 30 + name_len + extra_len;
    const data_len: usize = entry.compressed_size;
    if (data_start > zip_data.len or data_len > zip_data.len - data_start) return error.ZipTruncated;
    return zip_data[data_start..][0..data_len];
}

fn findEndOfCentralDirectory(zip_data: []const u8) !usize {
    if (zip_data.len < 22) return error.ZipTruncated;

    const min_offset = zip_data.len - @min(zip_data.len, 22 + max_zip_comment_len);
    var offset = zip_data.len - 22;
    while (true) {
        if (std.mem.eql(u8, zip_data[offset..][0..4], "PK\x05\x06")) return offset;
        if (offset == min_offset) break;
        offset -= 1;
    }
    return error.InvalidZip;
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
