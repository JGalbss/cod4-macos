#include "dl_main.h"
#include "qcommon.h"

#include <universal/com_files.h>
#include <ui_mp/ui_mp.h>

#include <curl/curl.h>

#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <string>

namespace
{
struct DownloadState
{
    CURLM *multi = nullptr;
    CURL *easy = nullptr;
    FILE *file = nullptr;
    std::string localName;
    std::string displayName;
    char error[CURL_ERROR_SIZE]{};
    bool running = false;
    bool cancelRequested = false;
};

DownloadState download;

std::string HideUrlCredentials(const char *url)
{
    std::string result = url ? url : "";
    const size_t schemeEnd = result.find("://");
    if (schemeEnd == std::string::npos)
        return result;

    const size_t authorityStart = schemeEnd + 3;
    const size_t authorityEnd = result.find_first_of("/?#", authorityStart);
    const size_t at = result.find('@', authorityStart);
    if (at != std::string::npos && (authorityEnd == std::string::npos || at < authorityEnd))
        result.replace(authorityStart, at - authorityStart, "*:*");
    return result;
}

size_t WriteDownloadData(char *data, size_t size, size_t count, void *userData)
{
    FILE *file = static_cast<FILE *>(userData);
    const size_t bytes = size * count;
    const size_t written = std::fwrite(data, 1, bytes, file);
    legacyHacks.cl_downloadCount += static_cast<int>(written);
    return written;
}

int DownloadProgress(void *, curl_off_t, curl_off_t, curl_off_t, curl_off_t)
{
    return download.cancelRequested ? 1 : 0;
}

void CloseDownload(bool removePartial)
{
    if (download.easy && download.multi)
        curl_multi_remove_handle(download.multi, download.easy);
    if (download.easy)
        curl_easy_cleanup(download.easy);
    if (download.multi)
        curl_multi_cleanup(download.multi);
    if (download.file)
        std::fclose(download.file);
    if (removePartial && !download.localName.empty())
        std::remove(download.localName.c_str());

    download.easy = nullptr;
    download.multi = nullptr;
    download.file = nullptr;
    download.localName.clear();
    download.displayName.clear();
    download.error[0] = '\0';
    download.running = false;
    download.cancelRequested = false;
}
} // namespace

int dl_initialized;
bool dl_isMotd;

int __cdecl DL_VPrintf(const char *fmt, char *argptr)
{
    char msg[1028];
#if defined(_WIN32) || defined(__APPLE__)
    _vsnprintf(msg, 0x400u, fmt, (va_list)argptr);
#else
    (void)argptr;
    std::strncpy(msg, fmt ? fmt : "", sizeof(msg) - 1);
    msg[sizeof(msg) - 1] = '\0';
#endif
    Com_Printf(0, "%s", msg);
    return static_cast<int>(std::strlen(msg));
}

void __cdecl DL_InitDownload()
{
    if (dl_initialized)
        return;

    const CURLcode result = curl_global_init(CURL_GLOBAL_DEFAULT);
    if (result != CURLE_OK)
    {
        Com_PrintWarning(14, "Native download subsystem initialization failed: %s\n",
            curl_easy_strerror(result));
        return;
    }

    dl_initialized = 1;
    Com_Printf(14, "Native HTTP/HTTPS download subsystem initialized\n");
}

void __cdecl DL_CancelDownload()
{
    if (!download.running && !download.easy && !download.multi && !download.file)
        return;

    download.cancelRequested = true;
    CloseDownload(true);
}

