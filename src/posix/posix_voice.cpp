// Native CoD4 multiplayer voice chat.
//
// The packet protocol is unchanged: the client sends one Speex narrowband
// frame per ClientVoicePacket_t and receives the same frames from the server.
// SDL uses CoreAudio for capture on macOS; decoded talkers are mixed into the
// game's existing native output device by PosixVoice_Mix.

#include "posix/posix_voice.h"

#include "client_mp/client_mp.h"
#include "qcommon/qcommon.h"
#include "server_mp/server_mp.h"

#include <SDL.h>
#include <speex/speex.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <mutex>

bool IN_IsTalkKeyHeld();

namespace
{
constexpr int kTalkerCount = 64;
constexpr int kVoiceRate = 8000;
constexpr int kExpectedFrameSamples = 160;
constexpr size_t kPlaybackCapacity = 16384; // just over two seconds at 8 kHz
constexpr size_t kCaptureCapacity = 32768;
constexpr size_t kPlaybackPrebuffer = 320;  // two codec frames / 40 ms

struct TalkerPlayback
{
    void *decoder = nullptr;
    SpeexBits bits{};
    bool bitsInitialized = false;
    std::array<int16_t, kPlaybackCapacity> samples{};
    size_t read = 0;
    size_t write = 0;
    size_t count = 0;
    double phase = 0.0;
    bool primed = false;
};

std::mutex g_voiceMutex;
std::array<TalkerPlayback, kTalkerCount> g_talkers{};
std::array<int, kTalkerCount> g_talkTimes{};
std::array<int16_t, kCaptureCapacity> g_captureSamples{};
size_t g_captureRead = 0;
size_t g_captureWrite = 0;
size_t g_captureCount = 0;

void *g_encoder = nullptr;
SpeexBits g_encodeBits{};
bool g_encodeBitsInitialized = false;
int g_encodeFrameSamples = 0;
int g_encoderQuality = 3;
SDL_AudioDeviceID g_captureDevice = 0;
bool g_captureAttempted = false;
bool g_recording = false;
std::atomic<bool> g_voiceInitialized{false};
bool g_traceVoice = false;
std::atomic<float> g_currentVoiceLevel{0.0f};
std::array<float, 6> g_levelHistory{};
unsigned int g_levelHistoryCursor = 0;
unsigned int g_reportedReceivePackets = 0;
unsigned int g_reportedTransmitPackets = 0;

const dvar_t *g_micScaler = nullptr;

void ResetPlayback(TalkerPlayback *talker)
{
    talker->read = 0;
    talker->write = 0;
    talker->count = 0;
    talker->phase = 0.0;
    talker->primed = false;
}

void CaptureCallback(void *, Uint8 *stream, const int byteCount)
{
    if (!stream || byteCount <= 0)
        return;
    const auto *samples = reinterpret_cast<const int16_t *>(stream);
    const size_t sampleCount = static_cast<size_t>(byteCount) / sizeof(int16_t);
    std::lock_guard<std::mutex> held(g_voiceMutex);
    for (size_t index = 0; index < sampleCount; ++index)
    {
        if (g_captureCount == kCaptureCapacity)
        {
            g_captureRead = (g_captureRead + 1) % kCaptureCapacity;
            --g_captureCount;
        }
        g_captureSamples[g_captureWrite] = samples[index];
        g_captureWrite = (g_captureWrite + 1) % kCaptureCapacity;
        ++g_captureCount;
    }
}

bool OpenCaptureDevice()
{
    if (g_captureDevice)
        return true;
    if (g_captureAttempted)
        return false;
    g_captureAttempted = true;

    SDL_AudioSpec wanted{};
    SDL_AudioSpec obtained{};
    wanted.freq = kVoiceRate;
    wanted.format = AUDIO_S16SYS;
    wanted.channels = 1;
    wanted.samples = 320;
    wanted.callback = CaptureCallback;
    g_captureDevice = SDL_OpenAudioDevice(nullptr, 1, &wanted, &obtained, 0);
    if (!g_captureDevice)
    {
        Com_PrintWarning(9, "[voice] microphone unavailable: %s\n", SDL_GetError());
        return false;
    }
    if (obtained.freq != kVoiceRate || obtained.format != AUDIO_S16SYS
        || obtained.channels != 1)
    {
        Com_PrintWarning(9,
            "[voice] microphone returned unsupported format %d Hz/0x%x/%u channels\n",
            obtained.freq, static_cast<unsigned int>(obtained.format), obtained.channels);
        SDL_CloseAudioDevice(g_captureDevice);
        g_captureDevice = 0;
        return false;
    }
    Com_Printf(9, "[voice] native microphone ready: %d Hz mono, %u-frame callback\n",
               obtained.freq, obtained.samples);
    return true;
}

void QueueDecodedSamples(TalkerPlayback *talker, const int16_t *samples,
                         const size_t sampleCount)
{
    for (size_t index = 0; index < sampleCount; ++index)
    {
        if (talker->count == kPlaybackCapacity)
        {
            talker->read = (talker->read + 1) % kPlaybackCapacity;
            --talker->count;
        }
        talker->samples[talker->write] = samples[index];
        talker->write = (talker->write + 1) % kPlaybackCapacity;
        ++talker->count;
    }
    if (!talker->primed && talker->count >= kPlaybackPrebuffer)
        talker->primed = true;
}

void MixTalker(TalkerPlayback *talker, float *stereoFrames,
               const int frameCount, const int outputRate)
{
    if (!talker->primed || talker->count < 2)
        return;
    double step = static_cast<double>(kVoiceRate) / static_cast<double>(outputRate);
    // Match the old DirectSound jitter correction in spirit: make only a
    // one-percent rate adjustment, inaudible in speech, to absorb packet jitter.
    if (talker->count < 160)
        step *= 0.99;
    else if (talker->count > 5000)
        step *= 1.01;

    for (int frame = 0; frame < frameCount; ++frame)
    {
        if (talker->count < 2)
        {
            ResetPlayback(talker);
            break;
        }
        const size_t next = (talker->read + 1) % kPlaybackCapacity;
        const float sample0 = talker->samples[talker->read] * (1.0f / 32768.0f);
        const float sample1 = talker->samples[next] * (1.0f / 32768.0f);
        const float sample = sample0
            + (sample1 - sample0) * static_cast<float>(talker->phase);
        stereoFrames[frame * 2] += sample;
        stereoFrames[frame * 2 + 1] += sample;
        talker->phase += step;
        while (talker->phase >= 1.0 && talker->count > 1)
        {
            talker->phase -= 1.0;
            talker->read = (talker->read + 1) % kPlaybackCapacity;
            --talker->count;
        }
    }
}

int CurrentVoiceQuality()
{
    return sv_voiceQuality ? std::clamp(sv_voiceQuality->current.integer, 0, 10) : 3;
}

void UpdateEncoderQuality()
{
    const int quality = CurrentVoiceQuality();
    if (quality == g_encoderQuality || !g_encoder)
        return;
    g_encoderQuality = quality;
    speex_encoder_ctl(g_encoder, SPEEX_SET_QUALITY, &g_encoderQuality);
}

bool RunCodecSelfTest()
{
    void *encoder = speex_encoder_init(&speex_nb_mode);
    void *decoder = speex_decoder_init(&speex_nb_mode);
    if (!encoder || !decoder)
    {
        if (encoder)
            speex_encoder_destroy(encoder);
        if (decoder)
            speex_decoder_destroy(decoder);
        return false;
    }
    int sampleRate = kVoiceRate;
    int quality = 3;
    int frameSamples = 0;
    int enhanced = 1;
    speex_encoder_ctl(encoder, SPEEX_SET_SAMPLING_RATE, &sampleRate);
    speex_encoder_ctl(encoder, SPEEX_SET_QUALITY, &quality);
    speex_encoder_ctl(encoder, SPEEX_GET_FRAME_SIZE, &frameSamples);
    speex_decoder_ctl(decoder, SPEEX_SET_ENH, &enhanced);
    speex_decoder_ctl(decoder, SPEEX_SET_SAMPLING_RATE, &sampleRate);

    SpeexBits encodedBits{};
    SpeexBits decodedBits{};
    speex_bits_init(&encodedBits);
    speex_bits_init(&decodedBits);
    std::array<int16_t, kExpectedFrameSamples> source{};
    std::array<int16_t, kExpectedFrameSamples> decoded{};
    for (size_t index = 0; index < source.size(); ++index)
    {
        source[index] = static_cast<int16_t>(std::lround(
            std::sin(static_cast<double>(index) * 6.283185307179586 * 440.0 / kVoiceRate)
            * 12000.0));
    }
    std::array<char, 256> packet{};
    speex_bits_reset(&encodedBits);
    const int encodeResult = speex_encode_int(encoder, source.data(), &encodedBits);
    const int packetBytes = speex_bits_write(&encodedBits, packet.data(),
                                             static_cast<int>(packet.size()));
    speex_bits_read_from(&decodedBits, packet.data(), std::max(packetBytes, 0));
    const int decodeResult = packetBytes > 0
        ? speex_decode_int(decoder, &decodedBits, decoded.data()) : -1;
    long long energy = 0;
    for (const int16_t sample : decoded)
        energy += std::abs(static_cast<int>(sample));

    TalkerPlayback playback{};
    QueueDecodedSamples(&playback, decoded.data(), decoded.size());
    QueueDecodedSamples(&playback, decoded.data(), decoded.size());
    std::array<float, 2048 * 2> mixed{};
    MixTalker(&playback, mixed.data(), 2048, 48000);
    double mixedEnergy = 0.0;
    for (const float sample : mixed)
        mixedEnergy += std::fabs(sample);

    speex_bits_destroy(&decodedBits);
    speex_bits_destroy(&encodedBits);
    speex_decoder_destroy(decoder);
    speex_encoder_destroy(encoder);
    const bool passed = frameSamples == kExpectedFrameSamples && encodeResult >= 0
        && packetBytes > 0 && packetBytes <= static_cast<int>(packet.size())
        && decodeResult == 0 && energy > 0 && mixedEnergy > 0.0;
    Com_Printf(9,
        "[voice:selftest] %s frame=%d packet=%d decoded-energy=%lld mixed-energy=%.1f\n",
        passed ? "passed" : "FAILED", frameSamples, packetBytes, energy, mixedEnergy);
    return passed;
}
} // namespace

