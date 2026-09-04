// Native audio for the POSIX/macOS client.
//
// The original engine delegates mixing and decoding to Miles Sound System.  That
// binary-only Windows backend cannot be part of a native arm64 build, so this file
// consumes the same loaded-sound and sound-alias assets and mixes them through
// SDL's CoreAudio driver.  Apple AudioToolbox decodes container/stream formats.

#include "sound/snd_local.h"
#include "sound/snd_public.h"

#include "database/database.h"
#include "qcommon/qcommon.h"
#include "posix/posix_voice.h"
#include "universal/com_files.h"
#include "universal/com_memory.h"
#include "universal/q_parse.h"

#include <SDL.h>

#if defined(__APPLE__)
#include <AudioToolbox/AudioToolbox.h>
#endif

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <limits>
#include <memory>
#include <mutex>
#include <random>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

void __cdecl BG_RegisterShockVolumeDvars();
void __cdecl CG_GetSoundEntityOrientation(SndEntHandle sndEnt, float *originOut,
                                           float (*axisOut)[3]);
void __cdecl CG_SubtitleSndLengthNotify(int msec, const snd_alias_t *lengthNotifyData);
snd_alias_t *Com_PickSoundAlias(const char *name);

const dvar_t *snd_cinematicVolumeScale = nullptr;
const dvar_t *snd_enable3D = nullptr;
const dvar_t *snd_enableEq = nullptr;
const dvar_t *snd_debugReplace = nullptr;
const dvar_t *snd_debugAlias = nullptr;
const dvar_t *snd_enable2D = nullptr;
const dvar_t *snd_khz = nullptr;
const dvar_t *snd_draw3D = nullptr;
const dvar_t *snd_volume = nullptr;
const dvar_t *snd_errorOnMissing = nullptr;
const dvar_t *snd_drawEqEnts = nullptr;
const dvar_t *snd_enableReverb = nullptr;
const dvar_t *snd_bits = nullptr;
const dvar_t *snd_slaveFadeTime = nullptr;
const dvar_t *snd_enableStream = nullptr;
const dvar_t *snd_drawEqChannels = nullptr;
const dvar_t *snd_levelFadeTime = nullptr;
const dvar_t *snd_touchStreamFilesOnLoad = nullptr;
const dvar_t *snd_outputConfiguration = nullptr;

namespace
{
constexpr int kOutputRate = 48000;
constexpr int kMaxVoices = 53;
constexpr int kMax2DVoices = 8;
constexpr int kMax3DVoices = 32;
constexpr int kMaxGeneralStreamVoices = 8;

struct AudioClip
{
    std::vector<int16_t> samples;
    int sampleRate = 0;
    int channels = 0;

    size_t FrameCount() const
    {
        return channels > 0 ? samples.size() / static_cast<size_t>(channels) : 0;
    }
};

struct Voice
{
    int playbackId = 0;
    std::shared_ptr<AudioClip> clip;
    double frame = 0.0;
    float volume = 1.0f;
    float pitch = 1.0f;
    float origin[3]{};
    float entityOffset[3]{};
    float minDistance = 0.0f;
    float maxDistance = 0.0f;
    float fadeVolume = 1.0f;
    float fadeGoal = 1.0f;
    float fadeRate = 0.0f;
    float slavePercentage = 1.0f;
    int knownLengthMilliseconds = 0;
    int entHandle = -1;
    int entChannel = 0;
    int backgroundTrack = -1;
    int falloffKnotCount = 0;
    float falloffKnots[8][2]{};
    float channelMap[2][2] = {
        {1.0f, 0.0f},
        {0.0f, 1.0f},
    };
    bool looping = false;
    bool spatial = false;
    bool streamed = false;
    bool fullDry = false;
    bool noWet = false;
    bool master = false;
    bool slave = false;
    bool useTimescale = true;
    bool stopAfterFade = false;
    bool hasSubtitle = false;
    bool finished = false;
    bool attached = false;
    std::string aliasName;
    std::string blendAliasName;
    std::string chainAliasName;
    uint64_t loopEpoch = 0;
};

struct Listener
{
    float origin[3]{};
    float axis[3][3] = {
        {1.0f, 0.0f, 0.0f},
        {0.0f, 1.0f, 0.0f},
        {0.0f, 0.0f, 1.0f},
    };
    int clientNum = -1;
    bool active = false;
};

struct ReverbDelay
{
    std::array<float, 2048> samples{};
    int length = 1;
    int cursor = 0;
    float filtered = 0.0f;

    float Comb(const float input, const float feedback, const float damping)
    {
        const float output = samples[cursor];
        filtered = output * (1.0f - damping) + filtered * damping;
        samples[cursor] = input + filtered * feedback;
        if (++cursor >= length)
            cursor = 0;
        return output;
    }

    float AllPass(const float input)
    {
        const float delayed = samples[cursor];
        const float output = delayed - input;
        samples[cursor] = input + delayed * 0.5f;
        if (++cursor >= length)
            cursor = 0;
        return output;
    }
};

struct NativeReverb
{
    std::array<ReverbDelay, 4> leftComb{};
    std::array<ReverbDelay, 4> rightComb{};
    std::array<ReverbDelay, 2> leftAllPass{};
    std::array<ReverbDelay, 2> rightAllPass{};
    std::array<float, 4> leftFeedback{};
    std::array<float, 4> rightFeedback{};
    float currentDamping = 0.45f;
    int configuredRoomType = -1;

    NativeReverb()
    {
        constexpr int leftCombLengths[4] = {1215, 1293, 1391, 1476};
        constexpr int rightCombLengths[4] = {1238, 1316, 1414, 1499};
        constexpr int leftAllPassLengths[2] = {605, 480};
        constexpr int rightAllPassLengths[2] = {628, 503};
        for (int index = 0; index < 4; ++index)
        {
            leftComb[index].length = leftCombLengths[index];
            rightComb[index].length = rightCombLengths[index];
        }
        for (int index = 0; index < 2; ++index)
        {
            leftAllPass[index].length = leftAllPassLengths[index];
            rightAllPass[index].length = rightAllPassLengths[index];
        }
    }

    void Configure(const int roomType)
    {
        // CoD4 room types are the standard EAX environment order. These decay
        // times preserve that model while the delay network replaces Miles/EAX.
        constexpr std::array<float, 26> decaySeconds = {
            1.49f, 0.17f, 0.40f, 1.49f, 0.50f, 2.31f, 4.32f, 3.92f, 2.91f,
            7.24f, 10.05f, 0.30f, 1.49f, 2.70f, 1.49f, 1.49f, 1.49f, 1.49f,
            1.49f, 1.49f, 1.65f, 2.81f, 1.49f, 8.39f, 17.23f, 7.56f
        };
        constexpr std::array<float, 26> damping = {
            0.45f, 0.92f, 0.67f, 0.25f, 0.72f, 0.32f, 0.38f, 0.32f, 0.20f,
            0.28f, 0.30f, 0.88f, 0.58f, 0.30f, 0.48f, 0.72f, 0.55f, 0.64f,
            0.48f, 0.62f, 0.42f, 0.32f, 0.90f, 0.15f, 0.12f, 0.18f
        };
        const int preset = std::clamp(roomType, 0, static_cast<int>(decaySeconds.size()) - 1);
        const float decay = decaySeconds[preset];
        currentDamping = damping[preset];
        configuredRoomType = preset;
        for (int index = 0; index < 4; ++index)
        {
            const float leftDelaySeconds = static_cast<float>(leftComb[index].length) / kOutputRate;
            const float rightDelaySeconds = static_cast<float>(rightComb[index].length) / kOutputRate;
            leftFeedback[index] = std::clamp(
                std::pow(0.001f, leftDelaySeconds / decay), 0.05f, 0.975f);
            rightFeedback[index] = std::clamp(
                std::pow(0.001f, rightDelaySeconds / decay), 0.05f, 0.975f);
        }
    }