int __cdecl DL_BeginDownload(char *localName, char *remoteName)
{
    if (!localName || !*localName || !remoteName || !*remoteName)
    {
        Com_PrintWarning(14, "Empty download URL or local filename\n");
        return 0;
    }

    if (download.running)
        DL_CancelDownload();

    DL_InitDownload();
    if (!dl_initialized)
        return 0;

    // The server chooses the redirect URL. Restrict it to protocols that are
    // actual CoD download transports; file:// and other libcurl handlers must
    // never be allowed to read arbitrary files from the player's machine.
    const bool supportedProtocol =
        !I_strnicmp(remoteName, "https://", 8)
        || !I_strnicmp(remoteName, "http://", 7)
        || !I_strnicmp(remoteName, "ftp://", 6);
    if (!supportedProtocol)
    {
        Com_PrintWarning(14, "Refusing unsupported download URL protocol\n");
        return 0;
    }

    if (FS_CreatePath(localName))
    {
        Com_PrintWarning(14, "Could not create download path for %s\n", localName);
        return 0;
    }

    download.file = std::fopen(localName, "wb");
    if (!download.file)
    {
        Com_PrintWarning(14, "Could not open download destination %s\n", localName);
        return 0;
    }

    download.easy = curl_easy_init();
    download.multi = curl_multi_init();
    if (!download.easy || !download.multi)
    {
        Com_PrintWarning(14, "Could not allocate native download request\n");
        CloseDownload(true);
        return 0;
    }

    download.localName = localName;
    download.displayName = HideUrlCredentials(remoteName);
    download.error[0] = '\0';
    download.cancelRequested = false;
    legacyHacks.cl_downloadCount = 0;
    I_strncpyz(legacyHacks.cl_downloadName, download.displayName.c_str(),
        sizeof(legacyHacks.cl_downloadName));

    curl_easy_setopt(download.easy, CURLOPT_URL, remoteName);
    curl_easy_setopt(download.easy, CURLOPT_WRITEFUNCTION, WriteDownloadData);
    curl_easy_setopt(download.easy, CURLOPT_WRITEDATA, download.file);
    curl_easy_setopt(download.easy, CURLOPT_XFERINFOFUNCTION, DownloadProgress);
    curl_easy_setopt(download.easy, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(download.easy, CURLOPT_ERRORBUFFER, download.error);
    curl_easy_setopt(download.easy, CURLOPT_USERAGENT, "KisakCOD-native-macOS/1.0");
    curl_easy_setopt(download.easy, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(download.easy, CURLOPT_MAXREDIRS, 8L);
    curl_easy_setopt(download.easy, CURLOPT_CONNECTTIMEOUT, 30L);
    curl_easy_setopt(download.easy, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(download.easy, CURLOPT_LOW_SPEED_TIME, 60L);
    curl_easy_setopt(download.easy, CURLOPT_FAILONERROR, 1L);
    curl_easy_setopt(download.easy, CURLOPT_PROTOCOLS_STR, "http,https,ftp");
    curl_easy_setopt(download.easy, CURLOPT_REDIR_PROTOCOLS_STR, "http,https,ftp");

    const CURLMcode addResult = curl_multi_add_handle(download.multi, download.easy);
    if (addResult != CURLM_OK)
    {
        Com_PrintWarning(14, "Could not queue native download: %s\n",
            curl_multi_strerror(addResult));
        CloseDownload(true);
        return 0;
    }

    download.running = true;
    Com_Printf(14, "Downloading %s\n", download.displayName.c_str());
    return 1;
}

int __cdecl DL_DownloadLoop()
{
    if (!download.running)
        return DL_FAILED;

    int activeRequests = 0;
    const CURLMcode performResult = curl_multi_perform(download.multi, &activeRequests);
    if (performResult != CURLM_OK)
    {
        Com_PrintWarning(14, "Download failed while transferring %s: %s\n",
            download.displayName.c_str(), curl_multi_strerror(performResult));
        CloseDownload(true);
        return DL_FAILED;
    }

    int pendingMessages = 0;
    while (CURLMsg *message = curl_multi_info_read(download.multi, &pendingMessages))
    {
        if (message->msg != CURLMSG_DONE || message->easy_handle != download.easy)
            continue;

        const CURLcode result = message->data.result;
        const std::string completedName = download.displayName;
        const std::string error = download.error;
        if (download.file)
        {
            std::fflush(download.file);
            std::fclose(download.file);
            download.file = nullptr;
        }

        if (result == CURLE_OK)
        {
            CloseDownload(false);
            Com_Printf(14, "Download complete: %s (%d bytes)\n",
                completedName.c_str(), legacyHacks.cl_downloadCount);
            return DL_DONE;
        }

        Com_PrintWarning(14, "Download failed for %s: %s\n", completedName.c_str(),
            error.empty() ? curl_easy_strerror(result) : error.c_str());
        CloseDownload(true);
        return DL_FAILED;
    }

    // A completion message is normally present as soon as activeRequests is
    // zero. Treat its absence as a transfer failure instead of leaving the UI
    // stuck forever on a download that libcurl no longer owns.
    if (!activeRequests)
    {
        Com_PrintWarning(14, "Download ended without a completion result\n");
        CloseDownload(true);
        return DL_FAILED;
    }
    return DL_CONTINUE;
}

bool __cdecl DL_InProgress()
{
    return download.running;
}

bool __cdecl DL_DLIsMotd()
{
    return dl_isMotd;
}