bool Voice_Init()
{
    if (g_voiceInitialized.load(std::memory_order_acquire))
        return true;

    (void)Dvar_RegisterBool("winvoice_mic_mute", true, DVAR_ARCHIVE,
                            "Mute microphone monitoring");
    (void)Dvar_RegisterFloat("winvoice_mic_reclevel", 65535.0f, 0.0f, 65535.0f,
                             DVAR_ARCHIVE, "Microphone recording level");
    (void)Dvar_RegisterBool("winvoice_save_voice", false, DVAR_ARCHIVE,
                            "Write received voice data to a file");
    g_micScaler = Dvar_RegisterFloat("winvoice_mic_scaler", 1.0f, 0.25f, 2.0f,
                                     DVAR_ARCHIVE, "Microphone scaler value");

    g_traceVoice = std::getenv("KISAK_AUDIO_TRACE") != nullptr;
    g_encoder = speex_encoder_init(&speex_nb_mode);
    if (!g_encoder)
    {
        Com_PrintWarning(9, "[voice] unable to initialize Speex encoder\n");
        return false;
    }
    speex_bits_init(&g_encodeBits);
    g_encodeBitsInitialized = true;
    int enabled = 1;
    int sampleRate = kVoiceRate;
    g_encoderQuality = CurrentVoiceQuality();
    speex_encoder_ctl(g_encoder, SPEEX_SET_SAMPLING_RATE, &sampleRate);
    speex_encoder_ctl(g_encoder, SPEEX_SET_QUALITY, &g_encoderQuality);
    speex_encoder_ctl(g_encoder, SPEEX_SET_VAD, &enabled);
    speex_encoder_ctl(g_encoder, SPEEX_SET_DTX, &enabled);
    speex_encoder_ctl(g_encoder, SPEEX_GET_FRAME_SIZE, &g_encodeFrameSamples);

    for (TalkerPlayback &talker : g_talkers)
    {
        talker.decoder = speex_decoder_init(&speex_nb_mode);
        if (!talker.decoder)
        {
            Voice_Shutdown();
            Com_PrintWarning(9, "[voice] unable to initialize Speex decoder\n");
            return false;
        }
        speex_bits_init(&talker.bits);
        talker.bitsInitialized = true;
        speex_decoder_ctl(talker.decoder, SPEEX_SET_ENH, &enabled);
        speex_decoder_ctl(talker.decoder, SPEEX_SET_SAMPLING_RATE, &sampleRate);
        ResetPlayback(&talker);
    }
    std::fill(g_talkTimes.begin(), g_talkTimes.end(), 0);
    g_voiceInitialized.store(g_encodeFrameSamples == kExpectedFrameSamples,
                             std::memory_order_release);
    if (!g_voiceInitialized.load(std::memory_order_acquire))
    {
        Com_PrintWarning(9, "[voice] unexpected Speex frame size %d\n", g_encodeFrameSamples);
        Voice_Shutdown();
        return false;
    }
    Com_Printf(9, "[voice] Speex narrowband ready: %d Hz, %d samples/frame, quality %d\n",
               kVoiceRate, g_encodeFrameSamples, g_encoderQuality);
    if (std::getenv("KISAK_VOICE_SELFTEST") && !RunCodecSelfTest())
        Com_PrintWarning(9, "[voice] codec round-trip self-test failed\n");
    return true;
}