    void Process(const float input, const int roomType, float *left, float *right)
    {
        if (roomType != configuredRoomType)
            Configure(roomType);
        float leftSum = 0.0f;
        float rightSum = 0.0f;
        for (int index = 0; index < 4; ++index)
        {
            leftSum += leftComb[index].Comb(
                input * 0.08f, leftFeedback[index], currentDamping);
            rightSum += rightComb[index].Comb(
                input * 0.08f, rightFeedback[index], currentDamping);
        }
        for (int index = 0; index < 2; ++index)
        {
            leftSum = leftAllPass[index].AllPass(leftSum);
            rightSum = rightAllPass[index].AllPass(rightSum);
        }
        *left = leftSum * 0.25f;
        *right = rightSum * 0.25f;
    }
};

struct NativeMixerState
{
    snd_channelvolgroup channelGroups[4]{};
    int currentChannelGroup = 0;
    snd_enveffect environmentGroups[3]{};
    int currentEnvironmentGroup = 0;
    snd_volume_info_t masterFade{1.0f, 1.0f, 0.0f};
    float slaveLerp = 0.0f;
};

struct PhysicsSoundRequest
{
    snd_alias_list_t *aliasList = nullptr;
    float origin[3]{};
};

SDL_AudioDeviceID g_audioDevice = 0;
SDL_AudioSpec g_audioSpec{};
std::mutex g_audioMutex;
std::mutex g_physicsSoundMutex;
std::vector<Voice> g_voices;
std::array<PhysicsSoundRequest, 32> g_physicsSounds{};
int g_physicsSoundCount = 0;
Listener g_listener;
// Keep decoded clips alive. Letting the final Voice release a weakly-cached clip
// caused repeated decoding of footsteps, foley, and UI sounds and could also free
// large sample buffers from inside CoreAudio's real-time callback.
std::unordered_map<const LoadedSound *, std::shared_ptr<AudioClip>> g_loadedClips;
std::unordered_set<unsigned char *> g_ownedSoundData;
std::unordered_map<std::string, std::shared_ptr<AudioClip>> g_streamedClips;
std::atomic<float> g_masterVolume{0.8f};
std::atomic<bool> g_reverbEnabled{true};
std::atomic<int> g_nextPlaybackId{1};
std::atomic<int> g_slaveFadeMilliseconds{500};
std::atomic<float> g_soundTimescale{1.0f};
std::atomic<unsigned int> g_callbackRemovedBackgroundMask{0};
std::atomic<uint64_t> g_callbackClippedSamples{0};
// Peak magnitude in thousandths, accumulated by the real-time callback and
// consumed only by the opt-in trace on the game thread.
std::atomic<unsigned int> g_callbackPeakMilli{0};
std::minstd_rand g_random{0x434f4434u};
bool g_initialized = false;
bool g_traceAudio = false;
int g_reportedClips = 0;
int g_reportedAliases = 0;
snd_entchannel_info_t g_entChannels[64]{};
int g_entChannelCount = 0;
int g_ambientPrimaryTrack = 1;
uint64_t g_loopEpoch = 1;
NativeMixerState g_mixer;
NativeReverb g_reverb;

void UpdateVolumeRamp(snd_volume_info_t *volume, const float elapsedMilliseconds)
{
    if (!volume || volume->goalrate == 0.0f)
        return;
    volume->volume += elapsedMilliseconds * volume->goalrate;
    if ((volume->goalrate > 0.0f && volume->volume >= volume->goalvolume)
        || (volume->goalrate < 0.0f && volume->volume <= volume->goalvolume))
    {
        volume->volume = volume->goalvolume;
        volume->goalrate = 0.0f;
    }
}

void UpdateEnvironmentRamp(snd_enveffect *effect, const float elapsedMilliseconds)
{
    if (!effect)
        return;
    snd_volume_info_t dry{effect->drylevel, effect->drygoal, effect->dryrate};
    snd_volume_info_t wet{effect->wetlevel, effect->wetgoal, effect->wetrate};
    UpdateVolumeRamp(&dry, elapsedMilliseconds);
    UpdateVolumeRamp(&wet, elapsedMilliseconds);
    effect->drylevel = dry.volume;
    effect->dryrate = dry.goalrate;
    effect->wetlevel = wet.volume;
    effect->wetrate = wet.goalrate;
}

void ResetMixerStateLocked()
{
    std::memset(&g_mixer, 0, sizeof(g_mixer));
    g_mixer.currentChannelGroup = 0;
    g_mixer.channelGroups[0].active = true;
    for (int channel = 0; channel < 64; ++channel)
    {
        snd_volume_info_t &volume = g_mixer.channelGroups[0].channelvol[channel];
        volume.volume = 1.0f;
        volume.goalvolume = 1.0f;
    }
    g_mixer.currentEnvironmentGroup = 0;
    g_mixer.environmentGroups[0].active = true;
    g_mixer.environmentGroups[0].roomtype = 0;
    g_mixer.environmentGroups[0].drylevel = 1.0f;
    g_mixer.environmentGroups[0].drygoal = 1.0f;
    g_mixer.masterFade.volume = 1.0f;
    g_mixer.masterFade.goalvolume = 1.0f;
}

void DeactivateChannelVolumesLocked(const int priority, int fadeMilliseconds)
{
    if (priority <= 0 || priority >= 4)
        return;
    snd_channelvolgroup &deactivated = g_mixer.channelGroups[priority];
    deactivated.active = false;
    if (g_mixer.currentChannelGroup != priority)
        return;

    int nextPriority = priority - 1;
    while (nextPriority >= 0 && !g_mixer.channelGroups[nextPriority].active)
        --nextPriority;
    if (nextPriority < 0)
        nextPriority = 0;
    fadeMilliseconds = std::max(fadeMilliseconds, 1);
    snd_channelvolgroup &next = g_mixer.channelGroups[nextPriority];
    for (int channel = 0; channel < g_entChannelCount; ++channel)
    {
        next.channelvol[channel].volume = deactivated.channelvol[channel].volume;
        next.channelvol[channel].goalrate =
            (next.channelvol[channel].goalvolume - next.channelvol[channel].volume)
            / static_cast<float>(fadeMilliseconds);
    }
    g_mixer.currentChannelGroup = nextPriority;
}

void DeactivateEnvironmentEffectsLocked(const int priority, int fadeMilliseconds)
{
    if (priority <= 0 || priority >= 3)
        return;
    snd_enveffect &deactivated = g_mixer.environmentGroups[priority];
    deactivated.active = false;
    if (g_mixer.currentEnvironmentGroup != priority)
        return;

    int nextPriority = priority - 1;
    while (nextPriority >= 0 && !g_mixer.environmentGroups[nextPriority].active)
        --nextPriority;
    if (nextPriority < 0)
        nextPriority = 0;
    fadeMilliseconds = std::max(fadeMilliseconds, 1);
    snd_enveffect &next = g_mixer.environmentGroups[nextPriority];
    next.drylevel = deactivated.drylevel;
    next.dryrate = (next.drygoal - next.drylevel) / static_cast<float>(fadeMilliseconds);
    next.wetlevel = deactivated.wetlevel;
    next.wetrate = (next.wetgoal - next.wetlevel) / static_cast<float>(fadeMilliseconds);
    g_mixer.currentEnvironmentGroup = nextPriority;
}

float ClampUnit(const float value)
{
    return std::max(-1.0f, std::min(1.0f, value));
}

int16_t FloatToSample(const float value)
{
    return static_cast<int16_t>(std::lrint(ClampUnit(value) * 32767.0f));
}

uint16_t ReadLe16(const uint8_t *data)
{
    return static_cast<uint16_t>(data[0] | static_cast<uint16_t>(data[1]) << 8);
}

uint32_t ReadLe32(const uint8_t *data)
{
    return static_cast<uint32_t>(data[0])
        | static_cast<uint32_t>(data[1]) << 8
        | static_cast<uint32_t>(data[2]) << 16
        | static_cast<uint32_t>(data[3]) << 24;
}

void AppendLe16(std::vector<uint8_t> *data, const uint16_t value)
{
    data->push_back(static_cast<uint8_t>(value));
    data->push_back(static_cast<uint8_t>(value >> 8));
}

void AppendLe32(std::vector<uint8_t> *data, const uint32_t value)
{
    data->push_back(static_cast<uint8_t>(value));
    data->push_back(static_cast<uint8_t>(value >> 8));
    data->push_back(static_cast<uint8_t>(value >> 16));
    data->push_back(static_cast<uint8_t>(value >> 24));
}

void AppendFourCC(std::vector<uint8_t> *data, const char value[4])
{
    data->insert(data->end(), value, value + 4);
}

#if defined(__APPLE__)
struct MemoryAudioFile
{
    const uint8_t *bytes = nullptr;
    size_t size = 0;
};

OSStatus AudioRead(void *clientData, const SInt64 position, const UInt32 requestCount,
                   void *buffer, UInt32 *actualCount)
{
    const auto *file = static_cast<const MemoryAudioFile *>(clientData);
    if (!file || position < 0 || static_cast<uint64_t>(position) >= file->size)
    {
        *actualCount = 0;
        return noErr;
    }
    const size_t available = file->size - static_cast<size_t>(position);
    const size_t count = std::min<size_t>(requestCount, available);
    std::memcpy(buffer, file->bytes + position, count);
    *actualCount = static_cast<UInt32>(count);
    return noErr;
}

SInt64 AudioSize(void *clientData)
{
    const auto *file = static_cast<const MemoryAudioFile *>(clientData);
    return file ? static_cast<SInt64>(file->size) : 0;
}

std::shared_ptr<AudioClip> DecodeContainer(const uint8_t *bytes, const size_t byteCount)
{
    if (!bytes || byteCount < 16)
        return {};

    MemoryAudioFile memory{bytes, byteCount};
    AudioFileID audioFile = nullptr;
    OSStatus status = AudioFileOpenWithCallbacks(
        &memory, AudioRead, nullptr, AudioSize, nullptr, 0, &audioFile);
    if (status != noErr || !audioFile)
        return {};

    ExtAudioFileRef extended = nullptr;
    status = ExtAudioFileWrapAudioFileID(audioFile, false, &extended);
    if (status != noErr || !extended)
    {
        AudioFileClose(audioFile);
        return {};
    }

    AudioStreamBasicDescription source{};
    UInt32 sourceSize = sizeof(source);
    status = ExtAudioFileGetProperty(extended, kExtAudioFileProperty_FileDataFormat,
                                     &sourceSize, &source);
    const UInt32 targetChannels = status == noErr && source.mChannelsPerFrame == 1 ? 1u : 2u;
    AudioStreamBasicDescription target{};
    target.mSampleRate = kOutputRate;
    target.mFormatID = kAudioFormatLinearPCM;
    target.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    target.mBytesPerPacket = targetChannels * sizeof(int16_t);
    target.mFramesPerPacket = 1;
    target.mBytesPerFrame = target.mBytesPerPacket;
    target.mChannelsPerFrame = targetChannels;
    target.mBitsPerChannel = 16;
    status = ExtAudioFileSetProperty(extended, kExtAudioFileProperty_ClientDataFormat,
                                     sizeof(target), &target);
    if (status != noErr)
    {
        ExtAudioFileDispose(extended);
        AudioFileClose(audioFile);
        return {};
    }

    auto clip = std::make_shared<AudioClip>();
    clip->sampleRate = kOutputRate;
    clip->channels = static_cast<int>(targetChannels);
    constexpr UInt32 kChunkFrames = 4096;
    std::vector<int16_t> chunk(static_cast<size_t>(kChunkFrames) * targetChannels);
    for (;;)
    {
        UInt32 frames = kChunkFrames;
        AudioBufferList buffers{};
        buffers.mNumberBuffers = 1;
        buffers.mBuffers[0].mNumberChannels = targetChannels;
        buffers.mBuffers[0].mDataByteSize = static_cast<UInt32>(chunk.size() * sizeof(int16_t));
        buffers.mBuffers[0].mData = chunk.data();
        status = ExtAudioFileRead(extended, &frames, &buffers);
        if (status != noErr || !frames)
            break;
        clip->samples.insert(clip->samples.end(), chunk.begin(),
                             chunk.begin() + frames * targetChannels);
        // A corrupt stream must not allocate without limit.
        if (clip->samples.size()
            > static_cast<size_t>(kOutputRate) * targetChannels * 60 * 30)
            break;
    }

    ExtAudioFileDispose(extended);
    AudioFileClose(audioFile);
    return !clip->samples.empty() ? clip : std::shared_ptr<AudioClip>();
}
#else
std::shared_ptr<AudioClip> DecodeContainer(const uint8_t *, size_t)
{
    return {};
}
#endif

std::vector<uint8_t> WrapImaAdpcmAsWave(const MssSoundCOD4 &sound)
{
    const uint16_t channels = static_cast<uint16_t>(std::max(1, sound.info.channels));
    const uint16_t blockAlign = static_cast<uint16_t>(sound.info.block_size);
    if (!blockAlign || !sound.data || !sound.info.data_len || !sound.info.rate)
        return {};
    const uint16_t samplesPerBlock = static_cast<uint16_t>(
        1 + (blockAlign - 4 * channels) * 2 / channels);
    const uint32_t averageBytes = sound.info.rate * blockAlign
        / std::max<uint16_t>(samplesPerBlock, 1);

    std::vector<uint8_t> wave;
    wave.reserve(static_cast<size_t>(sound.info.data_len) + 64);
    AppendFourCC(&wave, "RIFF");
    AppendLe32(&wave, 52u + sound.info.data_len);
    AppendFourCC(&wave, "WAVE");
    AppendFourCC(&wave, "fmt ");
    AppendLe32(&wave, 20);
    AppendLe16(&wave, 17); // WAVE_FORMAT_IMA_ADPCM
    AppendLe16(&wave, channels);
    AppendLe32(&wave, sound.info.rate);
    AppendLe32(&wave, averageBytes);
    AppendLe16(&wave, blockAlign);
    AppendLe16(&wave, 4);
    AppendLe16(&wave, 2);
    AppendLe16(&wave, samplesPerBlock);
    AppendFourCC(&wave, "fact");
    AppendLe32(&wave, 4);
    AppendLe32(&wave, sound.info.samples);
    AppendFourCC(&wave, "data");
    AppendLe32(&wave, sound.info.data_len);
    wave.insert(wave.end(), sound.data, sound.data + sound.info.data_len);
    if (wave.size() & 1)
        wave.push_back(0);
    return wave;
}

std::shared_ptr<AudioClip> DecodePcm(const MssSoundCOD4 &sound)
{
    const uint8_t *data = sound.data ? sound.data
        : static_cast<const uint8_t *>(sound.info.data_ptr);
    const int channels = sound.info.channels;
    const int bits = sound.info.bits;
    if (!data || !sound.info.data_len || sound.info.rate == 0 || channels <= 0
        || channels > 8 || (bits != 8 && bits != 16 && bits != 24 && bits != 32))
        return {};

    const size_t bytesPerSample = static_cast<size_t>(bits / 8);
    const size_t sampleCount = sound.info.data_len / bytesPerSample;
    if (sampleCount < static_cast<size_t>(channels))
        return {};
    auto clip = std::make_shared<AudioClip>();
    clip->sampleRate = static_cast<int>(sound.info.rate);
    clip->channels = channels;
    clip->samples.resize(sampleCount);
    for (size_t i = 0; i < sampleCount; ++i)
    {
        const uint8_t *sample = data + i * bytesPerSample;
        int32_t value = 0;
        if (sound.info.format == 3 && bits == 32)
        {
            float floatValue = 0.0f;
            std::memcpy(&floatValue, sample, sizeof(floatValue));
            clip->samples[i] = FloatToSample(floatValue);
            continue;
        }
        switch (bits)
        {
        case 8:
            value = (static_cast<int>(sample[0]) - 128) << 8;
            break;
        case 16:
            value = static_cast<int16_t>(ReadLe16(sample));
            break;
        case 24:
            value = static_cast<int32_t>(sample[0] | sample[1] << 8 | sample[2] << 16);
            if (value & 0x800000)
                value |= ~0xffffff;
            value >>= 8;
            break;
        case 32:
            value = static_cast<int32_t>(ReadLe32(sample)) >> 16;
            break;
        }
        clip->samples[i] = static_cast<int16_t>(std::clamp(value, -32768, 32767));
    }
    return clip;
}

std::shared_ptr<AudioClip> ClipForLoadedSound(const LoadedSound *loaded)
{
    if (!loaded)
        return {};
    const auto cached = g_loadedClips.find(loaded);
    if (cached != g_loadedClips.end())
        return cached->second;

    const MssSoundCOD4 &sound = loaded->sound;
    std::shared_ptr<AudioClip> clip;
    if (sound.info.format == 1 || sound.info.format == 3)
        clip = DecodePcm(sound);
    else
    {
        const uint8_t *data = sound.data ? sound.data
            : static_cast<const uint8_t *>(sound.info.data_ptr);
        clip = DecodeContainer(data, sound.info.data_len);
        if (!clip && sound.info.format == 17)
        {
            const std::vector<uint8_t> wave = WrapImaAdpcmAsWave(sound);
            clip = DecodeContainer(wave.data(), wave.size());
        }
    }

    if (clip)
        g_loadedClips[loaded] = clip;
    if (g_reportedClips++ < 24)
    {
        Com_Printf(9,
            "[coreaudio] loaded '%s': format=%d rate=%u bits=%d channels=%d bytes=%u %s\n",
            loaded->name ? loaded->name : "(unnamed)", sound.info.format,
            sound.info.rate, sound.info.bits, sound.info.channels, sound.info.data_len,
            clip ? "decoded" : "FAILED");
    }
    return clip;
}

std::string StreamPath(const SoundFile *soundFile)
{
    if (!soundFile)
        return {};
    const char *const directory = soundFile->u.streamSnd.filename.info.raw.dir;
    const char *const name = soundFile->u.streamSnd.filename.info.raw.name;
    if (!name || !*name)
        return {};
    std::string path = "sound/";
    if (directory && *directory)
    {
        path += directory;
        path += '/';
    }
    path += name;
    std::replace(path.begin(), path.end(), '\\', '/');
    return path;
}

std::shared_ptr<AudioClip> ClipForStream(const SoundFile *soundFile)
{
    const std::string path = StreamPath(soundFile);
    if (path.empty())
        return {};
    const auto cached = g_streamedClips.find(path);
    if (cached != g_streamedClips.end())
        return cached->second;

    void *buffer = nullptr;
    const int byteCount = FS_ReadFile(path.c_str(), &buffer);
    if (byteCount <= 0 || !buffer)
    {
        if (buffer)
            FS_FreeFile(static_cast<char *>(buffer));
        Com_PrintWarning(9, "[coreaudio] stream not found: %s\n", path.c_str());
        return {};
    }
    auto clip = DecodeContainer(static_cast<const uint8_t *>(buffer), byteCount);
    FS_FreeFile(static_cast<char *>(buffer));
    if (clip)
        g_streamedClips[path] = clip;
    if (g_reportedClips++ < 24)
        Com_Printf(9, "[coreaudio] stream '%s': %d bytes %s\n", path.c_str(), byteCount,
                   clip ? "decoded" : "FAILED");
    return clip;
}

std::shared_ptr<AudioClip> ClipForAlias(const snd_alias_t *alias, bool *streamed)
{
    if (!alias || !alias->soundFile || !alias->soundFile->exists)
        return {};
    if (alias->soundFile->type == 1)
    {
        if (streamed)
            *streamed = false;
        return ClipForLoadedSound(alias->soundFile->u.loadSnd);
    }
    if (alias->soundFile->type == 2)
    {
        if (streamed)
            *streamed = true;
        return ClipForStream(alias->soundFile);
    }
    return {};
}

bool IsNullSoundFile(const SoundFile *soundFile)
{
    return soundFile && soundFile->type == 1 && soundFile->u.loadSnd
        && soundFile->u.loadSnd->name
        && I_stricmp(soundFile->u.loadSnd->name, "null.wav") == 0;
}

float RandomRange(const float minimum, const float maximum)
{
    if (maximum <= minimum)
        return minimum;
    return minimum + std::generate_canonical<float, 16>(g_random) * (maximum - minimum);
}

float FalloffCurveValue(const Voice &voice, const float fraction)
{
    const int knotCount = std::clamp(voice.falloffKnotCount, 0, 8);
    if (knotCount < 2)
        return 1.0f - std::clamp(fraction, 0.0f, 1.0f);

    const float clamped = std::clamp(fraction, 0.0f, 1.0f);
    if (clamped <= voice.falloffKnots[0][0])
        return std::clamp(voice.falloffKnots[0][1], 0.0f, 1.0f);
    for (int knot = 1; knot < knotCount; ++knot)
    {
        if (clamped <= voice.falloffKnots[knot][0])
        {
            const float x0 = voice.falloffKnots[knot - 1][0];
            const float x1 = voice.falloffKnots[knot][0];
            const float span = x1 - x0;
            if (span <= 0.0f)
                return std::clamp(voice.falloffKnots[knot][1], 0.0f, 1.0f);
            const float t = std::clamp((clamped - x0) / span, 0.0f, 1.0f);
            return std::clamp(
                voice.falloffKnots[knot - 1][1]
                    + (voice.falloffKnots[knot][1] - voice.falloffKnots[knot - 1][1]) * t,
                0.0f, 1.0f);
        }
    }
    return std::clamp(voice.falloffKnots[knotCount - 1][1], 0.0f, 1.0f);
}

void SpatialGains(const Voice &voice, const Listener &listener, float *left, float *right)
{
    float gain = voice.volume;
    if (voice.entChannel >= 0 && voice.entChannel < g_entChannelCount)
    {
        gain *= g_mixer.channelGroups[g_mixer.currentChannelGroup]
                    .channelvol[voice.entChannel].volume;
    }
    if (voice.slave && !voice.master && g_mixer.slaveLerp > 0.0f)
    {
        gain *= 1.0f - (1.0f - voice.slavePercentage) * g_mixer.slaveLerp;
    }
    // Miles halves a mono 3D sample before spatialization because the single
    // source channel feeds both output sides.  Without the same compensation,
    // emitters, impacts, remote weapons, and other players' movement are much
    // louder than their authored mix even though local 2D weapons sound right.
    if (voice.spatial && voice.clip && voice.clip->channels == 1)
        gain *= 0.5f;
    float pan = 0.0f;
    if (voice.spatial && listener.active)
    {
        const float dx = voice.origin[0] - listener.origin[0];
        const float dy = voice.origin[1] - listener.origin[1];
        const float dz = voice.origin[2] - listener.origin[2];
        const float distance = std::sqrt(dx * dx + dy * dy + dz * dz);
        if (voice.maxDistance > voice.minDistance && distance > voice.minDistance)
        {
            const float fraction = (distance - voice.minDistance)
                / (voice.maxDistance - voice.minDistance);
            gain *= fraction < 1.0f ? FalloffCurveValue(voice, fraction) : 0.0f;
        }
        if (distance > 0.001f)
        {
            // CoD's axis[1] points left (the legacy Miles bridge converted it
            // with -transformed[1]); our panner's positive side is right.
            pan = -(dx * listener.axis[1][0] + dy * listener.axis[1][1]
                + dz * listener.axis[1][2]) / distance;
            pan = ClampUnit(pan);
        }
    }
    else if (!voice.spatial)
    {
        *left = gain;
        *right = gain;
        return;
    }
    // Equal-power pan preserves energy as a spatial source moves across stereo.
    constexpr float kHalfPi = 1.57079632679f;
    *left = gain * std::cos((pan + 1.0f) * 0.5f * kHalfPi);
    *right = gain * std::sin((pan + 1.0f) * 0.5f * kHalfPi);
}

void AudioCallback(void *, Uint8 *stream, const int byteCount)
{
    auto *output = reinterpret_cast<int16_t *>(stream);
    const int outputFrames = byteCount / (2 * static_cast<int>(sizeof(int16_t)));
    std::fill(output, output + outputFrames * 2, 0);

    std::lock_guard<std::mutex> held(g_audioMutex);
    const Listener listener = g_listener;
    const float elapsedMilliseconds = static_cast<float>(outputFrames) * 1000.0f
        / static_cast<float>(std::max(1, g_audioSpec.freq));
    for (int channel = 0; channel < g_entChannelCount; ++channel)
    {
        UpdateVolumeRamp(
            &g_mixer.channelGroups[g_mixer.currentChannelGroup].channelvol[channel],
            elapsedMilliseconds);
    }
    UpdateEnvironmentRamp(&g_mixer.environmentGroups[g_mixer.currentEnvironmentGroup],
                          elapsedMilliseconds);
    UpdateVolumeRamp(&g_mixer.masterFade, elapsedMilliseconds);
    const bool masterPlaying = std::any_of(g_voices.begin(), g_voices.end(), [](const Voice &voice)
    {
        return voice.master && !voice.finished && voice.frame >= 0.0
            && (!voice.stopAfterFade || voice.fadeVolume > 0.0f);
    });
    const int slaveFadeMilliseconds = g_slaveFadeMilliseconds.load(std::memory_order_relaxed);
    if (slaveFadeMilliseconds > 0)
    {
        const float change = elapsedMilliseconds / static_cast<float>(slaveFadeMilliseconds);
        g_mixer.slaveLerp = std::clamp(
            g_mixer.slaveLerp + (masterPlaying ? change : -change), 0.0f, 1.0f);
    }
    else
    {
        g_mixer.slaveLerp = masterPlaying ? 1.0f : 0.0f;
    }
    // The original mixer reserves 25% headroom here; SND_GetVolumeNormalized
    // multiplies it back for UI/cinematic queries.  Omitting this made dense
    // firefights and physics impacts clip even when isolated samples sounded fine.
    const float master = g_masterVolume.load(std::memory_order_relaxed)
        * g_mixer.masterFade.volume * 0.75f;
    const snd_enveffect environment =
        g_mixer.environmentGroups[g_mixer.currentEnvironmentGroup];
    const float wetLevel = g_reverbEnabled.load(std::memory_order_relaxed)
        ? environment.wetlevel : 0.0f;
    const float soundTimescale = g_soundTimescale.load(std::memory_order_relaxed);

    // Real-time callbacks must not churn malloc/free on every 512-frame buffer.
    thread_local std::vector<float> mixed;
    thread_local std::vector<float> reverbInput;
    mixed.resize(static_cast<size_t>(outputFrames) * 2);
    reverbInput.resize(static_cast<size_t>(outputFrames));
    std::fill(mixed.begin(), mixed.end(), 0.0f);
    std::fill(reverbInput.begin(), reverbInput.end(), 0.0f);

    for (Voice &voice : g_voices)
    {
        if (!voice.clip || !voice.clip->FrameCount())
            continue;
        const AudioClip &clip = *voice.clip;
        float leftGain = 0.0f;
        float rightGain = 0.0f;
        SpatialGains(voice, listener, &leftGain, &rightGain);
        leftGain *= master;
        rightGain *= master;
        const float dryGain = voice.fullDry ? 1.0f : environment.drylevel;
        const float fadeStep = voice.fadeRate * 1000.0f / kOutputRate;
        const double advance = static_cast<double>(clip.sampleRate) / kOutputRate
            * std::max(0.05f, voice.pitch)
            * (voice.useTimescale ? soundTimescale : 1.0f);
        const size_t frameCount = clip.FrameCount();
        for (int frame = 0; frame < outputFrames; ++frame)
        {
            const auto updateFade = [&voice, fadeStep]()
            {
                if (voice.fadeRate == 0.0f)
                    return;
                voice.fadeVolume += fadeStep;
                if ((voice.fadeRate > 0.0f && voice.fadeVolume >= voice.fadeGoal)
                    || (voice.fadeRate < 0.0f && voice.fadeVolume <= voice.fadeGoal))
                {
                    voice.fadeVolume = voice.fadeGoal;
                    voice.fadeRate = 0.0f;
                }
            };
            if (voice.frame < 0.0)
            {
                voice.frame += 1.0;
                updateFade();
                continue;
            }
            size_t sourceFrame = static_cast<size_t>(voice.frame);
            if (sourceFrame >= frameCount)
            {
                if (!voice.looping)
                    break;
                voice.frame = std::fmod(voice.frame, static_cast<double>(frameCount));
                sourceFrame = static_cast<size_t>(voice.frame);
            }
            size_t nextFrame = sourceFrame + 1;
            if (nextFrame >= frameCount)
                nextFrame = voice.looping ? 0 : sourceFrame;
            const float interpolation = static_cast<float>(
                voice.frame - static_cast<double>(sourceFrame));
            const size_t base = sourceFrame * clip.channels;
            const size_t nextBase = nextFrame * clip.channels;
            const float left0 = clip.samples[base] * (1.0f / 32768.0f);
            const float left1 = clip.samples[nextBase] * (1.0f / 32768.0f);
            float leftSample = left0 + (left1 - left0) * interpolation;
            float rightSample = leftSample;
            if (clip.channels > 1)
            {
                const float right0 = clip.samples[base + 1] * (1.0f / 32768.0f);
                const float right1 = clip.samples[nextBase + 1] * (1.0f / 32768.0f);
                rightSample = right0 + (right1 - right0) * interpolation;
            }
            if (voice.spatial && clip.channels > 1)
            {
                leftSample = rightSample = (leftSample + rightSample) * 0.5f;
            }
            else if (!voice.spatial)
            {
                const float sourceLeft = leftSample;
                const float sourceRight = clip.channels > 1 ? rightSample : 0.0f;
                leftSample = sourceLeft * voice.channelMap[0][0]
                    + sourceRight * voice.channelMap[0][1];
                rightSample = sourceLeft * voice.channelMap[1][0]
                    + sourceRight * voice.channelMap[1][1];
            }
            const float leftVoice = leftSample * leftGain;
            const float rightVoice = rightSample * rightGain;
            mixed[frame * 2] += leftVoice * dryGain * voice.fadeVolume;
            mixed[frame * 2 + 1] += rightVoice * dryGain * voice.fadeVolume;
            if (!voice.noWet)
                reverbInput[frame] += (leftVoice + rightVoice) * 0.5f * voice.fadeVolume;
            voice.frame += advance;
            updateFade();
        }
    }
    PosixVoice_Mix(mixed.data(), outputFrames, kOutputRate);
    if (g_traceAudio)
    {
        for (const Voice &voice : g_voices)
        {
            const bool remove = (voice.stopAfterFade && voice.fadeVolume <= 0.0f)
                || (!voice.looping && (!voice.clip
                    || (voice.frame >= voice.clip->FrameCount() && voice.chainAliasName.empty())));
            if (remove && voice.backgroundTrack >= 0 && voice.backgroundTrack < 32)
            {
                g_callbackRemovedBackgroundMask.fetch_or(
                    1u << static_cast<unsigned int>(voice.backgroundTrack),
                    std::memory_order_relaxed);
            }
        }
    }

    uint64_t clippedSamples = 0;
    float callbackPeak = 0.0f;
    for (int frame = 0; frame < outputFrames; ++frame)
    {
        float reverbLeft = 0.0f;
        float reverbRight = 0.0f;
        if (wetLevel > 0.0001f || environment.wetgoal > 0.0001f)
        {
            g_reverb.Process(reverbInput[frame],
                             environment.roomtype, &reverbLeft, &reverbRight);
        }
        // FloatToSample only clips actual overloads; unlike an always-on tanh it
        // leaves the authored waveform and transient response unchanged below 0 dBFS.
        const float finalLeft = mixed[frame * 2] + reverbLeft * wetLevel;
        const float finalRight = mixed[frame * 2 + 1] + reverbRight * wetLevel;
        callbackPeak = std::max(callbackPeak, std::max(std::fabs(finalLeft), std::fabs(finalRight)));
        clippedSamples += finalLeft < -1.0f || finalLeft > 1.0f;
        clippedSamples += finalRight < -1.0f || finalRight > 1.0f;
        output[frame * 2] = FloatToSample(finalLeft);
        output[frame * 2 + 1] = FloatToSample(finalRight);
    }
    if (g_traceAudio)
    {
        g_callbackClippedSamples.fetch_add(clippedSamples, std::memory_order_relaxed);
        const unsigned int peakMilli = static_cast<unsigned int>(std::min(
            callbackPeak * 1000.0f, static_cast<float>(std::numeric_limits<unsigned int>::max())));
        unsigned int previous = g_callbackPeakMilli.load(std::memory_order_relaxed);
        while (previous < peakMilli
            && !g_callbackPeakMilli.compare_exchange_weak(
                previous, peakMilli, std::memory_order_relaxed, std::memory_order_relaxed))
        {
        }
    }

    for (Voice &voice : g_voices)
    {
        if (!voice.looping && voice.clip && voice.frame >= voice.clip->FrameCount()
            && !voice.chainAliasName.empty())
        {
            voice.finished = true;
        }
    }
    g_voices.erase(std::remove_if(g_voices.begin(), g_voices.end(), [](const Voice &voice)
    {
        return (voice.stopAfterFade && voice.fadeVolume <= 0.0f)
            || (!voice.looping && (!voice.clip
                || (voice.frame >= voice.clip->FrameCount() && voice.chainAliasName.empty())));
    }), g_voices.end());
}

int StartAlias(const snd_alias_t *alias, const SndEntHandle sndEnt, const float *origin,
               const int timeshift, const float volumeScale, const bool forceLocal,
               const int backgroundTrack, const int fadeMilliseconds = 0,
               const float startFraction = 0.0f, const snd_alias_t *blendAlias = nullptr,
               const float blendFraction = 0.0f, bool *continued = nullptr,
               const bool treatAsMaster = false, const bool useTimescale = true)
{
    if (continued)
        *continued = false;
    if (!g_audioDevice || !alias)
        return -1;
    // Sound designers use null.wav as a weighted "play nothing" variation.
    // The original engine exits before allocating a channel for it.
    if (IsNullSoundFile(alias->soundFile))
        return -1;
    const snd_alias_t *const alias1 = blendAlias ? blendAlias : alias;
    const float blend = std::clamp(blendFraction, 0.0f, 1.0f);
    const int entChannel = (alias->flags & 0x3f00) >> 8;
    const bool channelIs3D = entChannel >= 0 && entChannel < g_entChannelCount
        && g_entChannels[entChannel].is3d;
    if ((channelIs3D && snd_enable3D && !snd_enable3D->current.enabled)
        || (!channelIs3D && snd_enable2D && !snd_enable2D->current.enabled))
    {
        return -1;
    }
    // The Windows backend rejects streamed aliases while snd_enableStream is
    // disabled.  Check the authored sound-file type before decoding so the
    // dvar also prevents the file I/O/cache population Miles would skip.
    if (alias->soundFile && alias->soundFile->type == 2
        && snd_enableStream && !snd_enableStream->current.enabled)
    {
        return -1;
    }
    const float blendedMaxDistance = alias->distMax
        + (alias1->distMax - alias->distMax) * blend;
    Listener listener;
    if (channelIs3D && origin)
    {
        std::lock_guard<std::mutex> held(g_audioMutex);
        listener = g_listener;
    }
    if (channelIs3D && origin && listener.active && blendedMaxDistance > 0.0f)
    {
        const float dx = origin[0] - listener.origin[0];
        const float dy = origin[1] - listener.origin[1];
        const float dz = origin[2] - listener.origin[2];
        if (dx * dx + dy * dy + dz * dz > blendedMaxDistance * blendedMaxDistance)
            return -1;
    }
    bool streamed = false;
    std::shared_ptr<AudioClip> clip = ClipForAlias(alias, &streamed);
    if (!clip)
        return -1;

    Voice voice;
    voice.playbackId = g_nextPlaybackId.fetch_add(1, std::memory_order_relaxed);
    if (voice.playbackId <= 0)
    {
        g_nextPlaybackId.store(2, std::memory_order_relaxed);
        voice.playbackId = 1;
    }
    voice.clip = std::move(clip);
    if (voice.clip->channels == 1)
    {
        // CoD4's default mono-to-stereo speaker map uses 0.5 per output.
        voice.channelMap[0][0] = 0.5f;
        voice.channelMap[0][1] = 0.0f;
        voice.channelMap[1][0] = 0.5f;
        voice.channelMap[1][1] = 0.0f;
    }
    if (alias->speakerMap)
    {
        const int sourceMap = voice.clip->channels > 1 ? 1 : 0;
        const MSSChannelMap &map = alias->speakerMap->channelMaps[sourceMap][0];
        if (map.speakerCount >= 2
            && map.speakers[0].numLevels > 0
            && map.speakers[1].numLevels > 0)
        {
            for (int outputChannel = 0; outputChannel < 2; ++outputChannel)
            {
                for (int inputChannel = 0; inputChannel < 2; ++inputChannel)
                {
                    voice.channelMap[outputChannel][inputChannel] =
                        inputChannel < map.speakers[outputChannel].numLevels
                        ? std::clamp(map.speakers[outputChannel].levels[inputChannel], 0.0f, 1.0f)
                        : 0.0f;
                }
            }
        }
    }
    const float volumeMinimum = alias->volMin + (alias1->volMin - alias->volMin) * blend;
    const float volumeMaximum = alias->volMax + (alias1->volMax - alias->volMax) * blend;
    const float pitchMinimum = alias->pitchMin + (alias1->pitchMin - alias->pitchMin) * blend;
    const float pitchMaximum = alias->pitchMax + (alias1->pitchMax - alias->pitchMax) * blend;
    voice.volume = std::clamp(RandomRange(volumeMinimum, volumeMaximum) * volumeScale,
                              0.0f, 1.0f);
    voice.pitch = std::max(0.05f, RandomRange(pitchMinimum, pitchMaximum));
    voice.minDistance = std::max(0.0f,
        alias->distMin + (alias1->distMin - alias->distMin) * blend);
    voice.maxDistance = std::max(voice.minDistance, blendedMaxDistance);
    voice.entHandle = sndEnt.handle;
    voice.entChannel = entChannel;
    voice.backgroundTrack = backgroundTrack;
    voice.looping = (alias->flags & 1) != 0;
    voice.spatial = !forceLocal && channelIs3D && origin && voice.maxDistance > 0.0f;
    voice.streamed = streamed;
    voice.fullDry = (alias->flags & 0x8) != 0;
    voice.noWet = (alias->flags & 0x10) != 0;
    voice.master = treatAsMaster || (alias->flags & 0x2) != 0;
    voice.slave = (alias->flags & 0x4) != 0;
    voice.useTimescale = useTimescale;
    voice.slavePercentage = std::clamp(alias->slavePercentage, 0.0f, 1.0f);
    voice.hasSubtitle = alias->subtitle != nullptr;
    if (!voice.looping && voice.clip->sampleRate > 0)
    {
        voice.knownLengthMilliseconds = std::max(0, static_cast<int>(std::lround(
            static_cast<double>(voice.clip->FrameCount()) * 1000.0
            / (static_cast<double>(voice.clip->sampleRate) * voice.pitch))))
            + std::max(alias->startDelay, 0);
    }
    if (fadeMilliseconds > 0)
    {
        voice.fadeVolume = 0.0f;
        voice.fadeGoal = 1.0f;
        voice.fadeRate = 1.0f / static_cast<float>(fadeMilliseconds);
    }
    voice.aliasName = alias->aliasName ? alias->aliasName : "";
    voice.blendAliasName = alias1->aliasName ? alias1->aliasName : voice.aliasName;
    voice.chainAliasName = alias->chainAliasName ? alias->chainAliasName : "";
    voice.loopEpoch = g_loopEpoch;
    if (alias->volumeFalloffCurve)
    {
        voice.falloffKnotCount = std::clamp(alias->volumeFalloffCurve->knotCount, 0, 8);
        std::memcpy(voice.falloffKnots, alias->volumeFalloffCurve->knots,
                    static_cast<size_t>(voice.falloffKnotCount) * sizeof(voice.falloffKnots[0]));
    }
    if (origin)
        std::copy(origin, origin + 3, voice.origin);
    if (voice.spatial && origin && sndEnt.handle != 0xffff)
    {
        float entityOrigin[3]{};
        float entityAxis[3][3]{};
        CG_GetSoundEntityOrientation(sndEnt, entityOrigin, entityAxis);
        const float delta[3] = {
            origin[0] - entityOrigin[0],
            origin[1] - entityOrigin[1],
            origin[2] - entityOrigin[2],
        };
        for (int axis = 0; axis < 3; ++axis)
        {
            voice.entityOffset[axis] = delta[0] * entityAxis[axis][0]
                + delta[1] * entityAxis[axis][1]
                + delta[2] * entityAxis[axis][2];
        }
        voice.attached = true;
    }
    bool hasStartPosition = false;
    if (startFraction > 0.0f)
    {
        voice.frame = std::clamp(startFraction, 0.0f, 1.0f)
            * static_cast<double>(voice.clip->FrameCount());
        hasStartPosition = voice.frame > 0.0;
    }
    else if (timeshift > 0)
    {
        voice.frame = static_cast<double>(timeshift) * voice.clip->sampleRate / 1000.0;
        hasStartPosition = true;
    }
    else if ((alias->flags & 0x20) != 0 && voice.clip->FrameCount() > 0)
    {
        voice.frame = RandomRange(0.0f, static_cast<float>(voice.clip->FrameCount()));
        hasStartPosition = voice.frame > 0.0;
    }
    if (alias->startDelay > 0 && !hasStartPosition)
        voice.frame -= static_cast<double>(alias->startDelay) * kOutputRate / 1000.0;

    // SND_StartAlias{2D,3D,Stream} report "not played" when a delayed network
    // event has already run past the sample.  Do this before channel eviction;
    // otherwise a stale sound can displace a live one for an audio callback.
    if (timeshift > 0
        && voice.frame >= static_cast<double>(voice.clip->FrameCount()))
    {
        return -1;
    }

    std::lock_guard<std::mutex> held(g_audioMutex);
    if (voice.looping)
    {
        for (Voice &current : g_voices)
        {
            if (current.entHandle == voice.entHandle && current.aliasName == voice.aliasName
                && current.blendAliasName == voice.blendAliasName
                && current.backgroundTrack == voice.backgroundTrack)
            {
                current.origin[0] = voice.origin[0];
                current.origin[1] = voice.origin[1];
                current.origin[2] = voice.origin[2];
                std::copy(std::begin(voice.entityOffset), std::end(voice.entityOffset),
                          current.entityOffset);
                current.attached = voice.attached;
                current.volume = std::clamp(volumeMinimum * volumeScale, 0.0f, 1.0f);
                current.pitch = std::max(0.05f, pitchMinimum);
                current.minDistance = voice.minDistance;
                current.maxDistance = voice.maxDistance;
                current.master = voice.master;
                current.slave = voice.slave;
                current.slavePercentage = voice.slavePercentage;
                current.useTimescale = voice.useTimescale;
                current.loopEpoch = g_loopEpoch;
                current.stopAfterFade = false;
                current.fadeGoal = 1.0f;
                if (fadeMilliseconds > 0)
                {
                    current.fadeRate = (1.0f - current.fadeVolume)
                        / static_cast<float>(fadeMilliseconds);
                }
                else
                {
                    current.fadeVolume = 1.0f;
                    current.fadeRate = 0.0f;
                }
                if (continued)
                    *continued = true;
                return current.playbackId;
            }
        }
    }
    if (voice.backgroundTrack < 0
        && voice.entChannel >= 0 && voice.entChannel < g_entChannelCount
        && g_entChannels[voice.entChannel].isRestricted)
    {
        g_voices.erase(std::remove_if(g_voices.begin(), g_voices.end(), [&voice](const Voice &current)
        {
            return current.entHandle == voice.entHandle
                && current.entChannel == voice.entChannel
                && current.backgroundTrack < 0;
        }), g_voices.end());
    }
    if (backgroundTrack >= 0)
    {
        g_voices.erase(std::remove_if(g_voices.begin(), g_voices.end(), [backgroundTrack](const Voice &v)
        {
            return v.backgroundTrack == backgroundTrack;
        }), g_voices.end());
    }
    const int channelVoiceLimit = voice.entChannel >= 0 && voice.entChannel < g_entChannelCount
        ? g_entChannels[voice.entChannel].maxVoices : kMaxVoices;
    const int channelVoiceCount = static_cast<int>(std::count_if(
        g_voices.begin(), g_voices.end(), [&voice](const Voice &current)
        {
            return current.entChannel == voice.entChannel;
        }));
    if (channelVoiceCount >= channelVoiceLimit)
        return -1;

    // Match the original Miles allocation: 8 loaded 2D voices, 32 loaded 3D
    // voices, five dedicated background tracks, and eight general streams.
    // Keeping these pools distinct prevents a field full of looping emitters
    // from evicting music, dialog, UI, or weapon audio.
    const auto samePool = [&voice](const Voice &current)
    {
        if (voice.backgroundTrack >= 0 || current.backgroundTrack >= 0)
            return false;
        if (voice.streamed != current.streamed)
            return false;
        return voice.streamed || voice.spatial == current.spatial;
    };
    const int poolLimit = voice.backgroundTrack >= 0 ? kMaxVoices
        : voice.streamed ? kMaxGeneralStreamVoices
        : voice.spatial ? kMax3DVoices : kMax2DVoices;
    const int poolCount = static_cast<int>(std::count_if(
        g_voices.begin(), g_voices.end(), samePool));
    if (poolCount >= poolLimit)
    {
        const int newPriority = voice.entChannel >= 0 && voice.entChannel < g_entChannelCount
            ? g_entChannels[voice.entChannel].priority : 0;
        const float newDx = voice.origin[0] - g_listener.origin[0];
        const float newDy = voice.origin[1] - g_listener.origin[1];
        const float newDz = voice.origin[2] - g_listener.origin[2];
        const float newDistanceSquared = newDx * newDx + newDy * newDy + newDz * newDz;
        auto replaceable = g_voices.end();
        int replaceablePriority = newPriority;
        float replaceableMetric = voice.spatial ? newDistanceSquared : -voice.volume;
        for (auto current = g_voices.begin(); current != g_voices.end(); ++current)
        {
            if (!samePool(*current) || (!voice.hasSubtitle && current->hasSubtitle))
                continue;
            const int currentPriority = current->entChannel >= 0
                    && current->entChannel < g_entChannelCount
                ? g_entChannels[current->entChannel].priority : 0;
            if (currentPriority > newPriority)
                continue;
            const float dx = current->origin[0] - g_listener.origin[0];
            const float dy = current->origin[1] - g_listener.origin[1];
            const float dz = current->origin[2] - g_listener.origin[2];
            const float metric = voice.spatial ? dx * dx + dy * dy + dz * dz
                                                : -current->volume;
            if (replaceable == g_voices.end()
                || currentPriority < replaceablePriority
                || (currentPriority == replaceablePriority && metric > replaceableMetric))
            {
                replaceable = current;
                replaceablePriority = currentPriority;
                replaceableMetric = metric;
            }
        }
        if (replaceable == g_voices.end()
            || (replaceablePriority == newPriority
                && replaceableMetric <= (voice.spatial ? newDistanceSquared : -voice.volume)))
        {
            return -1;
        }
        g_voices.erase(replaceable);
    }
    const int playbackId = voice.playbackId;
    if (g_traceAudio && g_reportedAliases++ < 192)
    {
        Com_Printf(9,
            "[coreaudio:alias] '%s' ch=%d(prio=%d,max=%d) %s rate=%d srcch=%d loop=%d flags=0x%x "
            "map=[%.2f %.2f; %.2f %.2f] curve=%d wet=%d dry=%s secondary='%s' chain='%s'\n",
            voice.aliasName.c_str(), voice.entChannel,
            voice.entChannel >= 0 && voice.entChannel < g_entChannelCount
                ? g_entChannels[voice.entChannel].priority : 0,
            voice.entChannel >= 0 && voice.entChannel < g_entChannelCount
                ? g_entChannels[voice.entChannel].maxVoices : 0,
            voice.spatial ? "3d" : "2d", voice.clip->sampleRate, voice.clip->channels,
            voice.looping ? 1 : 0,
            alias->flags, voice.channelMap[0][0], voice.channelMap[0][1],
            voice.channelMap[1][0], voice.channelMap[1][1], voice.falloffKnotCount,
            voice.noWet ? 0 : 1, voice.fullDry ? "full" : "environment",
            alias->secondaryAliasName ? alias->secondaryAliasName : "",
            voice.chainAliasName.c_str());
    }
    g_voices.push_back(std::move(voice));
    if (g_traceAudio && backgroundTrack >= 0)
        Com_Printf(9, "[coreaudio:background] started track=%d id=%d voices=%zu\n",
                   backgroundTrack, playbackId, g_voices.size());
    return playbackId;
}

int StartAliasTree(const snd_alias_t *alias0, const snd_alias_t *alias1,
                   const float lerp, const float volumeScale,
                   const SndEntHandle sndEnt, const float *origin,
                   const int timeshift, const bool forceLocal,
                   const bool treatAsMaster, const bool useTimescale,
                   const int recursionDepth = 0)
{
    if (!alias0)
        return -1;

    bool continued = false;
    const int playbackId = StartAlias(
        alias0, sndEnt, origin, timeshift, volumeScale, forceLocal, -1,
        0, 0.0f, alias1 ? alias1 : alias0, lerp, &continued,
        treatAsMaster, useTimescale);

    // Sound aliases often build a single authored event from several samples
    // (shot body, mechanical tail, distant report, foley, etc.).  The Windows
    // mixer recursively submitted that entire secondary chain.  A continued
    // primary loop only refreshes a secondary when that secondary also loops.
    if (alias0->secondaryAliasName && recursionDepth < 10
        && (!alias0->aliasName
            || I_stricmp(alias0->aliasName, alias0->secondaryAliasName) != 0))
    {
        if (snd_alias_t *secondary = Com_PickSoundAlias(alias0->secondaryAliasName))
        {
            if (!continued || (secondary->flags & 1) != 0)
            {
                StartAliasTree(secondary, secondary, lerp, volumeScale,
                               sndEnt, origin, timeshift, forceLocal,
                               treatAsMaster, useTimescale, recursionDepth + 1);
            }
        }
    }
    return playbackId;
}

void RegisterSoundDvars()
{
    snd_volume = Dvar_RegisterFloat("snd_volume", 0.8f, 0.0f, 1.0f, DVAR_ARCHIVE,
                                    "Game sound master volume");
    snd_cinematicVolumeScale = Dvar_RegisterFloat("snd_cinematicVolumeScale", 0.85f, 0.0f, 1.0f,
                                                   DVAR_ARCHIVE, "Scales cinematic volume");
    snd_enable2D = Dvar_RegisterBool("snd_enable2D", true, DVAR_CHEAT, "Enable 2D sounds");
    snd_enable3D = Dvar_RegisterBool("snd_enable3D", true, DVAR_CHEAT, "Enable spatial sounds");
    snd_enableStream = Dvar_RegisterBool("snd_enableStream", true, DVAR_CHEAT, "Enable streamed sounds");
    snd_enableReverb = Dvar_RegisterBool("snd_enableReverb", true, DVAR_CHEAT, "Enable reverb");
    snd_enableEq = Dvar_RegisterBool("snd_enableEq", true, DVAR_ARCHIVE, "Enable equalization");
    snd_errorOnMissing = Dvar_RegisterBool("snd_errorOnMissing", false, DVAR_ARCHIVE,
                                           "Raise an error when a sound is missing");
    snd_debugReplace = Dvar_RegisterBool("snd_debugReplace", false, DVAR_CHEAT, "Log voice replacement");
    snd_debugAlias = Dvar_RegisterString("snd_debugAlias", "", DVAR_CHEAT, "Trace an alias");
    snd_draw3D = Dvar_RegisterInt("snd_draw3D", 0, 0, 3, DVAR_CHEAT, "Draw spatial sound positions");
    snd_drawEqEnts = Dvar_RegisterBool("snd_drawEqEnts", false, DVAR_CHEAT, "Draw EQ entities");
    snd_drawEqChannels = Dvar_RegisterBool("snd_drawEqChannels", false, 0x81u,
                                           "Draw EQ channel state");
    snd_bits = Dvar_RegisterInt("snd_bits", 16, 8, 32, DVAR_ARCHIVE, "Output sample precision");
    snd_khz = Dvar_RegisterInt("snd_khz", 48, 11, 48, DVAR_ARCHIVE, "Output sample rate in kHz");
    snd_slaveFadeTime = Dvar_RegisterInt("snd_slaveFadeTime", 500, 0, 5000, DVAR_ARCHIVE,
                                         "Slave channel fade time");
    snd_levelFadeTime = Dvar_RegisterInt("snd_levelFadeTime", 250, 0, 5000, DVAR_ARCHIVE,
                                         "Level-start audio fade time");
    snd_touchStreamFilesOnLoad = Dvar_RegisterBool("snd_touchStreamFilesOnLoad", false, DVAR_ARCHIVE,
                                                   "Validate streamed files while loading");
    snd_outputConfiguration = Dvar_RegisterInt("snd_outputConfiguration", 0, 0, 1, DVAR_ARCHIVE,
                                               "Native stereo output configuration");
}
} // namespace

