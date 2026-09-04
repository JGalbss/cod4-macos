#pragma once

#include <cstdint>

bool Voice_Init();
void Voice_Shutdown();
bool Voice_SendVoiceData();
double Voice_GetVoiceLevel();
void Voice_Playback();
int Voice_GetLocalVoiceData();
void Voice_IncomingVoiceData(uint8_t talker, uint8_t *data, int packetDataSize);
bool Voice_IsClientTalking(unsigned int clientNum);
char Voice_StartRecording();
char Voice_StopRecording();

// Adds decoded chat directly to the native stereo mix. Called only by the
// CoreAudio output callback; samples are deliberately dry and non-spatial.
void PosixVoice_Mix(float *stereoFrames, int frameCount, int outputRate);
