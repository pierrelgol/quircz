#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <string>
#include <string_view>
#include <vector>

#include <opencv2/core.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/objdetect.hpp>

extern "C" {
#include "quirc.h"
#include "quircz.h"
}

namespace fs = std::filesystem;

struct ImageData {
    std::string path;
    std::string expected;
    cv::Mat gray;
    std::size_t pixel_count = 0;
};

struct Dataset {
    std::vector<ImageData> items;
    std::size_t total_pixels = 0;
    std::size_t max_scratch_len = 0;
};

struct BenchResult {
    std::string name;
    std::uint64_t elapsed_ns = 0;
    std::size_t images_processed = 0;
    std::size_t successful_images = 0;
    std::size_t payload_matches = 0;
    std::size_t decoded_candidates = 0;
    std::size_t failed_images = 0;
};

static bool hasPngSuffix(const fs::path &path) {
    return path.extension() == ".png";
}

static std::uint64_t monotonicNs() {
    const auto now = std::chrono::steady_clock::now().time_since_epoch();
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(now).count()
    );
}

static bool loadDataset(const fs::path &dataset_dir, Dataset &out) {
    out = {};

    if (!fs::exists(dataset_dir) || !fs::is_directory(dataset_dir)) {
        std::cerr << "failed to open dataset directory " << dataset_dir << '\n';
        return false;
    }

    for (const auto &entry : fs::directory_iterator(dataset_dir)) {
        if (!entry.is_regular_file() || !hasPngSuffix(entry.path())) {
            continue;
        }

        ImageData image;
        image.path = entry.path().string();
        image.expected = entry.path().stem().string();
        image.gray = cv::imread(image.path, cv::IMREAD_GRAYSCALE);
        if (image.gray.empty()) {
            std::cerr << "failed to load image " << image.path << '\n';
            return false;
        }
        if (!image.gray.isContinuous()) {
            image.gray = image.gray.clone();
        }

        image.pixel_count = static_cast<std::size_t>(image.gray.rows) * static_cast<std::size_t>(image.gray.cols);
        out.total_pixels += image.pixel_count;
        out.max_scratch_len = std::max(
            out.max_scratch_len,
            quircz_scratch_bytes_for_image(
                static_cast<std::uint32_t>(image.gray.cols),
                static_cast<std::uint32_t>(image.gray.rows)
            )
        );
        out.items.push_back(std::move(image));
    }

    std::sort(out.items.begin(), out.items.end(), [](const ImageData &a, const ImageData &b) {
        return a.path < b.path;
    });
    return !out.items.empty();
}

static void runQuircz(const Dataset &data, int rounds, BenchResult &result) {
    std::vector<std::uint8_t> scratch(data.max_scratch_len);
    const auto &first = data.items.front();
    quircz_detector *detector = quircz_detector_create(
        first.gray.ptr<std::uint8_t>(),
        static_cast<std::uint32_t>(first.gray.cols),
        static_cast<std::uint32_t>(first.gray.rows),
        scratch.data(),
        scratch.size()
    );

    if (detector == nullptr) {
        throw std::runtime_error("failed to create quircz detector");
    }

    result = {};
    result.name = "quircz";
    result.images_processed = data.items.size() * static_cast<std::size_t>(rounds);
    result.elapsed_ns = monotonicNs();

    for (int round = 0; round < rounds; round += 1) {
        for (const auto &image : data.items) {
            quircz_code codes[QUIRCZ_MAX_CODES];
            std::size_t code_count = 0;
            bool found_success = false;
            bool found_match = false;

            quircz_status status = quircz_detector_reset(
                detector,
                image.gray.ptr<std::uint8_t>(),
                static_cast<std::uint32_t>(image.gray.cols),
                static_cast<std::uint32_t>(image.gray.rows),
                scratch.data(),
                scratch.size()
            );
            if (status != QUIRCZ_OK) {
                result.failed_images += 1;
                continue;
            }

            status = quircz_detector_detect(detector, codes, QUIRCZ_MAX_CODES, &code_count);
            if (status != QUIRCZ_OK) {
                result.failed_images += 1;
                continue;
            }

            for (std::size_t i = 0; i < code_count; i += 1) {
                std::uint8_t payload[QUIRCZ_MAX_PAYLOAD_BYTES];
                quircz_decode_result decoded{};
                status = quircz_decode(&codes[i], payload, sizeof(payload), &decoded);
                if (status != QUIRCZ_OK) {
                    continue;
                }

                found_success = true;
                result.decoded_candidates += 1;
                if (decoded.payload_len == image.expected.size() &&
                    std::memcmp(payload, image.expected.data(), image.expected.size()) == 0) {
                    found_match = true;
                }
            }

            result.successful_images += found_success ? 1u : 0u;
            result.payload_matches += found_match ? 1u : 0u;
            result.failed_images += found_success ? 0u : 1u;
        }
    }

    result.elapsed_ns = monotonicNs() - result.elapsed_ns;
    quircz_detector_destroy(detector);
}

