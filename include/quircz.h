#ifndef QUIRCZ_H
#define QUIRCZ_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define QUIRCZ_MAX_BITMAP_BYTES 3918
#define QUIRCZ_MAX_PAYLOAD_BYTES 8896
#define QUIRCZ_MAX_CODES 64

typedef enum quircz_status {
    QUIRCZ_OK = 0,
    QUIRCZ_INVALID_ARGUMENT = 1,
    QUIRCZ_NULL_POINTER = 2,
    QUIRCZ_ALLOCATION_FAILURE = 3,
    QUIRCZ_TOO_MANY_CODES = 4,
    QUIRCZ_PAYLOAD_TOO_LARGE = 10,
    QUIRCZ_UNSUPPORTED_MODE = 11,
    QUIRCZ_INVALID_VERSION = 12,
    QUIRCZ_INVALID_MASK = 13,
    QUIRCZ_INVALID_QUIET_ZONE = 14,
    QUIRCZ_DATA_OVERFLOW = 15,
    QUIRCZ_SCRATCH_TOO_SMALL = 20,
    QUIRCZ_IMAGE_SIZE_MISMATCH = 21,
    QUIRCZ_TOO_MANY_REGIONS = 22,
    QUIRCZ_TOO_MANY_CAPSTONES = 23,
    QUIRCZ_TOO_MANY_GRIDS = 24,
    QUIRCZ_INVALID_DETECTION = 25,
    QUIRCZ_GRID_TOO_LARGE = 26,
    QUIRCZ_NO_CODE = 27,
    QUIRCZ_OUTPUT_TOO_SMALL = 28,
    QUIRCZ_INVALID_GRID_SIZE = 30,
    QUIRCZ_FORMAT_ECC = 31,
    QUIRCZ_DATA_ECC = 32,
    QUIRCZ_UNKNOWN_DATA_TYPE = 33,
    QUIRCZ_DATA_UNDERFLOW = 34
} quircz_status;

typedef enum quircz_encode_ecc_level {
    QUIRCZ_ECC_L = 0,
    QUIRCZ_ECC_M = 1,
    QUIRCZ_ECC_Q = 2,
    QUIRCZ_ECC_H = 3
} quircz_encode_ecc_level;

typedef enum quircz_encode_mode {
    QUIRCZ_ENCODE_AUTO = 0,
    QUIRCZ_ENCODE_NUMERIC = 1,
    QUIRCZ_ENCODE_ALPHANUMERIC = 2,
    QUIRCZ_ENCODE_BYTE = 3
} quircz_encode_mode;

typedef enum quircz_encode_mask {
    QUIRCZ_MASK_AUTO = 0,
    QUIRCZ_MASK_M0 = 1,
    QUIRCZ_MASK_M1 = 2,
    QUIRCZ_MASK_M2 = 3,
    QUIRCZ_MASK_M3 = 4,
    QUIRCZ_MASK_M4 = 5,
    QUIRCZ_MASK_M5 = 6,
    QUIRCZ_MASK_M6 = 7,
    QUIRCZ_MASK_M7 = 8
} quircz_encode_mask;

typedef enum quircz_decode_mode {
    QUIRCZ_DECODE_NONE = 0,
    QUIRCZ_DECODE_NUMERIC = 1,
    QUIRCZ_DECODE_ALPHA = 2,
    QUIRCZ_DECODE_BYTE = 4,
    QUIRCZ_DECODE_ECI = 7,
    QUIRCZ_DECODE_KANJI = 8
} quircz_decode_mode;

typedef struct quircz_point {
    int32_t x;
    int32_t y;
} quircz_point;

typedef struct quircz_code {
    quircz_point corners[4];
    uint16_t size;
    uint8_t cells[QUIRCZ_MAX_BITMAP_BYTES];
} quircz_code;

typedef struct quircz_encode_options {
    quircz_encode_mode mode;
    quircz_encode_ecc_level ecc_level;
    uint8_t version;
    bool version_is_set;
    quircz_encode_mask mask;
    uint8_t quiet_zone_modules;
} quircz_encode_options;

typedef struct quircz_encode_result {
    uint8_t *modules;
    uint16_t side_modules;
    uint16_t symbol_modules;
    uint8_t quiet_zone_modules;
    uint8_t version;
    quircz_encode_ecc_level ecc_level;
    quircz_encode_mode mode;
    uint8_t mask;
} quircz_encode_result;

typedef struct quircz_decode_result {
    uint8_t version;
    quircz_encode_ecc_level ecc_level;
    uint8_t mask;
    quircz_decode_mode mode;
    bool has_eci;
    uint32_t eci;
    uint16_t payload_len;
} quircz_decode_result;

typedef struct quircz_detector quircz_detector;

size_t quircz_scratch_bytes_for_image(uint32_t width, uint32_t height);
size_t quircz_bitmap_bytes_for_size(uint16_t size);
const char *quircz_status_message(quircz_status status);

quircz_status quircz_encode(
    const uint8_t *payload,
    size_t payload_len,
    const quircz_encode_options *options,
    quircz_encode_result *out_result
);

void quircz_encode_result_free(quircz_encode_result *result);

quircz_detector *quircz_detector_create(
    const uint8_t *grayscale,
    uint32_t width,
    uint32_t height,
    uint8_t *scratch,
    size_t scratch_len
);

void quircz_detector_destroy(quircz_detector *detector);

quircz_status quircz_detector_reset(
    quircz_detector *detector,
    const uint8_t *grayscale,
    uint32_t width,
    uint32_t height,
    uint8_t *scratch,
    size_t scratch_len
);

quircz_status quircz_detector_detect(
    quircz_detector *detector,
    quircz_code *out_codes,
    size_t code_capacity,
    size_t *out_count
);

quircz_status quircz_decode(
    const quircz_code *code,
    uint8_t *out_payload,
    size_t payload_capacity,
    quircz_decode_result *out_result
);

#ifdef __cplusplus
}
#endif

#endif
