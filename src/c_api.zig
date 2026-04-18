const std = @import("std");
const root = @import("root.zig");
const Detect = root.Detect;
const Decode = root.Decode;
const Encode = root.Encode;
const Perspective = @import("internal/Perspective.zig");
const Spec = @import("internal/Spec.zig");

const allocator = std.heap.page_allocator;

pub const DetectorHandle = opaque {};

const ValidateBuffersError = error{
    InvalidArgument,
    NullPointer,
    ScratchTooSmall,
};

const DecodeOptionsError = error{
    InvalidArgument,
};

const Detector = struct {
    grayscale: []const u8,
    scratch: []u8,
    width: u32,
    height: u32,
    detect: Detect,
};

pub const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    null_pointer = 2,
    allocation_failure = 3,
    too_many_codes = 4,
    payload_too_large = 10,
    unsupported_mode = 11,
    invalid_version = 12,
    invalid_mask = 13,
    invalid_quiet_zone = 14,
    data_overflow = 15,
    scratch_too_small = 20,
    image_size_mismatch = 21,
    too_many_regions = 22,
    too_many_capstones = 23,
    too_many_grids = 24,
    invalid_detection = 25,
    grid_too_large = 26,
    no_code = 27,
    output_too_small = 28,
    invalid_grid_size = 30,
    format_ecc = 31,
    data_ecc = 32,
    unknown_data_type = 33,
    data_underflow = 34,
};

pub const EncodeEccLevel = enum(c_int) {
    l = 0,
    m = 1,
    q = 2,
    h = 3,
};

pub const EncodeMode = enum(c_int) {
    auto = 0,
    numeric = 1,
    alphanumeric = 2,
    byte = 3,
};

pub const EncodeMask = enum(c_int) {
    auto = 0,
    m0 = 1,
    m1 = 2,
    m2 = 3,
    m3 = 4,
    m4 = 5,
    m5 = 6,
    m6 = 7,
    m7 = 8,
};

pub const DecodeMode = enum(c_int) {
    none = 0,
    numeric = 1,
    alpha = 2,
    byte = 4,
    eci = 7,
    kanji = 8,
};

pub const Point = extern struct {
    x: i32,
    y: i32,
};

pub const Code = extern struct {
    corners: [4]Point,
    size: u16,
    cells: [Spec.max_bitmap_bytes]u8,
};

pub const EncodeOptions = extern struct {
    mode: EncodeMode,
    ecc_level: EncodeEccLevel,
    version: u8,
    version_is_set: bool,
    mask: EncodeMask,
    quiet_zone_modules: u8,
};

pub const EncodeResult = extern struct {
    modules: ?[*]u8,
    side_modules: u16,
    symbol_modules: u16,
    quiet_zone_modules: u8,
    version: u8,
    ecc_level: EncodeEccLevel,
    mode: EncodeMode,
    mask: u8,
};

pub const DecodeResult = extern struct {
    version: u8,
    ecc_level: EncodeEccLevel,
    mask: u8,
    mode: DecodeMode,
    has_eci: bool,
    eci: u32,
    payload_len: u16,
};

pub export fn quircz_scratch_bytes_for_image(width: u32, height: u32) usize {
    return Detect.scratchBytesForImage(width, height);
}

pub export fn quircz_bitmap_bytes_for_size(size: u16) usize {
    return Detect.bitmapBytesForSize(size);
}

pub export fn quircz_status_message(status: Status) [*:0]const u8 {
    return switch (status) {
        .ok => "ok",
        .invalid_argument => "invalid argument",
        .null_pointer => "null pointer",
        .allocation_failure => "allocation failure",
        .too_many_codes => "too many codes",
        .payload_too_large => "payload too large",
        .unsupported_mode => "unsupported mode",
        .invalid_version => "invalid version",
        .invalid_mask => "invalid mask",
        .invalid_quiet_zone => "invalid quiet zone",
        .data_overflow => "data overflow",
        .scratch_too_small => "scratch too small",
        .image_size_mismatch => "image size mismatch",
        .too_many_regions => "too many regions",
        .too_many_capstones => "too many capstones",
        .too_many_grids => "too many grids",
        .invalid_detection => "invalid detection",
        .grid_too_large => "grid too large",
        .no_code => "no code",
        .output_too_small => "output too small",
        .invalid_grid_size => "invalid grid size",
        .format_ecc => "format ecc",
        .data_ecc => "data ecc",
        .unknown_data_type => "unknown data type",
        .data_underflow => "data underflow",
    };
}