static void runQuirc(const Dataset &data, int rounds, BenchResult &result) {
    quirc *decoder = quirc_new();
    int current_w = 1;
    int current_h = 1;

    if (decoder == nullptr) {
        throw std::runtime_error("failed to create quirc decoder");
    }
    if (quirc_resize(decoder, 1, 1) != 0) {
        quirc_destroy(decoder);
        throw std::runtime_error("failed to initialize quirc decoder storage");
    }

    result = {};
    result.name = "quirc";
    result.images_processed = data.items.size() * static_cast<std::size_t>(rounds);
    result.elapsed_ns = monotonicNs();

    for (int round = 0; round < rounds; round += 1) {
        for (const auto &image : data.items) {
            const int width = image.gray.cols;
            const int height = image.gray.rows;
            bool found_success = false;
            bool found_match = false;

            if (width != current_w || height != current_h) {
                if (quirc_resize(decoder, width, height) != 0) {
                    quirc_destroy(decoder);
                    throw std::runtime_error("quirc_resize failed");
                }
                current_w = width;
                current_h = height;
            }

            int begin_w = 0;
            int begin_h = 0;
            std::uint8_t *buffer = quirc_begin(decoder, &begin_w, &begin_h);
            if (buffer == nullptr || begin_w != width || begin_h != height) {
                quirc_destroy(decoder);
                throw std::runtime_error("quirc_begin failed");
            }

            std::memcpy(buffer, image.gray.ptr<std::uint8_t>(), image.pixel_count);
            quirc_end(decoder);

            const int code_count = quirc_count(decoder);
            if (code_count <= 0) {
                result.failed_images += 1;
                continue;
            }

            for (int i = 0; i < code_count; i += 1) {
                quirc_code code{};
                quirc_data decoded{};
                quirc_extract(decoder, i, &code);
                if (quirc_decode(&code, &decoded) != QUIRC_SUCCESS) {
                    continue;
                }

                found_success = true;
                result.decoded_candidates += 1;
                if (static_cast<std::size_t>(decoded.payload_len) == image.expected.size() &&
                    std::memcmp(decoded.payload, image.expected.data(), image.expected.size()) == 0) {
                    found_match = true;
                }
            }

            result.successful_images += found_success ? 1u : 0u;
            result.payload_matches += found_match ? 1u : 0u;
            result.failed_images += found_success ? 0u : 1u;
        }
    }

    result.elapsed_ns = monotonicNs() - result.elapsed_ns;
    quirc_destroy(decoder);
}

static void runOpenCv(const Dataset &data, int rounds, BenchResult &result) {
    cv::QRCodeDetector detector;

    result = {};
    result.name = "opencv";
    result.images_processed = data.items.size() * static_cast<std::size_t>(rounds);
    result.elapsed_ns = monotonicNs();

    for (int round = 0; round < rounds; round += 1) {
        for (const auto &image : data.items) {
            bool found_success = false;
            bool found_match = false;
            std::vector<cv::String> decoded_info;
            std::vector<cv::Point> points;

            const bool detected = detector.detectAndDecodeMulti(image.gray, decoded_info, points);
            if (!detected || decoded_info.empty()) {
                const std::string decoded = detector.detectAndDecode(image.gray);
                if (!decoded.empty()) {
                    found_success = true;
                    result.decoded_candidates += 1;
                    found_match = decoded == image.expected;
                }
            } else {
                for (const auto &decoded : decoded_info) {
                    if (decoded.empty()) {
                        continue;
                    }
                    found_success = true;
                    result.decoded_candidates += 1;
                    if (std::string_view(decoded.c_str(), decoded.size()) == image.expected) {
                        found_match = true;
                    }
                }
            }

            result.successful_images += found_success ? 1u : 0u;
            result.payload_matches += found_match ? 1u : 0u;
            result.failed_images += found_success ? 0u : 1u;
        }
    }

    result.elapsed_ns = monotonicNs() - result.elapsed_ns;
}

static void printResult(const BenchResult &result, const Dataset &data) {
    const double rounds = static_cast<double>(result.images_processed) / static_cast<double>(data.items.size());
    const double elapsed_s = static_cast<double>(result.elapsed_ns) / 1e9;
    const double ns_per_image = static_cast<double>(result.elapsed_ns) / static_cast<double>(result.images_processed);
    const double gpixel_s = (static_cast<double>(data.total_pixels) * rounds) / elapsed_s / 1e9;

    std::cout
        << result.name
        << " total=" << (elapsed_s * 1e3) << " ms"
        << " ns/image=" << ns_per_image
        << " GPix/s=" << gpixel_s
        << " ok=" << result.successful_images << "/" << result.images_processed
        << " payload_match=" << result.payload_matches << "/" << result.images_processed
        << " decoded=" << result.decoded_candidates
        << '\n';
}

int main(int argc, char **argv) {
    const fs::path dataset_dir = argc > 1 ? fs::path(argv[1]) : fs::path("demo/qr_dataset");
    const int rounds = argc > 2 ? std::atoi(argv[2]) : 5;
    Dataset data;
    BenchResult quircz_result;
    BenchResult quirc_result;
    BenchResult opencv_result;

    if (rounds <= 0) {
        std::cerr << "rounds must be positive\n";
        return 1;
    }

    if (!loadDataset(dataset_dir, data)) {
        std::cerr << "failed to load dataset from " << dataset_dir << '\n';
        return 1;
    }

    std::cout
        << "dataset=" << dataset_dir.string()
        << " images=" << data.items.size()
        << " total_pixels=" << data.total_pixels
        << " rounds=" << rounds
        << '\n';

    try {
        runQuircz(data, rounds, quircz_result);
        runQuirc(data, rounds, quirc_result);
        runOpenCv(data, rounds, opencv_result);
    } catch (const std::exception &err) {
        std::cerr << err.what() << '\n';
        return 1;
    }

    printResult(quircz_result, data);
    printResult(quirc_result, data);
    printResult(opencv_result, data);
    return 0;
}