void SND_PrewarmAliasList(const snd_alias_list_t *aliasList)
{
    if (!g_audioDevice || !aliasList || !aliasList->head || aliasList->count <= 0)
        return;

    // Weapon alias lists are normally tiny.  Keep corrupt/modded assets from
    // turning a prewarm request into an unbounded walk, and only decode sounds
    // already resident in the fastfile.  Streaming is intentionally deferred.
    const int aliasCount = std::min(aliasList->count, 256);
    for (int aliasIndex = 0; aliasIndex < aliasCount; ++aliasIndex)
    {
        const snd_alias_t &alias = aliasList->head[aliasIndex];
        if (alias.soundFile && alias.soundFile->exists
            && alias.soundFile->type == 1 && alias.soundFile->u.loadSnd)
        {
            ClipForLoadedSound(alias.soundFile->u.loadSnd);
        }
    }
}

snd_alias_list_t *Com_FindSoundAliasNoErrors(const char *name)
{
    if (!name || !*name)
        return nullptr;
    const XAssetEntryPoolEntry *entry = DB_FindXAssetEntry(ASSET_TYPE_SOUND, name);
    return entry ? entry->entry.asset.header.sound : nullptr;
}

snd_alias_list_t *Com_TryFindSoundAlias(const char *name)
{
    return Com_FindSoundAliasNoErrors(name);
}

