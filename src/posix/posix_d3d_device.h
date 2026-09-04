#pragma once

/**
 * Create the Direct3D 9 device the renderer draws through, on the SDL window
 * this engine already owns. Only built when KISAK_DXVK is on; without a device
 * the renderer stays disabled and nothing reaches the screen.
 *
 * @return true when dx.device is usable, false with the reason already printed.
 */
bool Posix_CreateD3DDevice();

/**
 * Write the current D3D9 backbuffer to fs_basepath/screenshots as a PPM. Backs the
 * "screenshot" console command under DXVK, where the GL present path that normally
 * captures frames never runs.
 */
void Posix_D3DScreenshot();
