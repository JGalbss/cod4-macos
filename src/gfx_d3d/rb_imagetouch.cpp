#include "rb_backend.h"
#include "rb_shade.h"
#include "rb_logfile.h"
#include "r_image.h"
#include "rb_state.h"
#include "r_utils.h"

int __cdecl RB_CompareTouchImages(const GfxImage *const *e0, const GfxImage *const *e1)
{
    const GfxImage *image0 = *e0;
    const GfxImage *image1 = *e1;

    if (!image1->semantic)
        return -1;
    if (!image0->semantic)
        return 1;
    if (image1->cardMemory.platform[0] != image0->cardMemory.platform[0])
        return image1->cardMemory.platform[0] - image0->cardMemory.platform[0];
    if (image0->mapType == image1->mapType)
        return 0;
    return image0->mapType - image1->mapType;
}

void __cdecl RB_TouchImage(GfxImage *image)
{
    if (image->mapType == MAPTYPE_2D)
    {
        R_SetCodeImageTexture(&gfxCmdBufSourceState, TEXTURE_SRC_CODE_FEEDBACK, image);
        R_Set2D(&gfxCmdBufSourceState);
        RB_DrawStretchPic(
            rgp.feedbackReplaceMaterial,
            0.0,
            0.0,
            8.0,
            8.0,
            0.0,
            0.0,
            1.0,
            1.0,
            0xFFFFFFFF,
            GFX_PRIM_STATS_CODE);
        RB_EndTessSurface();
    }
}

void __cdecl RB_TouchAllImages()
{
    const char *v0; // eax
    const char *v1; // eax
    int v2; // [esp+0h] [ebp-201Ch]
    int hr; // [esp+4h] [ebp-2018h]
    bool inScene; // [esp+Bh] [ebp-2011h]
    unsigned int i; // [esp+Ch] [ebp-2010h]
    [[maybe_unused]] int v6; // [esp+10h] [ebp-200Ch]
    ImageList imageList; // [esp+14h] [ebp-2008h] BYREF

    inScene = dx.inScene;
    if (!dx.inScene)
    {
        do
        {
            if (r_logFile && r_logFile->current.integer)
                RB_LogPrint("dx.device->BeginScene()\n");
            hr = dx.device->BeginScene();
            if (hr < 0)
            {
                do
                {
                    ++g_disableRendering;
                    v0 = R_ErrorDescription(hr);
                    Com_Error(ERR_FATAL, ".\\rb_imagetouch.cpp (%i) dx.device->BeginScene() failed: %s\n", 60, v0);
                } while (alwaysfails);
            }
        } while (alwaysfails);
    }
    if (tess.indexCount)
        RB_EndTessSurface();
    R_GetImageList(&imageList);
    qsort(
        imageList.image,
        imageList.count,
        sizeof(imageList.image[0]),
        (int(__cdecl *)(const void *, const void *))RB_CompareTouchImages);
    v6 = 0;
    for (i = 0; i < imageList.count && imageList.image[i]->semantic; ++i)
    {
        RB_TouchImage(imageList.image[i]);
        v6 += imageList.image[i]->cardMemory.platform[0];
    }
    R_SetCodeImageTexture(&gfxCmdBufSourceState, TEXTURE_SRC_CODE_FEEDBACK, 0);
    if (!inScene)
    {
        do
        {
            if (r_logFile && r_logFile->current.integer)
                RB_LogPrint("dx.device->EndScene()\n");
            v2 = dx.device->EndScene();
            if (v2 < 0)
            {
                do
                {
                    ++g_disableRendering;
                    v1 = R_ErrorDescription(v2);
                    Com_Error(ERR_FATAL, ".\\rb_imagetouch.cpp (%i) dx.device->EndScene() failed: %s\n", 77, v1);
                } while (alwaysfails);
            }
        } while (alwaysfails);
    }
}
