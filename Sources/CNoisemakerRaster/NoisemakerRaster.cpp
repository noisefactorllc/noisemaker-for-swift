#include "NoisemakerRaster.h"

#include <algorithm>
#include <cmath>
#include <cfloat>
#include <limits>
#include <memory>

#include "include/core/SkCanvas.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPaint.h"
#include "include/core/SkSurface.h"

struct NMRasterCanvas {
    int32_t width;
    int32_t height;
    sk_sp<SkColorSpace> srgb;
    sk_sp<SkSurface> surface;
};

namespace {
bool validDimensions(int32_t width, int32_t height) {
    return width > 0 && height > 0 && width <= 16384 && height <= 16384 &&
        static_cast<size_t>(width) <= std::numeric_limits<size_t>::max() /
            static_cast<size_t>(height) / 4;
}

bool validStroke(const double* record) {
    if (!record) return false;
    for (size_t field = 0; field < 9; ++field) {
        if (!std::isfinite(record[field])) return false;
    }
    // SkScalar is float. Reject values that would become infinities at the
    // native boundary even when the caller's doubles are finite.
    for (size_t field = 0; field < 5; ++field) {
        if (record[field] < -FLT_MAX || record[field] > FLT_MAX) return false;
    }
    return record[4] >= 0 && record[5] >= 0 && record[5] <= 255 &&
        record[6] >= 0 && record[6] <= 255 && record[7] >= 0 && record[7] <= 255 &&
        record[8] >= 0 && record[8] <= 1;
}
}  // namespace

extern "C" NMRasterCanvas* nm_raster_create(int32_t width, int32_t height) {
    if (!validDimensions(width, height)) return nullptr;
    try {
        auto result = std::make_unique<NMRasterCanvas>(
            NMRasterCanvas{width, height, SkColorSpace::MakeSRGB(), {}});
        const auto info = SkImageInfo::Make(width, height, kRGBA_8888_SkColorType,
                                            kPremul_SkAlphaType, result->srgb);
        result->surface = SkSurfaces::Raster(info);
        if (!result->surface) return nullptr;
        result->surface->getCanvas()->clear(SK_ColorTRANSPARENT);
        return result.release();
    } catch (...) { return nullptr; }
}

extern "C" int32_t nm_raster_stroke(NMRasterCanvas* canvas, const double record[9]) {
    if (!canvas || !validStroke(record)) return 1;
    try {
        // Canvas2D rejects a stroke whose geometric bounds miss the canvas.
        // Skia's standalone raster surface can otherwise leak AA coverage
        // into an edge pixel from a fully off-canvas line.
        const double radius = record[4] / 2.0;
        if (std::min(record[0], record[2]) - radius >= canvas->width ||
            std::max(record[0], record[2]) + radius <= 0 ||
            std::min(record[1], record[3]) - radius >= canvas->height ||
            std::max(record[1], record[3]) + radius <= 0) return 0;
        SkPaint paint;
        paint.setAntiAlias(true);
        paint.setStyle(SkPaint::kStroke_Style);
        paint.setStrokeCap(SkPaint::kRound_Cap);
        paint.setStrokeJoin(SkPaint::kRound_Join);
        paint.setStrokeWidth(static_cast<SkScalar>(record[4]));
        paint.setColor4f({static_cast<float>(record[5] / 255.0),
                          static_cast<float>(record[6] / 255.0),
                          static_cast<float>(record[7] / 255.0),
                          static_cast<float>(record[8])}, canvas->srgb.get());
        canvas->surface->getCanvas()->drawLine(
            static_cast<SkScalar>(record[0]), static_cast<SkScalar>(record[1]),
            static_cast<SkScalar>(record[2]), static_cast<SkScalar>(record[3]), paint);
        return 0;
    } catch (...) { return 2; }
}

extern "C" int32_t nm_raster_read_rgba8(NMRasterCanvas* canvas,
                                         uint8_t* output, size_t output_bytes) {
    if (!canvas || !output || output_bytes < static_cast<size_t>(canvas->width) * canvas->height * 4) return 1;
    try {
        const auto info = SkImageInfo::Make(canvas->width, canvas->height,
                                            kRGBA_8888_SkColorType, kUnpremul_SkAlphaType,
                                            canvas->srgb);
        return canvas->surface->readPixels(info, output,
                                           static_cast<size_t>(canvas->width) * 4, 0, 0) ? 0 : 2;
    } catch (...) { return 2; }
}

extern "C" void nm_raster_destroy(NMRasterCanvas* canvas) {
    try { delete canvas; } catch (...) {}
}

extern "C" int32_t nm_raster_segments_rgba8(int32_t width, int32_t height,
                                             const double* records, size_t record_count,
                                             uint8_t* output, size_t output_bytes) {
    if (!validDimensions(width, height) || !output || (record_count && !records) ||
        record_count > std::numeric_limits<size_t>::max() / 9 ||
        output_bytes < static_cast<size_t>(width) * height * 4) return 1;
    auto* canvas = nm_raster_create(width, height);
    if (!canvas) return 2;
    int32_t status = 0;
    for (size_t index = 0; index < record_count; ++index) {
        status = nm_raster_stroke(canvas, records + index * 9);
        if (status) break;
    }
    if (!status) status = nm_raster_read_rgba8(canvas, output, output_bytes);
    nm_raster_destroy(canvas);
    return status;
}
