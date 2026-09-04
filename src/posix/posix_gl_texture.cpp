// Upload GfxImage pixels to GL.
//
// Two sources. A handful of images carry their pixels in the zone
// (GfxImageLoadDef::data); the rest - 117 of the 124 in the startup zones - are
// streamed from images/<name>.iwi inside the .iwd archives, which is why every
// material painted as a flat colour before this existed.
//
// The .iwi has its own one-byte format enum whose meaning is not consistent across
// the files shipped with the game. It does not need to be: the zone's GfxImage
// carries the real D3DFORMAT FourCC even when resourceSize is 0, so the header is
// skipped and the bytes are read using the format the engine already knows.

#include "posix_gl_texture.h"

#include "gfx_d3d/r_gfx.h"
#include "gfx_d3d/r_material.h"
#include "qcommon/qcommon.h"
#include "universal/com_files.h"

#include <SDL.h>
#include <SDL_opengl.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unordered_map>

namespace posix_gl {
namespace {

// GL_EXT_texture_compression_s3tc. Declared here so the build does not depend on
// which GL headers the SDK happens to expose in a 2.1 context.
constexpr GLenum kDxt1 = 0x83F1;  // COMPRESSED_RGBA_S3TC_DXT1
constexpr GLenum kDxt3 = 0x83F2;  // COMPRESSED_RGBA_S3TC_DXT3
constexpr GLenum kDxt5 = 0x83F3;  // COMPRESSED_RGBA_S3TC_DXT5

constexpr int kIwiHeaderSize = 28;

// D3DFORMAT values the zone reports.
constexpr unsigned kFmtDxt1 = 0x31545844;  // 'DXT1'
constexpr unsigned kFmtDxt3 = 0x33545844;  // 'DXT3'
constexpr unsigned kFmtDxt5 = 0x35545844;  // 'DXT5'
constexpr unsigned kFmtA8R8G8B8 = 21;      // D3DFMT_A8R8G8B8
constexpr unsigned kFmtA8 = 28;            // D3DFMT_A8
constexpr unsigned kFmtL8 = 50;            // D3DFMT_L8
constexpr unsigned kFmtA8L8 = 51;          // D3DFMT_A8L8 - gradients, lines, highlights

std::unordered_map<const GfxImage *, unsigned int> g_textures;

struct Layout
{
    GLenum glFormat;
    GLenum dataFormat;  // uncompressed only
    int blockBytes;     // compressed only
    int pixelBytes;     // uncompressed only
    bool compressed;
};

bool LayoutForFormat(const unsigned format, Layout *out)
{
    switch (format)
    {
    case kFmtDxt1:      *out = {kDxt1, 0, 8, 0, true};                       return true;
    case kFmtDxt3:      *out = {kDxt3, 0, 16, 0, true};                      return true;
    case kFmtDxt5:      *out = {kDxt5, 0, 16, 0, true};                      return true;
    // D3DFMT_A8R8G8B8 is BGRA in memory order.
    case kFmtA8R8G8B8:  *out = {GL_RGBA, GL_BGRA, 0, 4, false};              return true;
    case kFmtA8:        *out = {GL_ALPHA, GL_ALPHA, 0, 1, false};            return true;
    case kFmtL8:        *out = {GL_LUMINANCE, GL_LUMINANCE, 0, 1, false};    return true;
    // A8L8 is luminance then alpha per pixel, which is GL's own ordering.
    case kFmtA8L8:      *out = {GL_LUMINANCE_ALPHA, GL_LUMINANCE_ALPHA, 0, 2, false}; return true;
    default: break;
    }
    return false;
}

int LevelBytes(const int width, const int height, const Layout &layout)
{
    if (layout.compressed)
    {
        const int blocksX = (width + 3) / 4;
        const int blocksY = (height + 3) / 4;
        return blocksX * blocksY * layout.blockBytes;
    }
    return width * height * layout.pixelBytes;
}

// A few images declare a format whose level does not fit the bytes actually present -
// logo_cod2 says A8R8G8B8 at 512x128, which would need 256 KB in a 148 KB file. Rather
// than upload garbage, work back from the size that IS there.
bool InferLayout(const int width, const int height, const int available, Layout *out)
{
    static const unsigned candidates[] = {kFmtDxt1, kFmtDxt5, kFmtA8L8, kFmtA8R8G8B8, kFmtA8};
    for (const unsigned candidate : candidates)
    {
        Layout layout{};
        if (!LayoutForFormat(candidate, &layout))
            continue;
        if (LevelBytes(width, height, layout) == available)
        {
            *out = layout;
            return true;
        }
    }
    return false;
}

unsigned int Upload(const int width, const int height, const Layout &layout,
                    const unsigned char *pixels, const int byteCount)
{
    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    if (layout.compressed)
    {
        glCompressedTexImage2D(GL_TEXTURE_2D, 0, layout.glFormat, width, height, 0, byteCount, pixels);
    }
    else
    {
        glTexImage2D(GL_TEXTURE_2D, 0, static_cast<GLint>(layout.glFormat), width, height, 0,
                     layout.dataFormat, GL_UNSIGNED_BYTE, pixels);
    }

    if (glGetError() != GL_NO_ERROR)
    {
        glDeleteTextures(1, &texture);
        return 0;
    }

    return texture;
}

// Reads images/<name>.iwi through the engine's own file system, so the .iwd archives
// are searched exactly as the game expects.
unsigned int UploadFromIwi(const GfxImage *image, const Layout &layout)
{
    char path[256];
    Com_sprintf(path, sizeof(path), "images/%s.iwi", image->name);

    void *buffer = nullptr;
    const int length = FS_ReadFile(path, &buffer);
    if (length < kIwiHeaderSize || !buffer)
    {
        if (buffer)
            FS_FreeFile(static_cast<char *>(buffer));
        return 0;
    }

    const auto *bytes = static_cast<const unsigned char *>(buffer);
    unsigned int texture = 0;

    if (std::memcmp(bytes, "IWi", 3) == 0)
    {
        // Mips are stored smallest first, so the full-size level is at the END of the
        // file. The four uint32s at offset 12 are prefix lengths: mips[0] is the whole
        // file and mips[1] is the file without the largest level - which is exactly
        // where that level begins.
        //
        // Reading from the front instead yields a small mip stretched over the quad.
        // That is subtly wrong for artwork and completely wrong for a font atlas,
        // where the glyph table's coordinates then index the wrong rows entirely.
        unsigned int mips[4] = {0, 0, 0, 0};
        std::memcpy(mips, bytes + 12, sizeof(mips));

        const int levelOffset = (mips[1] > 0 && mips[1] < mips[0])
                                    ? static_cast<int>(mips[1])
                                    : kIwiHeaderSize;
        const int available = length - levelOffset;

        Layout use = layout;
        int wanted = LevelBytes(image->width, image->height, use);
        if (wanted != available && InferLayout(image->width, image->height, available, &use))
            wanted = LevelBytes(image->width, image->height, use);

        if (wanted > 0 && levelOffset + wanted <= length)
            texture = Upload(image->width, image->height, use, bytes + levelOffset, wanted);
    }

    FS_FreeFile(static_cast<char *>(buffer));
    return texture;
}

} // namespace

unsigned int TextureForImage(const GfxImage *image)
{
    if (!image || image->width == 0 || image->height == 0)
        return 0;

    const auto cached = g_textures.find(image);
    if (cached != g_textures.end())
        return cached->second;

    unsigned int texture = 0;
    const GfxImageLoadDef *loadDef = image->texture.loadDef;

    Layout layout{};
    if (loadDef && LayoutForFormat(static_cast<unsigned>(loadDef->format), &layout))
    {
        if (loadDef->resourceSize > 0)
            texture = Upload(image->width, image->height, layout, loadDef->data, loadDef->resourceSize);
        else
            texture = UploadFromIwi(image, layout);
    }

    if (!texture && std::getenv("KISAK_TEX_TRACE"))
    {
        const unsigned fmt = loadDef ? static_cast<unsigned>(loadDef->format) : 0;
        char tag[5] = {0};
        for (int k = 0; k < 4; ++k)
        {
            const char ch = static_cast<char>((fmt >> (8 * k)) & 0xFF);
            tag[k] = (ch >= 32 && ch < 127) ? ch : '.';
        }
        Com_Printf(8, "[tex] no texture for '%s' %ux%u fmt=%u '%s' resourceSize=%d\n",
                   image->name ? image->name : "?", image->width, image->height,
                   fmt, tag, loadDef ? loadDef->resourceSize : -1);
    }

    // Cache failures too: a missing file should be looked for once, not every frame.
    g_textures.emplace(image, texture);
    return texture;
}

bool MaterialWantsTexture(const Material *material)
{
    if (!material || !material->textureTable)
        return false;

    for (int i = 0; i < material->textureCount; ++i)
    {
        if (material->textureTable[i].semantic == 0 && material->textureTable[i].u.image)
            return true;
    }
    return false;
}

unsigned int TextureForMaterial(const Material *material)
{
    if (!material || !material->textureTable || material->textureCount == 0)
        return 0;

    // Semantic 0 is the colour map. Anything else - normal, specular - is for the 3D
    // pipeline and would look wrong painted onto a UI quad.
    for (int i = 0; i < material->textureCount; ++i)
    {
        const MaterialTextureDef &def = material->textureTable[i];
        if (def.semantic == 0 && def.u.image)
            return TextureForImage(def.u.image);
    }

    return TextureForImage(material->textureTable[0].u.image);
}

} // namespace posix_gl