void Voice_Shutdown()
{
    if (g_captureDevice)
    {
        SDL_CloseAudioDevice(g_captureDevice);
        g_captureDevice = 0;
    }
    std::lock_guard<std::mutex> held(g_voiceMutex);
    for (TalkerPlayback &talker : g_talkers)
    {
        if (talker.bitsInitialized)
        {
            speex_bits_destroy(&talker.bits);
            talker.bitsInitialized = false;
        }
        if (talker.decoder)
        {
            speex_decoder_destroy(talker.decoder);
            talker.decoder = nullptr;
        }
        ResetPlayback(&talker);
    }
    if (g_encodeBitsInitialized)
    {
        speex_bits_destroy(&g_encodeBits);
        g_encodeBitsInitialized = false;
    }
    if (g_encoder)
    {
        speex_encoder_destroy(g_encoder);
        g_encoder = nullptr;
    }
    g_captureRead = g_captureWrite = g_captureCount = 0;
    g_captureAttempted = false;
    g_recording = false;
    g_voiceInitialized.store(false, std::memory_order_release);
}

bool Voice_SendVoiceData()
{
    if (!sv_voice || !sv_voice->current.enabled || !cl_voice
        || !cl_voice->current.enabled || Dvar_GetInt("rate") < 5000)
    {
        return false;
    }
    return clientUIActives[0].connectionState == CA_ACTIVE
        && ((cl_talking && cl_talking->current.enabled) || IN_IsTalkKeyHeld()
            || cl_voiceCommunication.voicePacketCount > 0);
}