snd_alias_list_t *Com_FindSoundAlias(const char *name)
{
    snd_alias_list_t *list = Com_FindSoundAliasNoErrors(name);
    if (!list && name)
        Com_PrintWarning(9, "Missing soundalias \"%s\".\n", name);
    return list;
}

snd_alias_t *Com_PickSoundAliasFromList(snd_alias_list_t *list)
{
    if (!list || !list->head || list->count <= 0)
        return nullptr;

    int maxSequence = list->head[0].sequence;
    for (int index = 1; index < list->count; ++index)
        maxSequence = std::max(maxSequence, list->head[index].sequence);

    const auto chooseWeighted = [list](const int excludedSequence) -> snd_alias_t *
    {
        snd_alias_t *chosen = nullptr;
        float cumulative = 0.0f;
        for (int index = 0; index < list->count; ++index)
        {
            snd_alias_t *alias = &list->head[index];
            if (alias->sequence == excludedSequence)
                continue;
            const float probability = std::max(0.0f, alias->probability);
            cumulative += probability;
            if (!chosen || (cumulative > 0.0f && RandomRange(0.0f, cumulative) < probability))
                chosen = alias;
        }
        return chosen;
    };

    snd_alias_t *chosen = chooseWeighted(-1);
    // CoD4's authored variation logic avoids selecting the most recently used
    // member of lists with three or more entries, while retaining probability
    // weighting among the remaining variants.
    if (list->count > 2 && chosen && chosen->sequence == maxSequence)
    {
        if (snd_alias_t *alternative = chooseWeighted(maxSequence))
            chosen = alternative;
    }
    if (!chosen)
        chosen = &list->head[0];

    if (maxSequence == std::numeric_limits<int>::max())
    {
        for (int index = 0; index < list->count; ++index)
            list->head[index].sequence = 0;
        maxSequence = 0;
    }
    chosen->sequence = maxSequence + 1;
    return chosen;
}

