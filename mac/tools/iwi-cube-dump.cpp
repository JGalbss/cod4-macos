// Decode the top level of a CoD IWI6 BC1, BC2, or BC3 image into PPM.
// This is a renderer-porting diagnostic, intentionally dependency-free.

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

namespace
{
struct IwiHeader6
{
    int8_t format;
    int8_t flags;
    uint16_t dimensions[3];
    uint32_t fileSizeForPicmip[4];
};
static_assert(sizeof(IwiHeader6) == 24);

struct Rgb
{
    uint8_t r;
    uint8_t g;
    uint8_t b;
};

Rgb Rgb565(const uint16_t value)
{
    return {
        static_cast<uint8_t>(((value >> 11) & 31) * 255 / 31),
        static_cast<uint8_t>(((value >> 5) & 63) * 255 / 63),
        static_cast<uint8_t>((value & 31) * 255 / 31),
    };
}

Rgb Mix(const Rgb a, const Rgb b, const unsigned wa, const unsigned wb,
        const unsigned divisor)
{
    return {
        static_cast<uint8_t>((a.r * wa + b.r * wb) / divisor),
        static_cast<uint8_t>((a.g * wa + b.g * wb) / divisor),
        static_cast<uint8_t>((a.b * wa + b.b * wb) / divisor),
    };
}

bool DecodeFace(const uint8_t *source, const unsigned width, const unsigned height,
                Rgb *destination, const unsigned destinationStride,
                const unsigned blockBytes = 8)
{
    if ((width & 3) || (height & 3))
        return false;
    for (unsigned blockY = 0; blockY < height / 4; ++blockY)
    {
        for (unsigned blockX = 0; blockX < width / 4; ++blockX)
        {
            const uint8_t *block = source + (blockY * (width / 4) + blockX) * blockBytes;
            if (blockBytes == 16)
                block += 8; // BC3 alpha block precedes the BC1-compatible RGB block.
            const uint16_t color0 = static_cast<uint16_t>(block[0] | block[1] << 8);
            const uint16_t color1 = static_cast<uint16_t>(block[2] | block[3] << 8);
            std::array<Rgb, 4> palette = {Rgb565(color0), Rgb565(color1), {}, {}};
            if (color0 > color1 || blockBytes == 16)
            {
                palette[2] = Mix(palette[0], palette[1], 2, 1, 3);
                palette[3] = Mix(palette[0], palette[1], 1, 2, 3);
            }
            else
            {
                palette[2] = Mix(palette[0], palette[1], 1, 1, 2);
                palette[3] = {};
            }
            const uint32_t selectors = static_cast<uint32_t>(block[4])
                | static_cast<uint32_t>(block[5]) << 8
                | static_cast<uint32_t>(block[6]) << 16
                | static_cast<uint32_t>(block[7]) << 24;
            for (unsigned y = 0; y < 4; ++y)
            {
                for (unsigned x = 0; x < 4; ++x)
                {
                    const unsigned selector = (selectors >> (2 * (y * 4 + x))) & 3;
                    destination[(blockY * 4 + y) * destinationStride + blockX * 4 + x]
                        = palette[selector];
                }
            }
        }
    }
    return true;
}
} // namespace

int main(const int argc, char **argv)
{
    if (argc != 3)
    {
        std::fprintf(stderr, "usage: %s input.iwi output.ppm\n", argv[0]);
        return 2;
    }
    FILE *input = std::fopen(argv[1], "rb");
    if (!input)
        return 3;
    uint8_t version[4]{};
    IwiHeader6 header{};
    const bool headerRead = std::fread(version, sizeof(version), 1, input) == 1
        && std::fread(&header, sizeof(header), 1, input) == 1;
    const bool bc1Cube = header.format == 0xB && (header.flags & (1u << 2)) != 0
        && header.dimensions[0] == header.dimensions[1];
    const bool bc1Image = header.format == 0xB && (header.flags & (1u << 2)) == 0;
    const bool bc2Image = header.format == 0xC && (header.flags & (1u << 2)) == 0;
    const bool bc3Image = header.format == 0xD && (header.flags & (1u << 2)) == 0;
    if (!headerRead || std::memcmp(version, "IWi", 3) != 0 || version[3] != 6
        || (!bc1Cube && !bc1Image && !bc2Image && !bc3Image))
    {
        std::fclose(input);
        std::fprintf(stderr, "unsupported IWI (need IWI6 BC1, BC2, or BC3)\n");
        return 4;
    }
    const unsigned width = header.dimensions[0];
    const unsigned height = header.dimensions[1];
    const unsigned faceCount = bc1Cube ? 6 : 1;
    const unsigned blockBytes = (bc2Image || bc3Image) ? 16 : 8;
    const size_t faceBytes = static_cast<size_t>(width / 4) * (height / 4) * blockBytes;
    std::vector<uint8_t> compressed(faceBytes * faceCount);
    // Image_LoadDxtc consumes external IWI cubemaps mip-major, from the
    // smallest level to the largest, with all six faces adjacent per mip.
    // Seek to the final six-face block rather than interpreting the beginning
    // of the mip chain as full-resolution BC1 data.
    if (std::fseek(input, -static_cast<long>(compressed.size()), SEEK_END) != 0)
    {
        std::fclose(input);
        return 5;
    }
    if (std::fread(compressed.data(), compressed.size(), 1, input) != 1)
    {
        std::fclose(input);
        return 5;
    }
    std::fclose(input);

    std::vector<Rgb> strip(static_cast<size_t>(width) * faceCount * height);
    for (unsigned face = 0; face < faceCount; ++face)
    {
        if (!DecodeFace(compressed.data() + faceBytes * face, width, height,
                        strip.data() + width * face, width * faceCount, blockBytes))
            return 6;
    }
    FILE *output = std::fopen(argv[2], "wb");
    if (!output)
        return 7;
    std::fprintf(output, "P6\n%u %u\n255\n", width * faceCount, height);
    std::fwrite(strip.data(), sizeof(Rgb), strip.size(), output);
    std::fclose(output);
    return 0;
}
