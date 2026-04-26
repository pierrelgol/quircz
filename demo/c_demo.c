#include "quircz.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define ZIP_EOCD_SIG        0x06054b50u
#define ZIP_CENTRAL_SIG     0x02014b50u
#define ZIP_LOCAL_SIG       0x04034b50u
#define ZIP_METHOD_STORE    0u
#define ZIP_METHOD_DEFLATE  8u
#define ZIP_MAX_COMMENT_LEN 0xffffu

typedef struct zip_entry {
        const unsigned char *name;
        size_t               name_len;
        unsigned short       method;
        unsigned int         compressed_size;
        unsigned int         uncompressed_size;
        unsigned int         local_header_offset;
} zip_entry;

static unsigned short read_u16le(const unsigned char *ptr) {
        return (unsigned short)(ptr[0] | ((unsigned short)ptr[1] << 8));
}

static unsigned int read_u32le(const unsigned char *ptr) {
        return (unsigned int)(ptr[0] | ((unsigned int)ptr[1] << 8) | ((unsigned int)ptr[2] << 16) | ((unsigned int)ptr[3] << 24));
}

static void fail_message(const char *message) {
        fprintf(stderr, "%s\n", message);
        exit(1);
}

static void fail_status(const char *prefix, quircz_status status) {
        fprintf(stderr, "%s: %s\n", prefix, quircz_status_message(status));
        exit(1);
}

static unsigned char *read_file(const char *path, size_t *out_len) {
        FILE          *file = fopen(path, "rb");
        unsigned char *data;
        long           file_size;

        if (file == NULL) {
                perror(path);
                exit(1);
        }

        if (fseek(file, 0, SEEK_END) != 0) {
                perror("fseek");
                fclose(file);
                exit(1);
        }

        file_size = ftell(file);
        if (file_size < 0) {
                perror("ftell");
                fclose(file);
                exit(1);
        }

        if (fseek(file, 0, SEEK_SET) != 0) {
                perror("fseek");
                fclose(file);
                exit(1);
        }

        data = (unsigned char *)malloc((size_t)file_size);
        if (data == NULL) {
                fclose(file);
                fail_message("allocation failure");
        }

        if ((size_t)file_size > 0 && fread(data, 1, (size_t)file_size, file) != (size_t)file_size) {
                perror("fread");
                fclose(file);
                free(data);
                exit(1);
        }

        fclose(file);
        *out_len = (size_t)file_size;
        return data;
}

static size_t find_end_of_central_directory(const unsigned char *zip_data, size_t zip_len) {
        size_t min_offset;
        size_t offset;

        if (zip_len < 22) fail_message("zip truncated");

        min_offset = zip_len > 22 + ZIP_MAX_COMMENT_LEN ? zip_len - (22 + ZIP_MAX_COMMENT_LEN) : 0;
        offset     = zip_len - 22;
        for (;;) {
                if (read_u32le(zip_data + offset) == ZIP_EOCD_SIG) return offset;
                if (offset == min_offset) break;
                offset -= 1;
        }

        fail_message("invalid zip");
        return 0;
}

static zip_entry find_zip_entry(const unsigned char *zip_data, size_t zip_len, const char *entry_name) {
        size_t               eocd_offset = find_end_of_central_directory(zip_data, zip_len);
        const unsigned char *record      = zip_data + eocd_offset;
        size_t               entry_count = read_u16le(record + 10);
        size_t               cd_offset   = read_u32le(record + 16);
        size_t               i;

        for (i = 0; i < entry_count; i += 1) {
                const unsigned char *header;
                size_t               name_len;
                size_t               extra_len;
                size_t               comment_len;
                size_t               name_offset;
                size_t               next_offset;

                if (cd_offset + 46 > zip_len) fail_message("zip truncated");
                header = zip_data + cd_offset;
                if (read_u32le(header) != ZIP_CENTRAL_SIG) fail_message("invalid zip");

                name_len    = read_u16le(header + 28);
                extra_len   = read_u16le(header + 30);
                comment_len = read_u16le(header + 32);
                name_offset = cd_offset + 46;
                next_offset = name_offset + name_len + extra_len + comment_len;

                if (next_offset > zip_len) fail_message("zip truncated");

                if (strlen(entry_name) == name_len && memcmp(zip_data + name_offset, entry_name, name_len) == 0) {
                        zip_entry entry;
                        entry.name                = zip_data + name_offset;
                        entry.name_len            = name_len;
                        entry.method              = read_u16le(header + 10);
                        entry.compressed_size     = read_u32le(header + 20);
                        entry.uncompressed_size   = read_u32le(header + 24);
                        entry.local_header_offset = read_u32le(header + 42);
                        return entry;
                }

                cd_offset = next_offset;
        }

        fail_message("zip entry not found");
        return (zip_entry){0};
}