snd_alias_t *Com_PickSoundAlias(const char *name)
{
    return Com_PickSoundAliasFromList(Com_FindSoundAlias(name));
}

void Com_GetSoundFileName(const snd_alias_t *alias, char *out, const int outSize)
{
    if (!out || outSize <= 0)
        return;
    out[0] = '\0';
    if (!alias || !alias->soundFile)
        return;
    if (alias->soundFile->type == 1)
    {
        const LoadedSound *loaded = alias->soundFile->u.loadSnd;
        if (loaded && loaded->name)
            I_strncpyz(out, loaded->name, outSize);
        return;
    }
    const std::string path = StreamPath(alias->soundFile);
    const char *relative = path.rfind("sound/", 0) == 0 ? path.c_str() + 6 : path.c_str();
    I_strncpyz(out, relative, outSize);
}

void SND_SetData(MssSoundCOD4 *sound, void *source)
{
    if (!sound || !source || !sound->info.data_len)
        return;
    sound->data = static_cast<unsigned char *>(
        Z_Malloc(static_cast<int>(sound->info.data_len), "native sound data", 15));
    if (!sound->data)
        return;
    g_ownedSoundData.insert(sound->data);
    std::memcpy(sound->data, source, sound->info.data_len);
    sound->info.data_ptr = sound->data;
    sound->info.initial_ptr = sound->data;
}