pub export fn quircz_encode(
    payload: ?[*]const u8,
    payload_len: usize,
    options: ?*const EncodeOptions,
    out_result: ?*EncodeResult,
) Status {
    if (out_result == null or options == null) return .null_pointer;
    if (payload_len > 0 and payload == null) return .null_pointer;

    out_result.?.* = std.mem.zeroes(EncodeResult);

    const zig_options = decodeEncodeOptions(options.?) catch |err| return mapDecodeOptionsError(err);
    const payload_slice = if (payload_len == 0)
        &[_]u8{}
    else
        payload.?[0..payload_len];

    var encoded = Encode.encode(allocator, payload_slice, zig_options) catch |err| return mapEncodeError(err);
    errdefer encoded.deinit(allocator);

    out_result.?.* = .{
        .modules = encoded.modules.ptr,
        .side_modules = encoded.side_modules,
        .symbol_modules = encoded.symbol_modules,
        .quiet_zone_modules = encoded.quiet_zone_modules,
        .version = encoded.version,
        .ecc_level = encodeEccLevelFromZig(encoded.ecc_level),
        .mode = encodeModeFromZig(encoded.mode),
        .mask = encoded.mask,
    };

    return .ok;
}

pub export fn quircz_encode_result_free(result: ?*EncodeResult) void {
    if (result == null) return;
    if (result.?.modules) |modules| {
        const len = @as(usize, result.?.side_modules) * result.?.side_modules;
        allocator.free(modules[0..len]);
    }
    result.?.* = std.mem.zeroes(EncodeResult);
}

pub export fn quircz_detector_create(
    grayscale: ?[*]const u8,
    width: u32,
    height: u32,
    scratch: ?[*]u8,
    scratch_len: usize,
) ?*DetectorHandle {
    const slices = validateImageBuffers(grayscale, width, height, scratch, scratch_len) catch return null;
    const detector = allocator.create(Detector) catch return null;
    detector.* = .{
        .grayscale = slices.grayscale,
        .scratch = slices.scratch,
        .width = width,
        .height = height,
        .detect = Detect.init(slices.grayscale, slices.scratch, width, height),
    };
    return handleFromDetector(detector);
}

pub export fn quircz_detector_destroy(handle: ?*DetectorHandle) void {
    if (handle == null) return;
    allocator.destroy(detectorFromHandle(handle.?));
}

pub export fn quircz_detector_reset(
    handle: ?*DetectorHandle,
    grayscale: ?[*]const u8,
    width: u32,
    height: u32,
    scratch: ?[*]u8,
    scratch_len: usize,
) Status {
    if (handle == null) return .null_pointer;
    const detector = detectorFromHandle(handle.?);
    const slices = validateImageBuffers(grayscale, width, height, scratch, scratch_len) catch |err| return mapValidateBuffersError(err);
    detector.* = .{
        .grayscale = slices.grayscale,
        .scratch = slices.scratch,
        .width = width,
        .height = height,
        .detect = Detect.init(slices.grayscale, slices.scratch, width, height),
    };
    return .ok;
}

pub export fn quircz_detector_detect(
    handle: ?*DetectorHandle,
    out_codes: ?[*]Code,
    code_capacity: usize,
    out_count: ?*usize,
) Status {
    if (handle == null or out_count == null) return .null_pointer;
    if (code_capacity > 0 and out_codes == null) return .null_pointer;

    out_count.?.* = 0;

    const detector = detectorFromHandle(handle.?);
    var detections: [Spec.max_grids]Detect.Detection = undefined;
    const found = detector.detect.scan(&detections) catch |err| return mapDetectError(err);
    if (found.len == 0) return .no_code;

    var first_extract_error: ?Status = null;
    var extracted: usize = 0;
    for (found) |*detection| {
        const code = detector.detect.extract(detection) catch |err| {
            if (first_extract_error == null) first_extract_error = mapExtractError(err);
            continue;
        };

        if (extracted >= code_capacity) return .too_many_codes;
        out_codes.?[extracted] = codeToC(code);
        extracted += 1;
    }

    if (extracted == 0) return first_extract_error orelse .no_code;

    out_count.?.* = extracted;
    return .ok;
}

