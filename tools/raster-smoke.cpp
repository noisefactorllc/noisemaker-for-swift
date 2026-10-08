#include <cstdint>
#include <fstream>
#include <iostream>
#include <vector>

#include "NoisemakerRaster.h"

int main(int argc, char** argv) {
    if (argc != 5) return 2;
    const int32_t width = std::stoi(argv[1]);
    const int32_t height = std::stoi(argv[2]);
    std::ifstream input(argv[3], std::ios::binary | std::ios::ate);
    if (!input) return 2;
    const auto length = input.tellg();
    if (length < 0 || length % (9 * sizeof(double)) != 0) return 2;
    std::vector<double> records(static_cast<size_t>(length) / sizeof(double));
    input.seekg(0);
    input.read(reinterpret_cast<char*>(records.data()), length);
    if (!input) return 2;
    std::vector<uint8_t> pixels(static_cast<size_t>(width) * height * 4);
    if (nm_raster_segments_rgba8(width, height, records.data(), records.size() / 9,
                                 pixels.data(), pixels.size()) != 0) return 2;
    std::ofstream output(argv[4], std::ios::binary);
    output.write(reinterpret_cast<const char*>(pixels.data()), pixels.size());
    return output ? 0 : 2;
}