void SND_FreeData(MssSoundCOD4 *sound)
{
    if (!sound || !sound->data)
        return;

    // LoadedSound assets from OAT borrow their bytes from an OatZone.  Only
    // buffers copied by SND_SetData are standalone malloc allocations.
    const auto owned = g_ownedSoundData.find(sound->data);
    if (owned == g_ownedSoundData.end())
        return;
    unsigned char *const data = *owned;
    g_ownedSoundData.erase(owned);
    Z_Free(data, 15);
    sound->data = nullptr;
    sound->info.data_ptr = nullptr;
    sound->info.initial_ptr = nullptr;
}

char SND_InitDriver()
{
    if (g_audioDevice)
        return 1;
    SDL_AudioSpec wanted{};
    wanted.freq = kOutputRate;
    wanted.format = AUDIO_S16SYS;
    wanted.channels = 2;
    wanted.samples = 512;
    wanted.callback = AudioCallback;
    g_audioDevice = SDL_OpenAudioDevice(nullptr, 0, &wanted, &g_audioSpec, 0);
    if (!g_audioDevice)
    {
        Com_PrintError(9, "[coreaudio] SDL_OpenAudioDevice failed: %s\n", SDL_GetError());
        return 0;
    }
    SDL_PauseAudioDevice(g_audioDevice, 0);
    Com_Printf(9, "[coreaudio] native output: %d Hz, %u channels, %u-frame callback (%s)\n",
               g_audioSpec.freq, g_audioSpec.channels, g_audioSpec.samples,
               SDL_GetCurrentAudioDriver() ? SDL_GetCurrentAudioDriver() : "unknown driver");
    return 1;
}

void SND_ParseEntChannelFile(const char *buffer)
{
    g_entChannelCount = 0;
    if (!buffer)
        return;

    Com_BeginParseSession("soundaliases/channels.def");
    Com_SetCSV(1);
    while (buffer && g_entChannelCount < static_cast<int>(std::size(g_entChannels)))
    {
        const char *name = reinterpret_cast<const char *>(Com_Parse(&buffer));
        if (!buffer)
            break;
        if (!name[0] || name[0] == '#')
        {
            Com_SkipRestOfLine(&buffer);
            continue;
        }

        snd_entchannel_info_t &channel = g_entChannels[g_entChannelCount];
        std::memset(&channel, 0, sizeof(channel));
        I_strncpyz(channel.name, name, sizeof(channel.name));
        const char *priority = reinterpret_cast<const char *>(Com_ParseOnLine(&buffer));
        channel.priority = priority[0] ? std::atoi(priority) : 0;
        const char *dimensionality = reinterpret_cast<const char *>(Com_ParseOnLine(&buffer));
        channel.is3d = dimensionality[0] ? I_stricmp(dimensionality, "3d") == 0 : false;
        const char *restriction = reinterpret_cast<const char *>(Com_ParseOnLine(&buffer));
        channel.isRestricted = restriction[0] ? I_stricmp(restriction, "restricted") == 0 : true;
        const char *pausable = reinterpret_cast<const char *>(Com_ParseOnLine(&buffer));
        channel.isPausable = pausable[0] ? I_stricmp(pausable, "pause") == 0 : true;
        const char *maxVoices = reinterpret_cast<const char *>(Com_ParseOnLine(&buffer));
        channel.maxVoices = maxVoices[0] ? std::clamp(std::atoi(maxVoices), 1, kMaxVoices)
                                         : kMaxVoices;
        ++g_entChannelCount;
        Com_SkipRestOfLine(&buffer);
    }
    Com_EndParseSession();
    Com_SetCSV(0);
}

void SND_InitEntChannels()
{
    char *buffer = Com_LoadRawTextFile("soundaliases/channels.def");
    if (!buffer)
    {
        Com_PrintError(9, "[coreaudio] unable to load soundaliases/channels.def\n");
        return;
    }
    SND_ParseEntChannelFile(buffer);
    Com_UnloadRawTextFile(buffer);
    BG_RegisterShockVolumeDvars();
    Com_Printf(9, "[coreaudio] loaded %d entity channels\n", g_entChannelCount);
}

void SND_Init()
{
    RegisterSoundDvars();
    g_traceAudio = std::getenv("KISAK_AUDIO_TRACE") != nullptr;
    g_reportedAliases = 0;
    const float initialMasterVolume = snd_volume->current.value;
    g_masterVolume.store(initialMasterVolume, std::memory_order_relaxed);
    if (initialMasterVolume <= 0.0001f)
    {
        Com_PrintWarning(9,
                         "[coreaudio] snd_volume is 0; native game audio is muted by the active profile\n");
    }
    if (g_initialized)
        return;
    SND_InitEntChannels();
    {
        std::lock_guard<std::mutex> held(g_audioMutex);
        ResetMixerStateLocked();
        g_listener = {};
        g_ambientPrimaryTrack = 1;
        g_loopEpoch = 1;
    }
    g_initialized = SND_InitDriver() != 0;
    if (g_initialized)
        Voice_Init();
}

void SND_ShutdownChannels()
{
    {
        std::lock_guard<std::mutex> held(g_audioMutex);
        g_voices.clear();
    }
    {
        std::lock_guard<std::mutex> held(g_physicsSoundMutex);
        g_physicsSoundCount = 0;
    }
}

void SND_Shutdown()
{
    Voice_Shutdown();
    SND_ShutdownChannels();
    if (g_audioDevice)
    {
        SDL_CloseAudioDevice(g_audioDevice);
        g_audioDevice = 0;
    }
    g_loadedClips.clear();
    g_streamedClips.clear();
    g_initialized = false;
}