char Voice_StartRecording()
{
    if (!g_voiceInitialized.load(std::memory_order_acquire)
        || (!g_captureDevice && !OpenCaptureDevice()))
        return 0;
    if (!g_recording)
    {
        {
            std::lock_guard<std::mutex> held(g_voiceMutex);
            g_captureRead = g_captureWrite = g_captureCount = 0;
        }
        SDL_PauseAudioDevice(g_captureDevice, 0);
        g_recording = true;
    }
    return 1;
}

char Voice_StopRecording()
{
    if (!g_recording)
        return 0;
    SDL_PauseAudioDevice(g_captureDevice, 1);
    {
        std::lock_guard<std::mutex> held(g_voiceMutex);
        g_captureRead = g_captureWrite = g_captureCount = 0;
    }
    g_recording = false;
    return 1;
}

int Voice_GetLocalVoiceData()
{
    if (!g_voiceInitialized.load(std::memory_order_acquire))
        return 0;

    const bool talkHeld = IN_IsTalkKeyHeld();
    if (!talkHeld || !Voice_SendVoiceData())
    {
        Voice_StopRecording();
        if (cl_voiceCommunication.voicePacketCount > 0)
            CL_VoiceTransmit(0);
        g_currentVoiceLevel.store(0.0f, std::memory_order_relaxed);
        return 0;
    }
    if (!Voice_StartRecording())
        return 0;

    UpdateEncoderQuality();
    int encodedBytesTotal = 0;
    std::array<int16_t, kExpectedFrameSamples> pcm{};
    for (;;)
    {
        {
            std::lock_guard<std::mutex> held(g_voiceMutex);
            if (g_captureCount < static_cast<size_t>(g_encodeFrameSamples))
                break;
            for (int index = 0; index < g_encodeFrameSamples; ++index)
            {
                pcm[static_cast<size_t>(index)] = g_captureSamples[g_captureRead];
                g_captureRead = (g_captureRead + 1) % kCaptureCapacity;
                --g_captureCount;
            }
        }

        const float scaler = g_micScaler
            ? std::clamp(g_micScaler->current.value, 0.5f, 1.5f) : 1.0f;
        double absoluteSum = 0.0;
        for (int16_t &sample : pcm)
        {
            const int scaled = static_cast<int>(std::lround(static_cast<float>(sample) * scaler));
            sample = static_cast<int16_t>(std::clamp(scaled, -32768, 32767));
            absoluteSum += std::abs(static_cast<int>(sample));
        }
        g_currentVoiceLevel.store(static_cast<float>(
            absoluteSum / (32767.0 * static_cast<double>(g_encodeFrameSamples))),
            std::memory_order_relaxed);

        std::array<char, 256> encoded{};
        speex_bits_reset(&g_encodeBits);
        if (speex_encode_int(g_encoder, pcm.data(), &g_encodeBits) < 0)
            continue;
        const int bytes = speex_bits_write(&g_encodeBits, encoded.data(),
                                           static_cast<int>(encoded.size()));
        if (bytes <= 0 || bytes > static_cast<int>(encoded.size()))
            continue;
        if (cl_voiceCommunication.voicePacketCount >= 10)
            CL_VoiceTransmit(0);
        if (cl_voiceCommunication.voicePacketCount >= 10)
            break;
        ClientVoicePacket_t &packet =
            cl_voiceCommunication.voicePackets[cl_voiceCommunication.voicePacketCount++];
        std::memcpy(packet.data, encoded.data(), static_cast<size_t>(bytes));
        packet.dataSize = bytes;
        encodedBytesTotal += bytes;
        if (g_traceVoice && g_reportedTransmitPackets++ < 16)
            Com_Printf(9, "[voice:tx] %d-byte Speex frame queued (%d pending)\n",
                       bytes, cl_voiceCommunication.voicePacketCount);
        CL_VoiceTransmit(0);
    }
    return encodedBytesTotal;
}