pub export fn quircz_decode(
    code: ?*const Code,
    out_payload: ?[*]u8,
    payload_capacity: usize,
    out_result: ?*DecodeResult,
) Status {
    if (code == null or out_result == null) return .null_pointer;
    if (payload_capacity > 0 and out_payload == null) return .null_pointer;

    out_result.?.* = std.mem.zeroes(DecodeResult);

    var zig_code = codeFromC(code.?);
    var empty_payload: [0]u8 = .{};
    const payload: []u8 = if (payload_capacity == 0)
        empty_payload[0..]
    else
        out_payload.?[0..payload_capacity];
    const result = Decode.decode(&zig_code, payload) catch |err| return mapDecodeError(err);

    out_result.?.* = .{
        .version = result.version,
        .ecc_level = encodeEccLevelFromDecode(result.ecc_level),
        .mask = @intFromEnum(result.mask),
        .mode = decodeModeFromZig(result.mode),
        .has_eci = result.eci != null,
        .eci = result.eci orelse 0,
        .payload_len = result.payload_len,
    };
    return .ok;
}

fn validateImageBuffers(
    grayscale: ?[*]const u8,
    width: u32,
    height: u32,
    scratch: ?[*]u8,
    scratch_len: usize,
) ValidateBuffersError!struct { grayscale: []const u8, scratch: []u8 } {
    if (width == 0 or height == 0) return error.InvalidArgument;

    const pixel_count = std.math.mul(usize, width, height) catch return error.InvalidArgument;
    if (grayscale == null or scratch == null) return error.NullPointer;

    const required_scratch = Detect.scratchBytesForImage(width, height);
    if (scratch_len < required_scratch) return error.ScratchTooSmall;

    return .{
        .grayscale = grayscale.?[0..pixel_count],
        .scratch = scratch.?[0..scratch_len],
    };
}

fn detectorFromHandle(handle: *DetectorHandle) *Detector {
    return @ptrCast(@alignCast(handle));
}

fn handleFromDetector(detector: *Detector) *DetectorHandle {
    return @ptrCast(detector);
}

fn decodeEncodeOptions(options: *const EncodeOptions) DecodeOptionsError!Encode.Options {
    return .{
        .mode = switch (options.mode) {
            .auto => .auto,
            .numeric => .numeric,
            .alphanumeric => .alphanumeric,
            .byte => .byte,
        },
        .ecc_level = switch (options.ecc_level) {
            .l => .l,
            .m => .m,
            .q => .q,
            .h => .h,
        },
        .version = if (options.version_is_set) options.version else null,
        .mask = switch (options.mask) {
            .auto => .auto,
            .m0 => .m0,
            .m1 => .m1,
            .m2 => .m2,
            .m3 => .m3,
            .m4 => .m4,
            .m5 => .m5,
            .m6 => .m6,
            .m7 => .m7,
        },
        .quiet_zone_modules = options.quiet_zone_modules,
    };
}

fn encodeEccLevelFromZig(level: Encode.EccLevel) EncodeEccLevel {
    return switch (level) {
        .l => .l,
        .m => .m,
        .q => .q,
        .h => .h,
    };
}

fn encodeEccLevelFromDecode(level: Decode.EccLevel) EncodeEccLevel {
    return switch (level) {
        .l => .l,
        .m => .m,
        .q => .q,
        .h => .h,
    };
}

fn encodeModeFromZig(mode: Encode.Mode) EncodeMode {
    return switch (mode) {
        .auto => .auto,
        .numeric => .numeric,
        .alphanumeric => .alphanumeric,
        .byte => .byte,
    };
}

fn decodeModeFromZig(mode: ?Decode.Mode) DecodeMode {
    return switch (mode orelse return .none) {
        .numeric => .numeric,
        .alpha => .alpha,
        .byte => .byte,
        .eci => .eci,
        .kanji => .kanji,
    };
}

fn codeToC(code: Detect.Code) Code {
    var result: Code = .{
        .corners = undefined,
        .size = code.size,
        .cells = code.cells,
    };
    for (code.corners, 0..) |corner, i| {
        result.corners[i] = pointFromZig(corner);
    }
    return result;
}

fn codeFromC(code: *const Code) Detect.Code {
    var result: Detect.Code = .{
        .size = code.size,
        .cells = code.cells,
    };
    for (code.corners, 0..) |corner, i| {
        result.corners[i] = pointToZig(corner);
    }
    return result;
}

fn pointFromZig(point: Perspective.PixelPoint) Point {
    return .{ .x = point.x, .y = point.y };
}

fn pointToZig(point: Point) Perspective.PixelPoint {
    return .{ .x = point.x, .y = point.y };
}

fn mapEncodeError(err: Encode.Error) Status {
    return switch (err) {
        error.PayloadTooLarge => .payload_too_large,
        error.UnsupportedMode => .unsupported_mode,
        error.InvalidVersion => .invalid_version,
        error.InvalidMask => .invalid_mask,
        error.InvalidQuietZone => .invalid_quiet_zone,
        error.DataOverflow => .data_overflow,
        error.AllocatorFailure => .allocation_failure,
    };
}