void SND_ErrorCleanup()
{
    SND_ShutdownChannels();
}

void SND_StopSounds(const snd_stopsounds_arg_t which)
{
    std::lock_guard<std::mutex> held(g_audioMutex);
    if (g_traceAudio)
        Com_Printf(9, "[coreaudio:stop] mode=0x%x voices=%zu\n", which, g_voices.size());
    if (which == SND_STOP_ALL)
    {
        g_voices.clear();
    }
    else
    {
        g_voices.erase(std::remove_if(g_voices.begin(), g_voices.end(), [which](const Voice &voice)
        {
            if (!voice.streamed)
                return (which & SND_STOP_STREAMED) == 0;
            const bool keepMusic = (which & SND_KEEP_MUSIC) && voice.backgroundTrack == 0;
            const bool keepAmbient = (which & SND_KEEP_AMBIENT) && voice.backgroundTrack > 0;
            return !keepMusic && !keepAmbient;
        }), g_voices.end());
    }
    if ((which & SND_KEEP_REVERB) == 0)
    {
        DeactivateEnvironmentEffectsLocked(2, 0);
        DeactivateEnvironmentEffectsLocked(1, 0);
    }
    if ((which & SND_KEEP_CHANNEL_VOLUMES) == 0)
    {
        DeactivateChannelVolumesLocked(3, 0);
        DeactivateChannelVolumesLocked(2, 0);
        DeactivateChannelVolumesLocked(1, 0);
    }
}

void SND_SetListener(const int localClientNum, const int clientNum, const float *origin,
                     const float (*axis)[3])
{
    if (localClientNum != 0 || !origin || !axis)
        return;
    std::lock_guard<std::mutex> held(g_audioMutex);
    std::copy(origin, origin + 3, g_listener.origin);
    std::memcpy(g_listener.axis, axis, sizeof(g_listener.axis));
    g_listener.clientNum = clientNum;
    g_listener.active = true;
}

void SND_FadeAllSounds(const float volume, const int fadeMilliseconds)
{
    std::lock_guard<std::mutex> held(g_audioMutex);
    const float clamped = std::max(0.0f, volume);
    g_mixer.masterFade.goalvolume = clamped;
    g_mixer.masterFade.goalrate = clamped - g_mixer.masterFade.volume;
    if (fadeMilliseconds > 0)
        g_mixer.masterFade.goalrate /= static_cast<float>(fadeMilliseconds);
    else
    {
        g_mixer.masterFade.volume = clamped;
        g_mixer.masterFade.goalrate = 0.0f;
    }
    if (fadeMilliseconds <= 0 && clamped == 0.0f)
        g_voices.clear();
}

double SND_GetVolumeNormalized()
{
    std::lock_guard<std::mutex> held(g_audioMutex);
    return static_cast<double>(g_masterVolume.load(std::memory_order_relaxed))
        * g_mixer.masterFade.volume;
}

char SND_GetKnownLength(const int playbackId, int *milliseconds)
{
    if (!milliseconds)
        return 0;
    *milliseconds = 0;
    if (playbackId == -1 || playbackId == 0)
        return 1;

    std::lock_guard<std::mutex> held(g_audioMutex);
    const auto voice = std::find_if(g_voices.begin(), g_voices.end(), [playbackId](const Voice &v)
    {
        return v.playbackId == playbackId;
    });
    if (voice == g_voices.end())
        return 0;
    *milliseconds = voice->knownLengthMilliseconds;
    return 1;
}

void DoLengthNotify(const int milliseconds, const snd_alias_t *lengthNotifyData,
                    const SndLengthId id)
{
    if (id == SndLengthNotify_Subtitle)
        CG_SubtitleSndLengthNotify(milliseconds, lengthNotifyData);
}

char SND_AddLengthNotify(const int playbackId, const snd_alias_t *lengthNotifyData,
                         const SndLengthId id)
{
    int milliseconds = 0;
    if (!SND_GetKnownLength(playbackId, &milliseconds))
        return 0;
    DoLengthNotify(milliseconds, lengthNotifyData, id);
    return 1;
}

int SND_PlaySoundAlias(const snd_alias_t *alias, const SndEntHandle sndEnt, const float *origin,
                       const int timeshift, const snd_alias_system_t)
{
    return StartAliasTree(alias, alias, 0.0f, 1.0f, sndEnt, origin, timeshift,
                          false, false, true);
}

int SND_PlaySoundAlias_Internal(const snd_alias_t *alias0, const snd_alias_t *alias1,
                                const float lerp, const float volumeScale,
                                const SndEntHandle sndEnt, const float *origin, int *channel,
                                const int timeshift, const bool treatAsMaster,
                                const bool useTimescale,
                                const snd_alias_system_t system)
{
    if (!alias0)
        return -1;
    const snd_alias_t *const effectiveAlias1 = alias1 ? alias1 : alias0;
    const int id = StartAliasTree(alias0, effectiveAlias1, lerp, volumeScale,
                                  sndEnt, origin, timeshift, false,
                                  treatAsMaster, useTimescale);
    if (channel)
        *channel = id;
    (void)system;
    return id;
}

int SND_PlayBlendedSoundAliases(const snd_alias_t *alias0, const snd_alias_t *alias1,
                                const float lerp, const float volumeScale,
                                const SndEntHandle sndEnt, const float *origin,
                                const int timeshift, const snd_alias_system_t system)
{
    if (!alias0 || !alias1)
        return -1;
    return SND_PlaySoundAlias_Internal(alias0, alias1, lerp, volumeScale, sndEnt,
                                       origin, nullptr, timeshift, false, true, system);
}

int SND_PlaySoundAliasAsMaster(const snd_alias_t *alias, const SndEntHandle sndEnt,
                               const float *origin, const int timeshift,
                               const snd_alias_system_t)
{
    return StartAliasTree(alias, alias, 0.0f, 1.0f, sndEnt, origin, timeshift,
                          false, true, true);
}

int SND_PlayLocalSoundAlias(const unsigned int localClientNum, const snd_alias_t *alias,
                            const snd_alias_system_t)
{
    if (localClientNum != 0)
        return -1;
    float listenerOrigin[3]{};
    {
        std::lock_guard<std::mutex> held(g_audioMutex);
        std::copy(std::begin(g_listener.origin), std::end(g_listener.origin), listenerOrigin);
    }
    // Match the engine path: a normal 2D alias remains 2D, while a mod that
    // intentionally submits a 3D alias as local gets a source at the listener.
    const SndEntHandle localEntity(0);
    return StartAliasTree(alias, alias, 0.0f, 1.0f, localEntity, listenerOrigin, 0,
                          false, false, true);
}

int SND_PlayLocalSoundAliasByName(const unsigned int localClientNum, const char *name,
                                  const snd_alias_system_t system)
{
    return SND_PlayLocalSoundAlias(localClientNum, Com_PickSoundAlias(name), system);
}

void SND_AddPlayFXSoundAlias(snd_alias_t *alias, const SndEntHandle sndEnt, const float *origin)
{
    SND_PlaySoundAlias(alias, sndEnt, origin, 0, SASYS_CGAME);
}

void SND_AddPhysicsSound(snd_alias_list_t *aliasList, float *origin)
{
    if (!aliasList || !origin)
        return;
    std::lock_guard<std::mutex> held(g_physicsSoundMutex);
    if (g_physicsSoundCount >= static_cast<int>(g_physicsSounds.size()))
        return;
    PhysicsSoundRequest &request = g_physicsSounds[g_physicsSoundCount++];
    request.aliasList = aliasList;
    std::copy(origin, origin + 3, request.origin);
}

void SND_PlayFXSounds()
{
    // FX aliases are submitted immediately above; no Windows worker queue is needed.
}

void SND_InitFXSounds()
{
}

void SND_StopSoundsOnEnt(const SndEntHandle ent)
{
    std::lock_guard<std::mutex> held(g_audioMutex);
    if (g_traceAudio)
        Com_Printf(9, "[coreaudio:entity] stop ent=%d voices=%zu\n", ent.handle, g_voices.size());
    g_voices.erase(std::remove_if(g_voices.begin(), g_voices.end(), [ent](const Voice &voice)
    {
        return voice.entHandle == ent.handle;
    }), g_voices.end());
}

void SND_StopSoundAliasOnEnt(const SndEntHandle ent, const char *aliasName)
{
    std::lock_guard<std::mutex> held(g_audioMutex);
    if (g_traceAudio)
        Com_Printf(9, "[coreaudio:entity] stop ent=%d alias='%s' voices=%zu\n",
                   ent.handle, aliasName ? aliasName : "", g_voices.size());
    g_voices.erase(std::remove_if(g_voices.begin(), g_voices.end(), [ent, aliasName](const Voice &voice)
    {
        return voice.entHandle == ent.handle && aliasName
            && (I_stricmp(voice.aliasName.c_str(), aliasName) == 0
                || I_stricmp(voice.blendAliasName.c_str(), aliasName) == 0);
    }), g_voices.end());
}

void SND_StartBackground(const int, const unsigned int track, const snd_alias_t *alias,
                         const int fadeTime, const float fraction, const bool useTimescale,
                         const snd_alias_system_t)
{
    const SndEntHandle background(0xffff);
    StartAlias(alias, background, nullptr, 0, 1.0f, true, static_cast<int>(track),
               std::max(fadeTime, 0), fraction, nullptr, 0.0f, nullptr, false,
               useTimescale);
}

void SND_PlayMusicAlias(const int localClientNum, const snd_alias_t *alias,
                        const bool useTimescale, const snd_alias_system_t system)
{
    SND_StartBackground(localClientNum, 0, alias, 0, 0.0f, useTimescale, system);
}

void SND_PlayAmbientAlias(const int localClientNum, const snd_alias_t *alias,
                          const int fadeTime, const snd_alias_system_t system)
{
    if (!alias)
        return;

    if (g_traceAudio)
        Com_Printf(9, "[coreaudio:ambient] play '%s' fade=%d current=%d\n",
                   alias->aliasName ? alias->aliasName : "", fadeTime,
                   g_ambientPrimaryTrack);

    const char *const aliasName = alias->aliasName ? alias->aliasName : "";
    {
        std::lock_guard<std::mutex> held(g_audioMutex);
        const auto current = std::find_if(g_voices.begin(), g_voices.end(), [](const Voice &voice)
        {
            return voice.backgroundTrack == g_ambientPrimaryTrack && !voice.stopAfterFade;
        });
        if (current != g_voices.end() && current->aliasName == aliasName)
            return;
    }

    const int oldPrimaryTrack = g_ambientPrimaryTrack;
    const int nextPrimaryTrack = 4 - oldPrimaryTrack;
    const float fraction = (alias->flags & 0x20) != 0 ? RandomRange(0.0f, 1.0f) : 0.0f;
    SND_StopBackground(static_cast<unsigned int>(oldPrimaryTrack), fadeTime);
    SND_StopBackground(static_cast<unsigned int>(oldPrimaryTrack + 1), fadeTime);
    SND_StartBackground(localClientNum, static_cast<unsigned int>(nextPrimaryTrack), alias,
                        fadeTime, fraction, true, system);
    if (alias->secondaryAliasName)
    {
        if (snd_alias_t *secondary = Com_PickSoundAlias(alias->secondaryAliasName))
        {
            SND_StartBackground(localClientNum, static_cast<unsigned int>(nextPrimaryTrack + 1),
                                secondary, fadeTime, fraction, true, system);
        }
    }
    g_ambientPrimaryTrack = nextPrimaryTrack;
}

