#ifndef KISAK_MP
#error This file is multiplayer-only
#endif

#include "cod4x_client.h"
#include "cod4x_reliable.h"

#include <client_mp/client_mp.h>
#include <qcommon/cmd.h>
#include <qcommon/qcommon.h>
#include <universal/com_files.h>
#include <win32/win_storage.h>

#include <tomcrypt.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <string>
#include <unordered_map>
#include <vector>

#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

namespace
{
constexpr const char *kDefaultMasterServers =
    "cod4master.cod4x.ovh;cod4master.ax-servers.hu";
constexpr const char *kMasterResponse = "getserversResponse";
constexpr uint16_t kMasterPort = 20810;
constexpr size_t kMaxMasterResponse = 1024 * 1024;

const dvar_t *cod4xEnabled;
const dvar_t *cod4xMasterServers;
const dvar_t *cod4xProtocol;
const dvar_t *cod4xVersion;

bool extendedProtocol;
bool passwordFileApplied;
int serverConfigDataSequence;
int connectionProtocol = 1;
std::unordered_map<uint64_t, int> advertisedServerProtocols;

constexpr int kDownloadNameSize = 64;
constexpr int kDownloadChecksumCount = 256;
constexpr int kDownloadChecksumWireSize =
    kDownloadNameSize + sizeof(int32_t) * (2 + kDownloadChecksumCount);
constexpr int kDownloadRequestSize = 2 * 1024 * 1024;
constexpr int kMaxDownloadSize = kDownloadChecksumCount * kDownloadRequestSize;
constexpr int kMaxDownloadBlockSize = 0xffff;
constexpr int kDownloadClientCommand = 5;
static_assert(kDownloadChecksumWireSize == 1096);

enum DownloadServerCommand
{
    DLSUBCMD_SERVERDL = 0,
    DLSUBCMD_FILEINIT = 1,
    DLSUBCMD_WWWRD = 2,
    DLSUBCMD_FAIL = 3,
};

enum DownloadClientCommand
{
    CLC_BEGINDOWNLOAD = 0,
    CLC_DONEDOWNLOAD = 1,
    CLC_STOPDOWNLOAD = 2,
    CLC_REQUESTDLBLOCKS = 3,
    CLC_WWWDLFAIL = 4,
};

struct DownloadState
{
    bool initialized;
    int requestedEnd;
    uint32_t expectedChecksum;
    uint32_t checksum;
    char requestedName[kDownloadNameSize];
};

DownloadState downloadState;

// This is the same anonymous fallback used by the public CoD4x client when
// its legacy CD-key authorization path cannot supply a GUID.  A persistent
// installation-specific identity can replace it later without changing the
// network protocol.
constexpr const char *kAnonymousGuid = "01234567890abcdef01234567890abcdef";

char installationGuid[33];
bool installationGuidInitialized;

uint64_t ServerAddressKey(const netadr_t &address)
{
    uint64_t key = static_cast<uint64_t>(static_cast<unsigned int>(address.type)) << 48;
    key |= static_cast<uint64_t>(address.port) << 32;
    key |= static_cast<uint64_t>(address.ip[0]);
    key |= static_cast<uint64_t>(address.ip[1]) << 8;
    key |= static_cast<uint64_t>(address.ip[2]) << 16;
    key |= static_cast<uint64_t>(address.ip[3]) << 24;
    return key;
}

bool MessageHasBytes(const msg_t *msg, const int count)
{
    return msg && count >= 0 && msg->readcount >= 0 && msg->readcount <= msg->cursize
        && count <= msg->cursize - msg->readcount;
}

uint32_t ReadLittleU32(const unsigned char *data)
{
    return static_cast<uint32_t>(data[0])
        | (static_cast<uint32_t>(data[1]) << 8)
        | (static_cast<uint32_t>(data[2]) << 16)
        | (static_cast<uint32_t>(data[3]) << 24);
}

bool ReadCString(msg_t *msg, char *output, const size_t outputSize)
{
    if (!output || outputSize < 2)
        return false;

    for (size_t i = 0; i + 1 < outputSize; ++i)
    {
        if (!MessageHasBytes(msg, 1))
            return false;
        const int character = MSG_ReadByte(msg);
        if (!character)
        {
            output[i] = '\0';
            return true;
        }
        output[i] = static_cast<char>(character);
    }
    output[outputSize - 1] = '\0';
    return false;
}

bool HasDownloadExtension(const char *path)
{
    const char *extension = std::strrchr(path, '.');
    return extension && (!I_stricmp(extension, ".iwd") || !I_stricmp(extension, ".ff"));
}

bool IsSafeDownloadPath(const char *path)
{
    if (!path || !*path || std::strlen(path) >= kDownloadNameSize
        || path[0] == '/' || path[0] == '\\' || !HasDownloadExtension(path))
    {
        return false;
    }

    const char *component = path;
    for (const unsigned char *cursor = reinterpret_cast<const unsigned char *>(path); ; ++cursor)
    {
        const unsigned char character = *cursor;
        if (character
            && (character == '\\' || character == ':' || character < 0x20 || character == 0x7f))
            return false;
        const bool asciiAlphaNumeric = (character >= '0' && character <= '9')
            || (character >= 'A' && character <= 'Z')
            || (character >= 'a' && character <= 'z');
        if (character && character != '/' && !asciiAlphaNumeric
            && character != '_' && character != '-' && character != '.')
        {
            return false;
        }
        if (!character || character == '/')
        {
            const size_t componentLength = reinterpret_cast<const char *>(cursor) - component;
            if (!componentLength
                || (componentLength == 1 && component[0] == '.')
                || (componentLength == 2 && component[0] == '.' && component[1] == '.'))
            {
                return false;
            }
            if (!character)
                break;
            component = reinterpret_cast<const char *>(cursor) + 1;
        }
    }
    return true;
}

uint32_t UpdateCrc32(uint32_t previous, const unsigned char *data, size_t length)
{
    uint32_t crc = ~previous;
    while (length--)
    {
        crc ^= *data++;
        for (int bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

bool SendDownloadCommand(
    const DownloadClientCommand command,
    const char *name = nullptr,
    const int offset = 0,
    const int size = 0)
{
    std::array<unsigned char, 128> commandData{};
    msg_t commandMessage{};
    MSG_Init(&commandMessage, commandData.data(), static_cast<int>(commandData.size()));
    MSG_WriteLong(&commandMessage, 0);
    MSG_WriteLong(&commandMessage, kDownloadClientCommand);
    MSG_WriteByte(&commandMessage, command);
    if (command == CLC_BEGINDOWNLOAD)
        MSG_WriteString(&commandMessage, name);
    else if (command == CLC_REQUESTDLBLOCKS)
    {
        MSG_WriteLong(&commandMessage, offset);
        MSG_WriteLong(&commandMessage, size);
    }
    return !commandMessage.overflowed && Cod4x_ReliableSendMessage(&commandMessage);
}

void CloseDownloadFile()
{
    if (cls.download)
    {
        FS_FCloseFile(cls.download);
        cls.download = 0;
    }
}

void StopMalformedDownload(const char *reason)
{
    CloseDownloadFile();
    downloadState = {};
    SendDownloadCommand(CLC_STOPDOWNLOAD);
    Com_Error(ERR_DROP, "CoD4x: malformed download: %s", reason);
}

bool RequestNextDownloadRange()
{
    const int remaining = cls.downloadSize - cls.downloadCount;
    if (remaining <= 0)
        return false;
    const int requestSize = std::min(remaining, kDownloadRequestSize);
    downloadState.requestedEnd = cls.downloadCount + requestSize;
    return SendDownloadCommand(
        CLC_REQUESTDLBLOCKS, nullptr, cls.downloadCount, requestSize);
}

void FinishDownload()
{
    CloseDownloadFile();
    if (downloadState.checksum != downloadState.expectedChecksum)
    {
        const uint32_t actualChecksum = downloadState.checksum;
        const uint32_t expectedChecksum = downloadState.expectedChecksum;
        downloadState = {};
        SendDownloadCommand(CLC_STOPDOWNLOAD);
        Com_Error(ERR_DROP,
            "CoD4x: checksum mismatch for %s (expected %08x, got %08x)",
            cls.downloadName, expectedChecksum, actualChecksum);
        return;
    }

    FS_SV_Rename(cls.downloadTempName, cls.downloadName);
    if (!FS_SV_FileExists(cls.downloadName))
    {
        downloadState = {};
        SendDownloadCommand(CLC_STOPDOWNLOAD);
        Com_Error(ERR_DROP, "CoD4x: could not install downloaded file %s", cls.downloadName);
        return;
    }

    Com_Printf(14, "CoD4x: downloaded %s (%d bytes, checksum %08x)\n",
        cls.downloadName, cls.downloadCount, downloadState.checksum);
    downloadState = {};
    cls.downloadName[0] = 0;
    cls.downloadTempName[0] = 0;
    legacyHacks.cl_downloadName[0] = 0;
    CL_NextDownload(NS_CLIENT1);
}

void ParseDownloadFileInit(msg_t *msg)
{
    if (!MessageHasBytes(msg, 4 + 4 + kDownloadChecksumWireSize))
    {
        StopMalformedDownload("truncated file-init message");
        return;
    }

    const int fileSize = MSG_ReadLong(msg);
    MSG_ReadLong(msg); // reserved checksum-info field in protocol 21
    if (fileSize <= 0 || fileSize > kMaxDownloadSize)
    {
        StopMalformedDownload("invalid file size");
        return;
    }
    if (msg->cursize - msg->readcount != kDownloadChecksumWireSize)
    {
        StopMalformedDownload("invalid checksum-info size");
        return;
    }

    std::array<unsigned char, kDownloadChecksumWireSize> checksumInfo{};
    MSG_ReadData(msg, checksumInfo.data(), static_cast<int>(checksumInfo.size()));
    const char *serverName = reinterpret_cast<const char *>(checksumInfo.data());
    if (!std::memchr(serverName, '\0', kDownloadNameSize) || !IsSafeDownloadPath(serverName))
    {
        StopMalformedDownload("invalid server file name");
        return;
    }
    const int checksumFileSize = static_cast<int>(ReadLittleU32(
        checksumInfo.data() + kDownloadNameSize));
    const uint32_t expectedChecksum = ReadLittleU32(
        checksumInfo.data() + kDownloadNameSize + sizeof(int32_t) * (1 + kDownloadChecksumCount));
    if (checksumFileSize != fileSize
        || std::strcmp(serverName, downloadState.requestedName)
        || !downloadState.requestedName[0]
        || !cls.downloadTempName[0])
    {
        StopMalformedDownload("file-init does not match the requested file");
        return;
    }
    if (downloadState.initialized || cls.download)
    {
        StopMalformedDownload("file-init while another download is active");
        return;
    }

    cls.downloadSize = fileSize;
    cls.downloadCount = 0;
    legacyHacks.cl_downloadSize = fileSize;
    legacyHacks.cl_downloadCount = 0;
    downloadState.initialized = true;
    downloadState.expectedChecksum = expectedChecksum;
    downloadState.checksum = 0;
    cls.download = FS_SV_FOpenFileWrite(cls.downloadTempName);
    if (!cls.download)
    {
        downloadState = {};
        SendDownloadCommand(CLC_STOPDOWNLOAD);
        Com_Error(ERR_DROP, "CoD4x: could not create download file %s", cls.downloadTempName);
        return;
    }
    if (!RequestNextDownloadRange())
    {
        StopMalformedDownload("could not queue the first download range");
        return;
    }
}

void ParseDownloadServerBlock(msg_t *msg)
{
    if (!downloadState.initialized || !cls.download)
    {
        StopMalformedDownload("data block without an active download");
        return;
    }
    if (!MessageHasBytes(msg, 6))
    {
        StopMalformedDownload("truncated data-block header");
        return;
    }

    const int fileOffset = MSG_ReadLong(msg);
    const int blockSize = static_cast<uint16_t>(MSG_ReadShort(msg));
    if (fileOffset != cls.downloadCount)
    {
        StopMalformedDownload("unexpected data-block offset");
        return;
    }
    if (msg->cursize - msg->readcount != blockSize
        || blockSize > cls.downloadSize - cls.downloadCount
        || blockSize > downloadState.requestedEnd - cls.downloadCount)
    {
        StopMalformedDownload("invalid data-block size");
        return;
    }

    if (!blockSize)
    {
        if (cls.downloadCount != downloadState.requestedEnd)
        {
            StopMalformedDownload("range ended before all requested bytes arrived");
            return;
        }
        if (cls.downloadCount == cls.downloadSize)
        {
            FinishDownload();
            return;
        }
        if (!RequestNextDownloadRange())
        {
            StopMalformedDownload("could not queue the next download range");
            return;
        }
        return;
    }

    std::array<unsigned char, kMaxDownloadBlockSize> block{};
    MSG_ReadData(msg, block.data(), blockSize);
    if (FS_Write(reinterpret_cast<const char *>(block.data()), blockSize, cls.download)
        != static_cast<unsigned int>(blockSize))
    {
        StopMalformedDownload("short file write");
        return;
    }
    downloadState.checksum = UpdateCrc32(downloadState.checksum, block.data(), blockSize);
    cls.downloadCount += blockSize;
    legacyHacks.cl_downloadCount = cls.downloadCount;
}

void ParseDownloadRedirect(msg_t *msg)
{
    char url[1024];
    if (!ReadCString(msg, url, sizeof(url)) || !MessageHasBytes(msg, 8))
    {
        StopMalformedDownload("truncated redirect message");
        return;
    }
    const int fileSize = MSG_ReadLong(msg);
    const int disconnect = MSG_ReadLong(msg);
    if (msg->readcount != msg->cursize || !url[0]
        || fileSize <= 0 || fileSize > kMaxDownloadSize
        || !downloadState.initialized || fileSize != cls.downloadSize
        || (disconnect != 0 && disconnect != 1))
    {
        StopMalformedDownload("invalid redirect message");
        return;
    }

    // The stock asynchronous HTTP path reports completion with textual IW3
    // commands.  Ask a protocol-21 server to use its direct, checksummed path
    // instead until that path has binary completion reporting end to end.
    CloseDownloadFile();
    downloadState.initialized = false;
    downloadState.requestedEnd = 0;
    cls.downloadCount = 0;
    legacyHacks.cl_downloadCount = 0;
    if (!SendDownloadCommand(CLC_WWWDLFAIL))
    {
        downloadState = {};
        Com_Error(ERR_DROP, "CoD4x: could not decline HTTP download redirect");
        return;
    }
    Com_Printf(14, "CoD4x: declined HTTP redirect; requesting checksummed server download\n");
}

void ParseDownloadFailure(msg_t *msg)
{
    char error[1024];
    if (!ReadCString(msg, error, sizeof(error)) || msg->readcount != msg->cursize)
    {
        StopMalformedDownload("invalid failure message");
        return;
    }
    CloseDownloadFile();
    downloadState = {};
    Com_Error(ERR_DROP, "%s", error[0] ? error : "Server refused the download");
}

void ParseDownloadMessage(msg_t *msg)
{
    if (!MessageHasBytes(msg, 1))
    {
        StopMalformedDownload("missing subcommand");
        return;
    }
    switch (MSG_ReadByte(msg))
    {
    case DLSUBCMD_FILEINIT:
        ParseDownloadFileInit(msg);
        break;
    case DLSUBCMD_SERVERDL:
        ParseDownloadServerBlock(msg);
        break;
    case DLSUBCMD_WWWRD:
        ParseDownloadRedirect(msg);
        break;
    case DLSUBCMD_FAIL:
        ParseDownloadFailure(msg);
        break;
    default:
        StopMalformedDownload("unknown subcommand");
        break;
    }
}

uint32_t RotateLeft(const uint32_t value, const unsigned int amount)
{
    return (value << amount) | (value >> (32 - amount));
}

// CoD4's GUID is MD5 over the first 16 normalized CD-key characters, but it
// uses a game-specific initial state rather than RFC 1321's standard IV.
// Keeping the derivation here gives the native client the same persistent
// identity as the official CoD4x client without exposing the key itself.
void BuildCodGuid(const unsigned char input[16], char output[33])
{
    static constexpr uint32_t shifts[64] = {
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21};
    static constexpr uint32_t constants[64] = {
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391};

    unsigned char block[64]{};
    memcpy(block, input, 16);
    block[16] = 0x80;
    block[56] = 0x80; // 16 bytes == 128 bits, little endian

    uint32_t words[16];
    for (int i = 0; i < 16; ++i)
    {
        words[i] = static_cast<uint32_t>(block[4 * i])
            | (static_cast<uint32_t>(block[4 * i + 1]) << 8)
            | (static_cast<uint32_t>(block[4 * i + 2]) << 16)
            | (static_cast<uint32_t>(block[4 * i + 3]) << 24);
    }

    constexpr uint32_t initial[4] = {0x6f1cd602, 0x226c74be, 0xb31c088d, 0x555a9639};
    uint32_t a = initial[0];
    uint32_t b = initial[1];
    uint32_t c = initial[2];
    uint32_t d = initial[3];
    for (int i = 0; i < 64; ++i)
    {
        uint32_t function;
        int wordIndex;
        if (i < 16)
        {
            function = (b & c) | (~b & d);
            wordIndex = i;
        }
        else if (i < 32)
        {
            function = (d & b) | (~d & c);
            wordIndex = (5 * i + 1) & 15;
        }
        else if (i < 48)
        {
            function = b ^ c ^ d;
            wordIndex = (3 * i + 5) & 15;
        }
        else
        {
            function = c ^ (b | ~d);
            wordIndex = (7 * i) & 15;
        }
        const uint32_t oldD = d;
        d = c;
        c = b;
        b += RotateLeft(a + function + constants[i] + words[wordIndex], shifts[i]);
        a = oldD;
    }

    const uint32_t digestWords[4] = {
        initial[0] + a, initial[1] + b, initial[2] + c, initial[3] + d};
    unsigned char digest[16];
    for (int i = 0; i < 4; ++i)
    {
        digest[4 * i] = static_cast<unsigned char>(digestWords[i]);
        digest[4 * i + 1] = static_cast<unsigned char>(digestWords[i] >> 8);
        digest[4 * i + 2] = static_cast<unsigned char>(digestWords[i] >> 16);
        digest[4 * i + 3] = static_cast<unsigned char>(digestWords[i] >> 24);
    }
    for (int i = 0; i < 16; ++i)
        std::snprintf(output + 2 * i, 3, "%02x", digest[i]);
    output[32] = '\0';
}

bool LoadInstallationGuid(char output[33])
{
    std::string defaultPath;
    const char *path = std::getenv("KISAK_COD4X_CDKEY_FILE");
    if (!path || !*path)
    {
        const char *home = std::getenv("HOME");
        if (!home || !*home)
            return false;
        defaultPath = std::string(home) + "/.cod4-mac/config/cdkey";
        path = defaultPath.c_str();
    }

    FILE *file = std::fopen(path, "rb");
    if (!file)
        return false;
    char rawKey[96]{};
    const size_t bytesRead = std::fread(rawKey, 1, sizeof(rawKey) - 1, file);
    std::fclose(file);

    unsigned char normalized[16];
    size_t count = 0;
    for (size_t i = 0; i < bytesRead && count < sizeof(normalized); ++i)
    {
        const unsigned char character = static_cast<unsigned char>(rawKey[i]);
        if (std::isalnum(character))
            normalized[count++] = static_cast<unsigned char>(std::tolower(character));
    }
    memset(rawKey, 0, sizeof(rawKey));
    if (count != sizeof(normalized))
        return false;
    BuildCodGuid(normalized, output);
    memset(normalized, 0, sizeof(normalized));
    return true;
}

void SendStatsResponse()
{
    if (!LiveStorage_DoWeHaveStats())
    {
        // This mirrors CoD4x: no packet is preferable to acknowledging with
        // zeroed stats, which makes stock game scripts reject every class.
        Com_PrintWarning(14, "CoD4x: stats requested before local stats were ready\n");
        return;
    }

    const playerStatNetworkData *stats = LiveStorage_GetStatBuffer();
    std::array<unsigned char, 4 + 4 + 1 + 4 + 8192> responseData{};
    std::array<unsigned char, 8192> encryptedStats{};
    alignas(uint32_t) unsigned char key[16];
    const uint32_t challenge = static_cast<uint32_t>(clientConnections[0].challenge);
    for (int i = 0; i < 4; ++i)
        memcpy(key + 4 * i, &challenge, sizeof(challenge));

    symmetric_key keySchedule;
    if (rijndael_setup(key, sizeof(key), 0, &keySchedule) != CRYPT_OK)
    {
        Com_PrintWarning(14, "CoD4x: could not initialize stats encryption\n");
        return;
    }

    unsigned char previousCiphertext[16] = {
        0x4f, 0x11, 0x62, 0xeb, 0x44, 0x61, 0x99, 0x66,
        0xa4, 0xcf, 0x41, 0x73, 0x99, 0x12, 0x55, 0xb9};
    for (int block = 0; block < 8192 / 16; ++block)
    {
        unsigned char plaintext[16];
        memcpy(plaintext, stats->playerStats + 16 * block, sizeof(plaintext));
        for (int byteIndex = 0; byteIndex < 16; ++byteIndex)
            plaintext[byteIndex] ^= previousCiphertext[byteIndex];
        rijndael_ecb_encrypt(plaintext, previousCiphertext, &keySchedule);
        memcpy(encryptedStats.data() + 16 * block, previousCiphertext, sizeof(previousCiphertext));
    }
    rijndael_done(&keySchedule);
    memset(key, 0, sizeof(key));

    msg_t response{};
    MSG_Init(&response, responseData.data(), static_cast<int>(responseData.size()));
    MSG_WriteLong(&response, 0); // logical size is filled by the transport
    MSG_WriteLong(&response, 9); // clc_statscommands
    MSG_WriteByte(&response, 2); // challenge-keyed AES-CBC stats
    MSG_WriteLong(&response, 8192);
    MSG_WriteData(&response, encryptedStats.data(), static_cast<int>(encryptedStats.size()));
    if (Cod4x_ReliableSendMessage(&response))
        Com_Printf(14, "CoD4x: sent encrypted player stats\n");
    else
        Com_PrintWarning(14, "CoD4x: reliable stats queue is full\n");
}

bool SendAll(const int socketFd, const uint8_t *data, size_t size)
{
    while (size)
    {
        const ssize_t sent = send(socketFd, data, size, 0);
        if (sent > 0)
        {
            data += sent;
            size -= static_cast<size_t>(sent);
            continue;
        }
        if (sent < 0 && errno == EINTR)
            continue;
        return false;
    }
    return true;
}

bool QueryMaster(const std::string &host, const char *keywords, std::vector<uint8_t> &response)
{
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    addrinfo *addresses = nullptr;
    const std::string port = std::to_string(kMasterPort);
    const int resolveResult = getaddrinfo(host.c_str(), port.c_str(), &hints, &addresses);
    if (resolveResult != 0)
    {
        Com_PrintWarning(14, "CoD4x: could not resolve master %s: %s\n", host.c_str(), gai_strerror(resolveResult));
        return false;
    }

    int socketFd = -1;
    for (addrinfo *address = addresses; address; address = address->ai_next)
    {
        socketFd = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (socketFd < 0)
            continue;

        timeval timeout{};
        timeout.tv_sec = 5;
        setsockopt(socketFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(socketFd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        if (connect(socketFd, address->ai_addr, address->ai_addrlen) == 0)
            break;

        close(socketFd);
        socketFd = -1;
    }
    freeaddrinfo(addresses);

    if (socketFd < 0)
    {
        Com_PrintWarning(14, "CoD4x: could not connect to master %s:%u\n", host.c_str(), kMasterPort);
        return false;
    }

    std::string query("\xff\xff\xff\xffgetservers ", 15);
    query += std::to_string(KISAK_COD4X_PROTOCOL_VERSION);
    if (keywords && *keywords)
    {
        query.push_back(' ');
        query += keywords;
    }
    query.push_back('\0');

    bool ok = SendAll(socketFd, reinterpret_cast<const uint8_t *>(query.data()), query.size());
    response.clear();
    uint8_t buffer[8192];
    while (ok && response.size() < kMaxMasterResponse)
    {
        const ssize_t received = recv(socketFd, buffer, sizeof(buffer), 0);
        if (received > 0)
        {
            response.insert(response.end(), buffer, buffer + received);
            continue;
        }
        if (received == 0)
            break;
        if (errno == EINTR)
            continue;
        ok = false;
    }
    close(socketFd);
    return ok && !response.empty() && response.size() < kMaxMasterResponse;
}

bool IsDuplicate(const netadr_t &address)
{
    for (int i = 0; i < cls.numglobalservers; ++i)
    {
        if (NET_CompareAdr(cls.globalServers[i].adr, address))
            return true;
    }
    return false;
}

void AddServer(const netadr_t &address)
{
    if (cls.numglobalservers >= static_cast<int>(std::size(cls.globalServers)) || IsDuplicate(address))
        return;

    serverInfo_t &server = cls.globalServers[cls.numglobalservers++];
    std::memset(&server, 0, sizeof(server));
    server.adr = address;
    server.ping = -1;
    server.dirty = 1;
}

bool ParseMasterResponse(const std::vector<uint8_t> &response, int &ipv6OnlyRecords)
{
    ipv6OnlyRecords = 0;
    if (response.size() < 4 + std::strlen(kMasterResponse)
        || std::memcmp(response.data(), "\xff\xff\xff\xff", 4) != 0
        || std::memcmp(response.data() + 4, kMasterResponse, std::strlen(kMasterResponse)) != 0)
    {
        return false;
    }

    const uint8_t *cursor = response.data() + 4 + std::strlen(kMasterResponse);
    const uint8_t *const end = response.data() + response.size();
    while (cursor < end && *cursor != '\\')
        ++cursor;

    cls.numglobalservers = 0;
    std::memset(cls.globalServers, 0, sizeof(cls.globalServers));

    while (cursor < end && *cursor == '\\')
    {
        ++cursor;
        if (end - cursor >= 3 && cursor[0] == 'E' && cursor[1] == 'O'
            && (cursor[2] == 'T' || cursor[2] == 'F'))
        {
            break;
        }

        // CoD4x prefixes every server record with four bytes of master-side
        // metadata, followed by as many as three typed addresses.
        if (end - cursor < 4)
            return false;
        cursor += 4;

        netadr_t firstIpv4{};
        bool haveIpv4 = false;
        bool haveAnyAddress = false;
        for (int addressIndex = 0; addressIndex < 3; ++addressIndex)
        {
            if (cursor >= end)
                return false;
            if (*cursor == '\\')
                break;

            const uint8_t type = *cursor++;
            if (type == 4) // CoD4x NA_IP
            {
                if (end - cursor < 6)
                    return false;
                if (!haveIpv4)
                {
                    firstIpv4.type = NA_IP;
                    std::memcpy(firstIpv4.ip, cursor, sizeof(firstIpv4.ip));
                    std::memcpy(&firstIpv4.port, cursor + 4, sizeof(firstIpv4.port));
                    haveIpv4 = true;
                }
                cursor += 6;
                haveAnyAddress = true;
            }
            else if (type == 5) // CoD4x NA_IP6; stock IW3 has no IPv6 netadr.
            {
                if (end - cursor < 18)
                    return false;
                cursor += 18;
                haveAnyAddress = true;
            }
            else
            {
                return false;
            }
        }

        if (!haveAnyAddress || cursor >= end || *cursor != '\\')
            return false;
        if (haveIpv4)
            AddServer(firstIpv4);
        else
            ++ipv6OnlyRecords;
    }

    CL_SortGlobalServers();
    cls.waitglobalserverresponse = 0;
    cls.pingUpdateSource = 1;
    return true;
}
}

void Cod4x_Init()
{
    if (cod4xEnabled)
        return;

    cod4xEnabled = Dvar_RegisterBool(
        "cod4x_enabled", true, DVAR_ARCHIVE,
        "Use the native CoD4x client compatibility path");
    cod4xMasterServers = Dvar_RegisterString(
        "cod4x_masterservers", kDefaultMasterServers, DVAR_ARCHIVE,
        "Semicolon-separated CoD4x master servers");
    cod4xProtocol = Dvar_RegisterInt(
        "cod4x_protocol", KISAK_COD4X_PROTOCOL_VERSION,
        KISAK_COD4X_PROTOCOL_VERSION, KISAK_COD4X_PROTOCOL_VERSION,
        DVAR_ROM, "CoD4x network protocol family");
    cod4xVersion = Dvar_RegisterString(
        "cod4x_version", KISAK_COD4X_CLIENT_VERSION, DVAR_ROM,
        "CoD4x client compatibility version");

    Com_Printf(14, "CoD4x: native compatibility enabled (protocol %d, client %s)\n",
        cod4xProtocol->current.integer, cod4xVersion->current.string);
}

bool Cod4x_IsEnabled()
{
    return cod4xEnabled && cod4xEnabled->current.enabled;
}

void Cod4x_OnChallengeResponse()
{
    extendedProtocol = Cod4x_IsEnabled()
        && Cmd_Argc() > 4
        && !I_stricmp(Cmd_Argv(4), "xproto");

    if (extendedProtocol)
    {
        connectionProtocol = KISAK_COD4X_PROTOCOL_VERSION;
        Com_Printf(14, "CoD4x: server selected extended protocol %d (xproto %s)\n",
            KISAK_COD4X_PROTOCOL_VERSION,
            Cmd_Argc() > 5 ? Cmd_Argv(5) : "unknown");
    }
    else
    {
        // An ordinary challenge preserves protocol 6 only when the selected
        // browser row advertised it. Native loopback/listen connections use 1.
        if (connectionProtocol != 6)
            connectionProtocol = 1;
        Com_Printf(14, "CoD4x: server selected legacy protocol %d\n", connectionProtocol);
    }
}

bool Cod4x_UseExtendedProtocol()
{
    return extendedProtocol;
}

void Cod4x_RememberServerProtocol(const netadr_t &address, const int protocol)
{
    if (!Cod4x_IsEnabled() || address.type != NA_IP
        || (protocol != 1 && protocol != 6 && protocol != KISAK_COD4X_PROTOCOL_VERSION))
    {
        return;
    }
    // Master responses cap the browser at 20,000 entries. Bound stale address
    // metadata as well; clearing only affects a later fallback to protocol 1.
    if (advertisedServerProtocols.size() >= 20000
        && advertisedServerProtocols.find(ServerAddressKey(address)) == advertisedServerProtocols.end())
    {
        advertisedServerProtocols.clear();
    }
    advertisedServerProtocols[ServerAddressKey(address)] = protocol;
}

void Cod4x_BeginConnection(const netadr_t &address)
{
    extendedProtocol = false;
    connectionProtocol = 1;
    if (!Cod4x_IsEnabled() || NET_IsLocalAddress(address))
        return;

    const auto advertised = advertisedServerProtocols.find(ServerAddressKey(address));
    if (advertised != advertisedServerProtocols.end() && advertised->second == 6)
        connectionProtocol = 6;
    Com_Printf(14, "CoD4x: connecting with browser-advertised protocol %d\n", connectionProtocol);
}

int Cod4x_GetConnectionProtocol()
{
    return extendedProtocol ? KISAK_COD4X_PROTOCOL_VERSION : connectionProtocol;
}

int Cod4x_GetServerConfigDataSequence()
{
    return serverConfigDataSequence;
}

void Cod4x_SetServerConfigDataSequence(const int sequence)
{
    serverConfigDataSequence = sequence;
}

void Cod4x_ExecuteReliableMessage(msg_t *msg)
{
    const int command = MSG_ReadLong(msg);
    Com_Printf(14, "CoD4x: reliable command %d (%d payload bytes)\n",
        command, msg->cursize - msg->readcount);
    switch (command)
    {
    case svc_gamestate:
        // The reliable envelope identifies the message as a gamestate, and
        // the ordinary server-message payload begins with the same byte.
        if (MSG_ReadByte(msg) != svc_gamestate)
        {
            Com_PrintWarning(14, "CoD4x: malformed reliable gamestate\n");
            return;
        }
        Com_Printf(14, "CoD4x: received extended gamestate (%d bytes)\n", msg->cursize - msg->readcount);
        CL_ParseGamestateCod4x(NS_CLIENT1, msg);
        break;
    case svc_download:
        Com_Printf(14, "CoD4x: received extended download (%d bytes)\n",
            msg->cursize - msg->readcount);
        ParseDownloadMessage(msg);
        break;
    case 8: // svc_steamcommands
        Com_DPrintf(14, "CoD4x: ignored Steam reliable command\n");
        break;
    case 9: // svc_statscommands
    {
        const int subcommand = MSG_ReadByte(msg);
        if (subcommand == 0)
            SendStatsResponse();
        break;
    }
    case 10: // svc_configdata
    case 11: // svc_configclient
    case 12: // svc_acdata
        Com_DPrintf(14, "CoD4x: ignored optional reliable command %d (%d bytes)\n",
            command, msg->cursize - msg->readcount);
        break;
    default:
        Com_PrintWarning(14, "CoD4x: unknown reliable command %d\n", command);
        break;
    }
}

void Cod4x_BeginDownload(const char *localName, const char *remoteName)
{
    if (!Cod4x_UseExtendedProtocol())
    {
        Com_Error(ERR_DROP, "CoD4x: protocol-21 download requested without protocol 21");
        return;
    }
    if (!IsSafeDownloadPath(localName) || !IsSafeDownloadPath(remoteName))
    {
        Com_Error(ERR_DROP, "CoD4x: refused unsafe download path");
        return;
    }
    if (cls.download)
    {
        Com_Error(ERR_DROP, "CoD4x: attempted to begin a download while another is active");
        return;
    }

    downloadState = {};
    I_strncpyz(downloadState.requestedName, remoteName, sizeof(downloadState.requestedName));
    if (!SendDownloadCommand(CLC_BEGINDOWNLOAD, remoteName))
    {
        downloadState = {};
        Com_Error(ERR_DROP, "CoD4x: reliable download queue is full");
        return;
    }
    Com_Printf(14, "CoD4x: requested download %s\n", remoteName);
}

void Cod4x_ReportDownloadComplete()
{
    if (!SendDownloadCommand(CLC_DONEDOWNLOAD))
    {
        Com_Error(ERR_DROP, "CoD4x: could not report download completion");
        return;
    }
}

const char *Cod4x_GetGuid()
{
    if (!installationGuidInitialized)
    {
        installationGuidInitialized = true;
        if (LoadInstallationGuid(installationGuid))
            Com_Printf(14, "CoD4x: using persistent installation identity\n");
        else
            I_strncpyz(installationGuid, kAnonymousGuid, sizeof(installationGuid));
    }
    return installationGuid;
}

void Cod4x_ApplyPasswordFile()
{
    if (passwordFileApplied || !Cod4x_IsEnabled())
        return;
    passwordFileApplied = true;

    const char *path = std::getenv("KISAK_COD4X_PASSWORD_FILE");
    if (!path || !*path)
        return;

    FILE *file = std::fopen(path, "rb");
    if (!file)
    {
        Com_PrintWarning(14, "CoD4x: could not read password file\n");
        return;
    }

    char password[256]{};
    const size_t count = std::fread(password, 1, sizeof(password) - 1, file);
    std::fclose(file);
    password[count] = '\0';
    while (*password && (password[std::strlen(password) - 1] == '\n'
        || password[std::strlen(password) - 1] == '\r'))
    {
        password[std::strlen(password) - 1] = '\0';
    }

    if (!*password)
    {
        Com_PrintWarning(14, "CoD4x: password file is empty\n");
        return;
    }

    Dvar_SetStringByName("password", password);
    std::memset(password, 0, sizeof(password));
    Com_Printf(14, "CoD4x: applied join password from protected file\n");
}

bool Cod4x_AcceptsServerProtocol(const int protocol, const int stockProtocol)
{
    return protocol == stockProtocol
        || (Cod4x_IsEnabled()
            && (protocol == KISAK_COD4X_PROTOCOL_VERSION || protocol == 6));
}

bool Cod4x_QueryMasterServers(const char *keywords)
{
    if (!Cod4x_IsEnabled())
        return false;

    const char *masterList = cod4xMasterServers->current.string;
    const char *start = masterList;
    while (start && *start)
    {
        const char *separator = std::strchr(start, ';');
        const size_t length = separator ? static_cast<size_t>(separator - start) : std::strlen(start);
        std::string host(start, length);
        if (!host.empty() && host.front() == '*')
            host.erase(host.begin());

        if (!host.empty())
        {
            Com_Printf(14, "CoD4x: requesting protocol %d servers from %s\n",
                KISAK_COD4X_PROTOCOL_VERSION, host.c_str());
            std::vector<uint8_t> response;
            if (QueryMaster(host, keywords, response))
            {
                int ipv6OnlyRecords = 0;
                if (ParseMasterResponse(response, ipv6OnlyRecords))
                {
                    Com_Printf(14, "CoD4x: discovered %d IPv4 servers%s\n",
                        cls.numglobalservers,
                        ipv6OnlyRecords ? va(" (%d IPv6-only skipped)", ipv6OnlyRecords) : "");
                    return true;
                }
                Com_PrintWarning(14, "CoD4x: malformed response from master %s\n", host.c_str());
            }

            if (!separator)
                break;
        }
        start = separator ? separator + 1 : nullptr;
    }

    Com_PrintWarning(14, "CoD4x: all configured master servers failed; using stock query path\n");
    return false;
}