static const unsigned char *zip_entry_data(const unsigned char *zip_data, size_t zip_len, const zip_entry *entry) {
        size_t               offset = entry->local_header_offset;
        const unsigned char *header;
        size_t               name_len;
        size_t               extra_len;
        size_t               data_offset;

        if (offset + 30 > zip_len) fail_message("zip truncated");
        header = zip_data + offset;
        if (read_u32le(header) != ZIP_LOCAL_SIG) fail_message("invalid zip");

        name_len    = read_u16le(header + 26);
        extra_len   = read_u16le(header + 28);
        data_offset = offset + 30 + name_len + extra_len;

        if (data_offset + entry->compressed_size > zip_len) fail_message("zip truncated");
        return zip_data + data_offset;
}

static unsigned char *extract_zip_entry(const unsigned char *zip_data, size_t zip_len, const char *entry_name, size_t *out_len) {
        zip_entry            entry      = find_zip_entry(zip_data, zip_len, entry_name);
        const unsigned char *compressed = zip_entry_data(zip_data, zip_len, &entry);
        unsigned char       *data       = (unsigned char *)malloc(entry.uncompressed_size);

        if (data == NULL) fail_message("allocation failure");

        switch (entry.method) {
                case ZIP_METHOD_STORE :
                        if (entry.compressed_size != entry.uncompressed_size) fail_message("zip size mismatch");
                        memcpy(data, compressed, entry.uncompressed_size);
                        break;
                case ZIP_METHOD_DEFLATE :
                        {
                                z_stream stream;
                                int      rc;

                                memset(&stream, 0, sizeof(stream));
                                stream.next_in   = (Bytef *)compressed;
                                stream.avail_in  = entry.compressed_size;
                                stream.next_out  = data;
                                stream.avail_out = entry.uncompressed_size;

                                rc               = inflateInit2(&stream, -MAX_WBITS);
                                if (rc != Z_OK) {
                                        free(data);
                                        fail_message("inflateInit2 failed");
                                }

                                rc = inflate(&stream, Z_FINISH);
                                if (rc != Z_STREAM_END || stream.total_out != entry.uncompressed_size) {
                                        inflateEnd(&stream);
                                        free(data);
                                        fail_message("inflate failed");
                                }

                                rc = inflateEnd(&stream);
                                if (rc != Z_OK) {
                                        free(data);
                                        fail_message("inflateEnd failed");
                                }
                                break;
                        }
                default : free(data); fail_message("unsupported zip compression");
        }

        *out_len = entry.uncompressed_size;
        return data;
}

