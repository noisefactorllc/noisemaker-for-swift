#include <array>
#include <cstdint>
#include <cstdio>
#include <limits>

#include "NoisemakerRaster.h"

namespace {
bool check(bool condition, const char* name) {
    if (!condition) std::fprintf(stderr, "raster API failed: %s\n", name);
    return condition;
}
}

int main() {
    constexpr int32_t width = 16, height = 16;
    constexpr size_t byte_count = width * height * 4;
    const std::array<double, 9> stroke = {1, 1, 14, 14, 2, 255, 0, 0, 1};
    std::array<uint8_t, byte_count> batch{}, streaming{};
    bool ok = true;
    ok &= check(nm_raster_segments_rgba8(width, height, stroke.data(), 1,
                                         batch.data(), batch.size()) == 0, "batch draw");
    auto* canvas = nm_raster_create(width, height);
    ok &= check(canvas != nullptr, "create");
    if (canvas) {
        ok &= check(nm_raster_stroke(canvas, stroke.data()) == 0, "streaming stroke");
        ok &= check(nm_raster_read_rgba8(canvas, streaming.data(), streaming.size()) == 0,
                    "streaming read");
        ok &= check(batch == streaming, "batch and streaming agree");
        const size_t center = (8 * width + 8) * 4;
        ok &= check(batch[center] > 0 && batch[center + 1] == 0 &&
                    batch[center + 2] == 0 && batch[center + 3] > 0, "red stroke pixels");
        ok &= check(batch[(15 * width) * 4 + 3] == 0, "transparent background");
        ok &= check(nm_raster_read_rgba8(canvas, streaming.data(), streaming.size() - 1) == 1,
                    "short output rejected");
        ok &= check(nm_raster_stroke(canvas, nullptr) == 1, "null stroke rejected");
        auto invalid = stroke;
        invalid[0] = std::numeric_limits<double>::max();
        ok &= check(nm_raster_stroke(canvas, invalid.data()) == 1,
                    "finite double overflow rejected");
        invalid = stroke;
        invalid[4] = std::numeric_limits<double>::max();
        ok &= check(nm_raster_stroke(canvas, invalid.data()) == 1,
                    "stroke width overflow rejected");
        invalid = stroke;
        invalid[8] = std::numeric_limits<double>::quiet_NaN();
        ok &= check(nm_raster_stroke(canvas, invalid.data()) == 1, "NaN rejected");
        invalid = stroke;
        invalid[5] = 256;
        ok &= check(nm_raster_stroke(canvas, invalid.data()) == 1, "color range checked");
        nm_raster_destroy(canvas);
    }
    ok &= check(nm_raster_create(0, height) == nullptr, "zero dimension rejected");
    ok &= check(nm_raster_create(16385, height) == nullptr, "oversize rejected");
    ok &= check(nm_raster_segments_rgba8(width, height, nullptr, 1,
                                         batch.data(), batch.size()) == 1, "null batch rejected");
    // These source Canvas2D strokes straddle the 256px boundary. A line
    // touching the interior contributes two pixels; the next line and the
    // left-side line are wholly outside and must contribute nothing.
    const std::array<double, 9> touching_right = {
        256.2324490754339, 146.3538158527735, 256.2511810533704,
        146.13846845986566, 0.5, 255, 255, 255, 0.894};
    const std::array<double, 9> outside_right = {
        256.2511810533704, 146.13846845986566, 256.2699130313068,
        145.92312106695783, 0.5, 255, 255, 255, 0.85};
    const std::array<double, 9> outside_left = {
        -0.26646906677150983, 221.25633717962546, -0.61078479269432,
        221.24975757421518, 0.5, 255, 255, 255, 0.21};
    auto* edge_canvas = nm_raster_create(256, 256);
    ok &= check(edge_canvas != nullptr, "edge canvas create");
    if (edge_canvas) {
        std::array<uint8_t, 256 * 256 * 4> edge_pixels{}, before_outside{};
        ok &= check(nm_raster_stroke(edge_canvas, touching_right.data()) == 0,
                    "touching right edge stroke");
        ok &= check(nm_raster_read_rgba8(edge_canvas, edge_pixels.data(), edge_pixels.size()) == 0,
                    "touching right edge read");
        ok &= check(edge_pixels[(145 * 256 + 255) * 4 + 3] == 6 &&
                    edge_pixels[(146 * 256 + 255) * 4 + 3] == 24,
                    "touching edge matches source Canvas coverage");
        before_outside = edge_pixels;
        ok &= check(nm_raster_stroke(edge_canvas, outside_right.data()) == 0 &&
                    nm_raster_stroke(edge_canvas, outside_left.data()) == 0,
                    "off-canvas strokes accepted");
        ok &= check(nm_raster_read_rgba8(edge_canvas, edge_pixels.data(), edge_pixels.size()) == 0 &&
                    edge_pixels == before_outside,
                    "fully off-canvas strokes leave pixels unchanged");
        nm_raster_destroy(edge_canvas);
    }
    nm_raster_destroy(nullptr);
    return ok ? 0 : 1;
}