void Voice_IncomingVoiceData(const uint8_t talkerIndex, uint8_t *data,
                             const int packetDataSize)
{
    if (!g_voiceInitialized.load(std::memory_order_acquire)
        || talkerIndex >= kTalkerCount || !data
        || packetDataSize <= 0 || packetDataSize > 256)
    {
        return;
    }

    std::array<int16_t, kExpectedFrameSamples> decoded{};
    std::lock_guard<std::mutex> held(g_voiceMutex);
    TalkerPlayback &talker = g_talkers[talkerIndex];
    g_talkTimes[talkerIndex] = Sys_Milliseconds();
    speex_bits_read_from(&talker.bits, reinterpret_cast<char *>(data), packetDataSize);
    if (speex_decode_int(talker.decoder, &talker.bits, decoded.data()) != 0)
    {
        if (g_traceVoice)
            Com_PrintWarning(9, "[voice:rx] invalid Speex frame from client %u (%d bytes)\n",
                             static_cast<unsigned int>(talkerIndex), packetDataSize);
        return;
    }
    QueueDecodedSamples(&talker, decoded.data(), decoded.size());
    if (g_traceVoice && g_reportedReceivePackets++ < 16)
        Com_Printf(9, "[voice:rx] client=%u bytes=%d buffered=%zu samples\n",
                   static_cast<unsigned int>(talkerIndex), packetDataSize, talker.count);
}

bool Voice_IsClientTalking(const unsigned int clientNum)
{
    if (clientNum >= kTalkerCount)
        return false;
    std::lock_guard<std::mutex> held(g_voiceMutex);
    return Sys_Milliseconds() - g_talkTimes[clientNum] < 300;
}

double Voice_GetVoiceLevel()
{
    g_levelHistory[g_levelHistoryCursor++ % g_levelHistory.size()] =
        g_currentVoiceLevel.load(std::memory_order_relaxed);
    double sum = 0.0;
    for (const float level : g_levelHistory)
        sum += level;
    return sum / static_cast<double>(g_levelHistory.size());
}

void Voice_Playback()
{
    // Output is callback-driven. Keeping this entry point lets the unmodified
    // client frame loop retain its original scheduling and talking indicators.
}

void PosixVoice_Mix(float *stereoFrames, const int frameCount, const int outputRate)
{
    if (!g_voiceInitialized.load(std::memory_order_acquire)
        || !stereoFrames || frameCount <= 0 || outputRate <= 0)
        return;

    std::lock_guard<std::mutex> held(g_voiceMutex);
    for (TalkerPlayback &talker : g_talkers)
        MixTalker(&talker, stereoFrames, frameCount, outputRate);
}