fn mapDetectError(err: Detect.Error) Status {
    return switch (err) {
        error.ScratchTooSmall => .scratch_too_small,
        error.ImageSizeMismatch => .image_size_mismatch,
        error.TooManyRegions => .too_many_regions,
        error.TooManyCapstones => .too_many_capstones,
        error.TooManyGrids => .too_many_grids,
    };
}

fn mapExtractError(err: Detect.ExtractError) Status {
    return switch (err) {
        error.InvalidDetection => .invalid_detection,
        error.GridTooLarge => .grid_too_large,
    };
}

fn mapDecodeError(err: Decode.Error) Status {
    return switch (err) {
        error.InvalidGridSize => .invalid_grid_size,
        error.InvalidVersion => .invalid_version,
        error.FormatEcc => .format_ecc,
        error.DataEcc => .data_ecc,
        error.UnknownDataType => .unknown_data_type,
        error.DataOverflow => .data_overflow,
        error.DataUnderflow => .data_underflow,
        error.OutputTooSmall => .output_too_small,
    };
}

fn mapValidateBuffersError(err: ValidateBuffersError) Status {
    return switch (err) {
        error.InvalidArgument => .invalid_argument,
        error.NullPointer => .null_pointer,
        error.ScratchTooSmall => .scratch_too_small,
    };
}

fn mapDecodeOptionsError(err: DecodeOptionsError) Status {
    return switch (err) {
        error.InvalidArgument => .invalid_argument,
    };
}

test "c encode allocates and frees modules" {
    const options: EncodeOptions = .{
        .mode = .byte,
        .ecc_level = .m,
        .version = 0,
        .version_is_set = false,
        .mask = .auto,
        .quiet_zone_modules = 4,
    };
    var result = std.mem.zeroes(EncodeResult);
    try std.testing.expectEqual(Status.ok, quircz_encode("hello".ptr, 5, &options, &result));
    try std.testing.expect(result.modules != null);
    try std.testing.expect(result.side_modules > result.symbol_modules);

    quircz_encode_result_free(&result);
    try std.testing.expect(result.modules == null);
}

test "c detector reports no code on blank image" {
    var grayscale: [21 * 21]u8 = @splat(0xff);
    var scratch: [Detect.scratchBytesForImage(21, 21)]u8 = undefined;
    const detector = quircz_detector_create(&grayscale, 21, 21, &scratch, scratch.len) orelse return error.TestUnexpectedResult;
    defer quircz_detector_destroy(detector);

    var count: usize = 99;
    try std.testing.expectEqual(Status.no_code, quircz_detector_detect(detector, null, 0, &count));
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "c detect and decode round trip an encoded symbol" {
    var encoded = try Encode.encode(std.testing.allocator, "zig-c-api", .{
        .mode = .byte,
        .ecc_level = .m,
    });
    defer encoded.deinit(std.testing.allocator);

    const scale = 8;
    const width = encoded.side_modules * scale;
    const height = encoded.side_modules * scale;
    var grayscale = try std.testing.allocator.alloc(u8, @as(usize, width) * height);
    defer std.testing.allocator.free(grayscale);

    for (0..encoded.side_modules) |module_y| {
        for (0..encoded.side_modules) |module_x| {
            const value: u8 = if (encoded.moduleAt(module_x, module_y) != 0) 0 else 0xff;
            for (0..scale) |dy| {
                const py = module_y * scale + dy;
                const row = py * width;
                for (0..scale) |dx| {
                    const px = module_x * scale + dx;
                    grayscale[row + px] = value;
                }
            }
        }
    }

    const scratch = try std.testing.allocator.alloc(u8, Detect.scratchBytesForImage(width, height));
    defer std.testing.allocator.free(scratch);

    const detector = quircz_detector_create(grayscale.ptr, width, height, scratch.ptr, scratch.len) orelse return error.TestUnexpectedResult;
    defer quircz_detector_destroy(detector);

    var code: Code = undefined;
    var count: usize = 0;
    try std.testing.expectEqual(Status.ok, quircz_detector_detect(detector, @ptrCast(&code), 1, &count));
    try std.testing.expectEqual(@as(usize, 1), count);

    var payload: [Spec.max_payload_bytes]u8 = @splat(0);
    var result = std.mem.zeroes(DecodeResult);
    try std.testing.expectEqual(Status.ok, quircz_decode(&code, &payload, payload.len, &result));
    try std.testing.expectEqualStrings("zig-c-api", payload[0..result.payload_len]);
}
