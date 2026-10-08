#ifndef NOISEMAKER_RASTER_H
#define NOISEMAKER_RASTER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Each record has nine doubles: x0, y0, x1, y1, stroke width,
// red, green, blue (0..255), and alpha (0..1). The caller owns both buffers.
// Output is top-down, unpremultiplied sRGB RGBA8 with width * height * 4 bytes.
// Returns 0 on success, 1 for invalid input, and 2 for raster allocation/readback failure.
int32_t nm_raster_segments_rgba8(int32_t width, int32_t height,
                                 const double* records, size_t record_count,
                                 uint8_t* output, size_t output_bytes);

// Streaming form avoids retaining all strokes for large overlays. A canvas is
// local to one caller; destroy it after reading, including when a stroke fails.
typedef struct NMRasterCanvas NMRasterCanvas;
NMRasterCanvas* nm_raster_create(int32_t width, int32_t height);
int32_t nm_raster_stroke(NMRasterCanvas* canvas, const double record[9]);
int32_t nm_raster_read_rgba8(NMRasterCanvas* canvas, uint8_t* output, size_t output_bytes);
void nm_raster_destroy(NMRasterCanvas* canvas);

#ifdef __cplusplus
}
#endif

#endif