static unsigned char *bmp_to_grayscale(const unsigned char *data, size_t len, unsigned int *out_width, unsigned int *out_height) {
        int            width_i;
        int            height_i;
        unsigned short bit_count;
        unsigned int   pixel_offset;
        unsigned int   height;
        unsigned int   width;
        unsigned int   bytes_per_pixel;
        unsigned int   row_stride;
        int            top_down;
        unsigned char *grayscale;
        unsigned int   y;

        if (len < 54 || data[0] != 'B' || data[1] != 'M') fail_message("invalid bmp");

        pixel_offset = read_u32le(data + 10);
        width_i      = (int)read_u32le(data + 18);
        height_i     = (int)read_u32le(data + 22);
        bit_count    = read_u16le(data + 28);

        if (width_i <= 0 || height_i == 0) fail_message("invalid bmp");
        if (bit_count != 24 && bit_count != 32) fail_message("unsupported bmp bit depth");

        width           = (unsigned int)width_i;
        height          = (unsigned int)(height_i < 0 ? -height_i : height_i);
        top_down        = height_i < 0;
        bytes_per_pixel = bit_count / 8u;
        row_stride      = (width * bytes_per_pixel + 3u) & ~3u;

        if ((size_t)pixel_offset > len) fail_message("invalid bmp");
        if ((size_t)row_stride * height > len - pixel_offset) fail_message("invalid bmp");

        grayscale = (unsigned char *)malloc((size_t)width * height);
        if (grayscale == NULL) fail_message("allocation failure");

        for (y = 0; y < height; y += 1) {
                unsigned int         src_y   = top_down ? y : (height - 1u - y);
                const unsigned char *src_row = data + pixel_offset + (size_t)src_y * row_stride;
                unsigned char       *dst_row = grayscale + (size_t)y * width;
                unsigned int         x;

                for (x = 0; x < width; x += 1) {
                        const unsigned char b = src_row[x * bytes_per_pixel + 0];
                        const unsigned char g = src_row[x * bytes_per_pixel + 1];
                        const unsigned char r = src_row[x * bytes_per_pixel + 2];
                        dst_row[x]            = (unsigned char)(((unsigned int)r * 77u + (unsigned int)g * 150u + (unsigned int)b * 29u) >> 8);
                }
        }

        *out_width  = width;
        *out_height = height;
        return grayscale;
}

int main(int argc, char **argv) {
        const char      *path = argc > 1 ? argv[1] : "demo/zen.zip";
        size_t           zip_len;
        unsigned char   *zip_data = read_file(path, &zip_len);
        size_t           bmp_len;
        unsigned char   *bmp_data = extract_zip_entry(zip_data, zip_len, "zen.bmp", &bmp_len);
        unsigned int     width;
        unsigned int     height;
        unsigned char   *grayscale   = bmp_to_grayscale(bmp_data, bmp_len, &width, &height);
        size_t           scratch_len = quircz_scratch_bytes_for_image(width, height);
        unsigned char   *scratch     = (unsigned char *)malloc(scratch_len);
        quircz_detector *detector;
        quircz_code      codes[QUIRCZ_MAX_CODES];
        size_t           found = 0;
        quircz_status    status;
        size_t           i;

        free(zip_data);
        free(bmp_data);

        if (scratch == NULL) fail_message("allocation failure");

        detector = quircz_detector_create(grayscale, width, height, scratch, scratch_len);
        if (detector == NULL) fail_message("quircz_detector_create failed");

        status = quircz_detector_detect(detector, codes, QUIRCZ_MAX_CODES, &found);
        if (status == QUIRCZ_NO_CODE) {
                printf("no QR codes found in %s\n", path);
                quircz_detector_destroy(detector);
                free(scratch);
                free(grayscale);
                return 0;
        }
        if (status != QUIRCZ_OK) fail_status("quircz_detector_detect", status);

        printf("found %zu QR code(s) in %s\n\n", found, path);

        for (i = 0; i < found; i += 1) {
                unsigned char        payload[QUIRCZ_MAX_PAYLOAD_BYTES];
                quircz_decode_result result;

                status = quircz_decode(&codes[i], payload, sizeof(payload), &result);
                if (status != QUIRCZ_OK) {
                        printf("[%zu] decode failed: %s\n", i + 1, quircz_status_message(status));
                        continue;
                }

                printf("[%zu] %.*s\n", i + 1, (int)result.payload_len, (const char *)payload);
        }

        quircz_detector_destroy(detector);
        free(scratch);
        free(grayscale);
        return 0;
}