void SND_StopBackground(const unsigned int track, const int fadeTime)
{
    std::lock_guard<std::mutex> held(g_audioMutex);
    if (g_traceAudio)
        Com_Printf(9, "[coreaudio:background] stop track=%u fade=%d voices=%zu\n",
                   track, fadeTime, g_voices.size());
    if (fadeTime <= 0)
    {
        g_voices.erase(std::remove_if(g_voices.begin(), g_voices.end(), [track](const Voice &voice)
        {
            return voice.backgroundTrack == static_cast<int>(track);
        }), g_voices.end());
        return;
    }
    for (Voice &voice : g_voices)
    {
        if (voice.backgroundTrack != static_cast<int>(track))
            continue;
        voice.fadeGoal = 0.0f;
        voice.fadeRate = -voice.fadeVolume / static_cast<float>(fadeTime);
        voice.stopAfterFade = true;
    }
}

void SND_StopMusic(const int fadeTime)
{
    SND_StopBackground(0, fadeTime);
}

void SND_StopAmbient(const int, const int fadeTime)
{
    for (unsigned int track = 1; track <= 4; ++track)
        SND_StopBackground(track, fadeTime);
}

char SND_UpdateBackgroundVolume(const unsigned int track, const int)
{
    std::lock_guard<std::mutex> held(g_audioMutex);
    return std::any_of(g_voices.begin(), g_voices.end(), [track](const Voice &voice)
    {
        return voice.backgroundTrack == static_cast<int>(track);
    }) ? 1 : 0;
}

void SND_UpdatePhysics()
{
    std::array<PhysicsSoundRequest, 32> pending{};
    int count = 0;
    {
        std::lock_guard<std::mutex> held(g_physicsSoundMutex);
        count = g_physicsSoundCount;
        std::copy_n(g_physicsSounds.begin(), count, pending.begin());
        g_physicsSoundCount = 0;
    }
    if (!count || !SND_AnyActiveListeners())
        return;

    const SndEntHandle world(ENTITYNUM_WORLD);
    for (int index = 0; index < count; ++index)
    {
        if (snd_alias_t *alias = Com_PickSoundAliasFromList(pending[index].aliasList))
            SND_PlaySoundAlias(alias, world, pending[index].origin, 0, SASYS_CGAME);
    }
}

void SND_Update()
{
    if (snd_volume)
        g_masterVolume.store(snd_volume->current.value, std::memory_order_relaxed);
    if (snd_enableReverb)
        g_reverbEnabled.store(snd_enableReverb->current.enabled, std::memory_order_relaxed);
    if (snd_slaveFadeTime)
        g_slaveFadeMilliseconds.store(snd_slaveFadeTime->current.integer,
                                      std::memory_order_relaxed);
    float soundTimescale = static_cast<float>(Com_GetTimescaleForSnd());
    if (!(soundTimescale > 0.0f) || !std::isfinite(soundTimescale))
        soundTimescale = 1.0f;
    g_soundTimescale.store(soundTimescale, std::memory_order_relaxed);

    struct PendingChain
    {
        std::string aliasName;
        std::string previousAliasName;
        int entHandle = -1;
        float origin[3]{};
    };
    std::vector<PendingChain> pending;
    {
        std::lock_guard<std::mutex> held(g_audioMutex);
        for (Voice &voice : g_voices)
        {
            if (voice.attached && voice.spatial && !voice.finished)
            {
                float entityOrigin[3]{};
                float entityAxis[3][3]{};
                CG_GetSoundEntityOrientation(SndEntHandle(voice.entHandle), entityOrigin,
                                             entityAxis);
                for (int component = 0; component < 3; ++component)
                {
                    voice.origin[component] = entityOrigin[component]
                        + voice.entityOffset[0] * entityAxis[0][component]
                        + voice.entityOffset[1] * entityAxis[1][component]
                        + voice.entityOffset[2] * entityAxis[2][component];
                }
            }
            if (!voice.finished || voice.chainAliasName.empty())
                continue;
            PendingChain chain;
            chain.aliasName = voice.chainAliasName;
            chain.previousAliasName = voice.aliasName;
            chain.entHandle = voice.entHandle;
            std::copy(std::begin(voice.origin), std::end(voice.origin), chain.origin);
            pending.push_back(std::move(chain));
        }
        g_voices.erase(std::remove_if(g_voices.begin(), g_voices.end(), [](const Voice &voice)
        {
            return voice.finished;
        }), g_voices.end());
    }
    for (const PendingChain &chain : pending)
    {
        snd_alias_t *alias = Com_PickSoundAlias(chain.aliasName.c_str());
        if (!alias || (alias->aliasName && chain.previousAliasName == alias->aliasName))
            continue;
        SND_PlaySoundAlias(alias, SndEntHandle(chain.entHandle), chain.origin, 0, SASYS_CGAME);
    }
    SND_UpdatePhysics();
}

void SND_UpdateLoopingSounds()
{
    std::lock_guard<std::mutex> held(g_audioMutex);
    g_voices.erase(std::remove_if(g_voices.begin(), g_voices.end(), [](const Voice &voice)
    {
        return voice.looping && voice.backgroundTrack < 0 && voice.loopEpoch != g_loopEpoch;
    }), g_voices.end());
    ++g_loopEpoch;
    if (g_traceAudio && g_loopEpoch % 120 == 0)
    {
        const int spatial = static_cast<int>(std::count_if(
            g_voices.begin(), g_voices.end(), [](const Voice &voice)
            {
                return voice.spatial && voice.backgroundTrack < 0;
            }));
        const int background = static_cast<int>(std::count_if(
            g_voices.begin(), g_voices.end(), [](const Voice &voice)
            {
                return voice.backgroundTrack >= 0;
            }));
        Com_Printf(9, "[coreaudio:voices] total=%zu spatial=%d background=%d epoch=%llu "
                      "peak=%.3f clipped=%llu cbg=0x%x\n",
                   g_voices.size(), spatial, background,
                   static_cast<unsigned long long>(g_loopEpoch),
                   static_cast<double>(g_callbackPeakMilli.exchange(0, std::memory_order_relaxed))
                       / 1000.0,
                   static_cast<unsigned long long>(
                       g_callbackClippedSamples.exchange(0, std::memory_order_relaxed)),
                   g_callbackRemovedBackgroundMask.exchange(0, std::memory_order_relaxed));
    }
    if (g_loopEpoch == 0)
    {
        g_loopEpoch = 1;
        for (Voice &voice : g_voices)
            if (voice.looping && voice.backgroundTrack < 0)
                voice.loopEpoch = g_loopEpoch;
    }
}

void SND_SetChannelVolumes(const int priority, const float *channelVolumes,
                           int fadeMilliseconds)
{
    if (priority <= 0 || priority >= 4 || !channelVolumes || fadeMilliseconds < 0)
        return;
    std::lock_guard<std::mutex> held(g_audioMutex);
    snd_channelvolgroup &group = g_mixer.channelGroups[priority];
    group.active = true;
    fadeMilliseconds = std::max(fadeMilliseconds, 1);
    const snd_channelvolgroup &current = g_mixer.channelGroups[g_mixer.currentChannelGroup];
    for (int channel = 0; channel < g_entChannelCount; ++channel)
    {
        snd_volume_info_t &volume = group.channelvol[channel];
        volume.goalvolume = std::clamp(channelVolumes[channel], 0.0f, 1.0f);
        volume.volume = current.channelvol[channel].volume;
        volume.goalrate = (volume.goalvolume - volume.volume)
            / static_cast<float>(fadeMilliseconds);
    }
    if (priority >= g_mixer.currentChannelGroup)
    {
        bool higherActive = false;
        for (int higher = priority + 1; higher < 4; ++higher)
            higherActive |= g_mixer.channelGroups[higher].active;
        if (!higherActive)
            g_mixer.currentChannelGroup = priority;
    }
}

void SND_DeactivateChannelVolumes(const int priority, const int fadeMilliseconds)
{
    if (fadeMilliseconds < 0)
        return;
    std::lock_guard<std::mutex> held(g_audioMutex);
    DeactivateChannelVolumesLocked(priority, fadeMilliseconds);
}

namespace
{
constexpr std::array<const char *, 26> kRoomNames = {
    "generic", "paddedcell", "room", "bathroom", "livingroom", "stoneroom",
    "auditorium", "concerthall", "cave", "arena", "hangar", "carpetedhallway",
    "hallway", "stonecorridor", "alley", "forest", "city", "mountains", "quarry",
    "plain", "parkinglot", "sewerpipe", "underwater", "drugged", "dizzy", "psychotic"
};
}

int SND_RoomtypeFromString(const char *roomName)
{
    if (!roomName)
        return 0;
    for (size_t room = 0; room < kRoomNames.size(); ++room)
    {
        if (I_stricmp(roomName, kRoomNames[room]) == 0)
            return static_cast<int>(room);
    }
    Com_PrintWarning(9, "[coreaudio] unknown room type '%s'; using generic\n", roomName);
    return 0;
}

void SND_SetEnvironmentEffects(const int priority, const char *roomName,
                               const float dryLevel, const float wetLevel,
                               int fadeMilliseconds)
{
    if (priority <= 0 || priority >= 3 || !roomName || fadeMilliseconds < 0)
        return;
    std::lock_guard<std::mutex> held(g_audioMutex);
    snd_enveffect &effect = g_mixer.environmentGroups[priority];
    const snd_enveffect &current =
        g_mixer.environmentGroups[g_mixer.currentEnvironmentGroup];
    effect.active = true;
    effect.roomtype = SND_RoomtypeFromString(roomName);
    effect.drygoal = std::clamp(dryLevel, 0.0f, 1.0f);
    effect.wetgoal = std::clamp(wetLevel, 0.0f, 1.0f);
    effect.drylevel = current.drylevel;
    effect.wetlevel = current.wetlevel;
    fadeMilliseconds = std::max(fadeMilliseconds, 1);
    effect.dryrate = (effect.drygoal - effect.drylevel)
        / static_cast<float>(fadeMilliseconds);
    effect.wetrate = (effect.wetgoal - effect.wetlevel)
        / static_cast<float>(fadeMilliseconds);
    if (priority >= g_mixer.currentEnvironmentGroup)
    {
        bool higherActive = false;
        for (int higher = priority + 1; higher < 3; ++higher)
            higherActive |= g_mixer.environmentGroups[higher].active;
        if (!higherActive)
            g_mixer.currentEnvironmentGroup = priority;
    }
}

void SND_DeactivateEnvironmentEffects(const int priority, const int fadeMilliseconds)
{
    if (fadeMilliseconds < 0)
        return;
    std::lock_guard<std::mutex> held(g_audioMutex);
    DeactivateEnvironmentEffectsLocked(priority, fadeMilliseconds);
}

char SND_AnyActiveListeners()
{
    std::lock_guard<std::mutex> held(g_audioMutex);
    return g_listener.active ? 1 : 0;
}

void SND_DisconnectListener(const int localClientNum)
{
    if (localClientNum != 0)
        return;
    std::lock_guard<std::mutex> held(g_audioMutex);
    g_listener = {};
}

void SND_SaveListeners(snd_listener *listeners)
{
    if (!listeners)
        return;
    std::lock_guard<std::mutex> held(g_audioMutex);
    std::memset(listeners, 0, sizeof(snd_listener) * 2);
    std::memcpy(listeners[0].orient.origin, g_listener.origin, sizeof(g_listener.origin));
    std::memcpy(listeners[0].orient.axis, g_listener.axis, sizeof(g_listener.axis));
    listeners[0].clientNum = g_listener.clientNum;
    listeners[0].active = g_listener.active;
}

void SND_RestoreListeners(snd_listener *listeners)
{
    if (!listeners)
        return;
    std::lock_guard<std::mutex> held(g_audioMutex);
    std::memcpy(g_listener.origin, listeners[0].orient.origin, sizeof(g_listener.origin));
    std::memcpy(g_listener.axis, listeners[0].orient.axis, sizeof(g_listener.axis));
    g_listener.clientNum = listeners[0].clientNum;
    g_listener.active = listeners[0].active;
}

int SND_GetEntChannelCount()
{
    return g_entChannelCount;
}

snd_entchannel_info_t *SND_GetEntChannelName(const int entchannel)
{
    if (entchannel < 0 || entchannel >= g_entChannelCount)
        return nullptr;
    return &g_entChannels[entchannel];
}
