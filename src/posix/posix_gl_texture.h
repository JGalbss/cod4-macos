// GL textures for the engine's GfxImage assets.
#pragma once

struct GfxImage;
struct Material;

namespace posix_gl {

// The GL texture for this image, uploading it on first use. Returns 0 when the image
// has no pixels anywhere - the caller should then draw untextured.
unsigned int TextureForImage(const GfxImage *image);

// The colour map a material paints with, or 0 if it has none.
unsigned int TextureForMaterial(const Material *material);

// True when the material names a colour map, whether or not it loaded.
bool MaterialWantsTexture(const Material *material);

} // namespace posix_gl
