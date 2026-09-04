#include "files.h"
#include <universal/assertive.h>
#include <universal/q_shared.h>
#include <universal/com_files.h>
#include "qcommon.h"
#include <database/database.h>
#include "cmd.h"
#include <sound/snd_public.h>
#ifdef KISAK_COD4X
#include <cod4x/cod4x_client.h>
#endif

int fs_numServerReferencedIwds;
char basename[64];
const char *fs_serverReferencedIwdNames[1024];
int fs_serverReferencedIwds[1024];

// KISAKTODO header-ify
extern int fs_fakeChkSum;

char *__cdecl FS_GetMapBaseName(char *mapname)
{
    unsigned int v2; // [esp+0h] [ebp-18h]
    int c; // [esp+10h] [ebp-8h]
    signed int len; // [esp+14h] [ebp-4h]

    iassert( mapname );
    if (!I_strnicmp(mapname, "maps/mp/", 8))
        mapname += 8;
    v2 = strlen(mapname);
    len = v2;
    if (!I_stricmp(&mapname[v2 - 3], "bsp"))
        len = v2 - 7;
    memcpy((unsigned __int8 *)basename, (unsigned __int8 *)mapname, len);
    basename[len] = 0;
    for (c = 0; c < len; ++c)
    {
        if (basename[c] == 37)
            basename[c] = 95;
    }
    return basename;
}

BOOL __cdecl FS_serverPak(const char *pak)
{
    char v2; // [esp+3h] [ebp-55h]
    char *v3; // [esp+8h] [ebp-50h]
    char szFile[68]; // [esp+10h] [ebp-48h] BYREF

    v3 = szFile;
    do
    {
        v2 = *pak;
        *v3++ = *pak++;
    } while (v2);
    I_strlwr(szFile);
    return strstr(szFile, "_svr_") != 0;
}

int __cdecl FS_iwIwd(char *iwd, char *base)
{
    const char *v2; // eax
    const char *v4; // eax
    char v5; // [esp+3h] [ebp-71h]
    char *v6; // [esp+8h] [ebp-6Ch]
    const char *v7; // [esp+Ch] [ebp-68h]
    char v8; // [esp+13h] [ebp-61h]
    char *v9; // [esp+18h] [ebp-5Ch]
    char *v10; // [esp+1Ch] [ebp-58h]
    char *str2; // [esp+20h] [ebp-54h]
    char szFile[68]; // [esp+24h] [ebp-50h] BYREF
    const char *pszLoc; // [esp+6Ch] [ebp-8h]
    int i; // [esp+70h] [ebp-4h]

    for (i = 0; i < 25; ++i)
    {
        v2 = va("%s/iw_%02d", base, i);
        if (!FS_FilenameCompare(iwd, v2))
            return 1;
    }
    pszLoc = strstr(iwd, "localized_");
    if (pszLoc)
    {
        v10 = iwd;
        v9 = szFile;
        do
        {
            v8 = *v10;
            *v9++ = *v10++;
        } while (v8);
        szFile[pszLoc - iwd + 10] = 0;
        v4 = va("%s/localized_", base);
        if (!FS_FilenameCompare(szFile, v4))
        {
            v7 = pszLoc + 10;
            v6 = szFile;
            do
            {
                v5 = *v7;
                *v6++ = *v7++;
            } while (v5);
            I_strlwr(szFile);
            for (i = 0; i < 25; ++i)
            {
                str2 = va("_iw%02d", i);
                if (strstr(szFile, str2))
                    return 1;
            }
        }
    }
    return 0;
}

#ifdef KISAK_COD4X
bool FS_IsSafeUserMapDownloadName(const char *name)
{
    constexpr const char prefix[] = "usermaps/";
    if (!name || I_strnicmp(name, prefix, sizeof(prefix) - 1)
        || !name[sizeof(prefix) - 1]
        || strlen(name) + strlen(".iwd") >= MAX_QPATH)
    {
        return false;
    }

    const char *component = name + sizeof(prefix) - 1;
    for (const unsigned char *cursor = reinterpret_cast<const unsigned char *>(component); ; ++cursor)
    {
        const unsigned char character = *cursor;
        const bool alphaNumeric = (character >= '0' && character <= '9')
            || (character >= 'A' && character <= 'Z')
            || (character >= 'a' && character <= 'z');
        if (character && character != '/' && !alphaNumeric
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
                return true;
            component = reinterpret_cast<const char *>(cursor) + 1;
        }
    }
}
#endif

int __cdecl FS_CompareIwds(char *needediwds, int len, int dlstring)
{
    char *v4; // eax
    const char *v5; // [esp+8h] [ebp-20h]
    const char *string; // [esp+Ch] [ebp-1Ch]
    uintptr_t v7; // [esp+Ch] [ebp-1Ch] - widened from unsigned int to hold 64-bit pointer
    int haveiwd; // [esp+1Ch] [ebp-Ch]
    searchpath_s *j; // [esp+20h] [ebp-8h]
    int i; // [esp+24h] [ebp-4h]

    if (!fs_numServerReferencedIwds)
        return 0;
    *needediwds = 0;
    string = fs_gameDirVar->current.string;
    v5 = string + 1;
    v7 = (uintptr_t)&string[strlen(string) + 1]; // KISAKHACK: 64-bit pointer in uintptr_t
    for (i = 0; i < fs_numServerReferencedIwds; ++i)
    {
        haveiwd = 0;
        if ((const char *)v7 == v5 || !FS_serverPak(fs_serverReferencedIwdNames[i]))
        {
            for (j = fs_searchpaths; j; j = j->next)
            {
                if (j->iwd && j->iwd->checksum == fs_serverReferencedIwds[i])
                {
                    haveiwd = 1;
                    break;
                }
            }
            if (!haveiwd && fs_serverReferencedIwdNames[i] && *fs_serverReferencedIwdNames[i])
            {
#ifdef KISAK_COD4X
                const char *expectedBase = strrchr(fs_serverReferencedIwdNames[i], '/');
                expectedBase = expectedBase ? expectedBase + 1 : fs_serverReferencedIwdNames[i];
                bool printedCandidate = false;
                for (j = fs_searchpaths; j; j = j->next)
                {
                    if (j->iwd && !I_stricmp(j->iwd->iwdBasename, expectedBase))
                    {
                        Com_Printf(10,
                            "CoD4x: IWD checksum mismatch for %s: server %d, local %d (%s)\n",
                            fs_serverReferencedIwdNames[i], fs_serverReferencedIwds[i],
                            j->iwd->checksum, j->iwd->iwdFilename);
                        printedCandidate = true;
                    }
                }
                if (!printedCandidate)
                {
                    Com_Printf(10, "CoD4x: referenced IWD %s (checksum %d) is not mounted\n",
                        fs_serverReferencedIwdNames[i], fs_serverReferencedIwds[i]);
                }
#endif
                const bool gameDirectoryIwd = (const char *)v7 != v5
                    && !I_strnicmp(fs_serverReferencedIwdNames[i], fs_gameDirVar->current.string,
                        (int)(v7 - (uintptr_t)v5));
#ifdef KISAK_COD4X
                const bool userMapIwd = FS_IsSafeUserMapDownloadName(fs_serverReferencedIwdNames[i]);
#else
                const bool userMapIwd = false;
#endif
                if ((!gameDirectoryIwd && !userMapIwd)
                    || FS_iwIwd((char *)fs_serverReferencedIwdNames[i], (char*)"main"))
                {
                    I_strncpyz(needediwds, (char *)fs_serverReferencedIwdNames[i], len);
                    I_strncat(needediwds, len, ".iwd");
                    return 2;
                }
                if (dlstring)
                {
                    I_strncat(needediwds, len, "@");
                    I_strncat(needediwds, len, (char *)fs_serverReferencedIwdNames[i]);
                    I_strncat(needediwds, len, ".iwd");
                    I_strncat(needediwds, len, "@");
                    I_strncat(needediwds, len, (char *)fs_serverReferencedIwdNames[i]);
                    I_strncat(needediwds, len, ".iwd");
                }
                else
                {
                    I_strncat(needediwds, len, (char *)fs_serverReferencedIwdNames[i]);
                    I_strncat(needediwds, len, ".iwd");
                    v4 = va("%s.iwd", fs_serverReferencedIwdNames[i]);
                    if (FS_SV_FileExists(v4))
                        I_strncat(needediwds, len, " (local file exists with wrong checksum)");
                    I_strncat(needediwds, len, "\n");
                }
            }
        }
    }
    if (!*needediwds)
        return 0;
    Com_Printf(10, "Need iwds: %s\n", needediwds);
    return 1;
}

int fs_numServerReferencedFFs;
const char *fs_serverReferencedFFNames[32];
int fs_serverReferencedFFCheckSums[32];
int __cdecl FS_CompareFFs(char *neededFFs, int len, int dlstring)
{
    if (!fs_numServerReferencedFFs)
        return 0;

    *neededFFs = 0;
    const int gameDirLength = strlen(fs_gameDirVar->current.string);
    for (int i = 0; i < fs_numServerReferencedFFs; ++i)
    {
        const char *serverName = fs_serverReferencedFFNames[i];
#ifdef KISAK_COD4X
        // These zones implement the CoD4x runtime itself.  The native port has
        // its own implementation and must not reject a server merely because
        // its bundled runtime revision has a different byte size.
        if (Cod4x_UseExtendedProtocol()
            && (!I_stricmp(serverName, "cod4x_ambfix")
                || !I_stricmp(serverName, "cod4x_patchv2")))
            continue;
#endif

        const char *ffName = serverName;
        int ffDir = 0;
        int fileSize = DB_FileSize(ffName, 0);
        if (!fileSize)
        {
            if (!I_strnicmp(serverName, "usermaps/", 9) && strlen(serverName) > 9)
            {
                ffName = serverName + 9;
                ffDir = 2;
            }
            else if (gameDirLength && !I_strnicmp(serverName, fs_gameDirVar->current.string, gameDirLength)
                && serverName[gameDirLength] == '/' && serverName[gameDirLength + 1])
            {
                ffName = serverName + gameDirLength + 1;
                ffDir = 1;
            }
            fileSize = DB_FileSize(ffName, ffDir);
        }

        if (fileSize != fs_serverReferencedFFCheckSums[i] && serverName && *serverName)
        {
            if (ffDir == 0)
            {
                I_strncpyz(neededFFs, (char *)serverName, len);
                I_strncat(neededFFs, len, ".ff");
                return 2;
            }

            char downloadName[256];
            I_strncpyz(downloadName, (char *)serverName, sizeof(downloadName));
            if (char *loadSuffix = strstr(downloadName, "_load"))
                *loadSuffix = 0;
            if (dlstring)
            {
                I_strncat(neededFFs, len, "@");
                I_strncat(neededFFs, len, downloadName);
                if (ffDir == 2)
                {
                    I_strncat(neededFFs, len, "/");
                    I_strncat(neededFFs, len, (char *)ffName);
                }
                I_strncat(neededFFs, len, ".ff");
                I_strncat(neededFFs, len, "@");
                I_strncat(neededFFs, len, downloadName);
                if (ffDir == 2)
                {
                    I_strncat(neededFFs, len, "/");
                    I_strncat(neededFFs, len, (char *)ffName);
                }
                I_strncat(neededFFs, len, ".ff");
            }
            else
            {
                I_strncat(neededFFs, len, downloadName);
                if (ffDir == 2)
                {
                    I_strncat(neededFFs, len, "/");
                    I_strncat(neededFFs, len, (char *)ffName);
                }
                I_strncat(neededFFs, len, ".ff");
                if (fileSize)
                    I_strncat(neededFFs, len, " (local file exists with wrong filesize)");
                I_strncat(neededFFs, len, "\n");
            }
        }
    }
    if (!*neededFFs)
        return 0;
    Com_Printf(10, "Need FFs: %s\n", neededFFs);
    return 1;
}

FS_SERVER_COMPARE_RESULT __cdecl FS_CompareWithServerFiles(char *neededFiles, int len, int dlstring)
{
    FS_SERVER_COMPARE_RESULT iwdCompareResult; // [esp+10h] [ebp-Ch]
    int neededIWDStrLen; // [esp+14h] [ebp-8h]
    FS_SERVER_COMPARE_RESULT ffCompareResult; // [esp+18h] [ebp-4h]

    *neededFiles = 0;
    iwdCompareResult = (FS_SERVER_COMPARE_RESULT)FS_CompareIwds(neededFiles, len, dlstring);
    if (iwdCompareResult == NOT_DOWNLOADABLE)
        return (FS_SERVER_COMPARE_RESULT)2;
    neededIWDStrLen = strlen(neededFiles);
    iassert( len >= neededIWDStrLen );
    ffCompareResult = (FS_SERVER_COMPARE_RESULT)FS_CompareFFs(&neededFiles[neededIWDStrLen], len - neededIWDStrLen, dlstring);
    if (ffCompareResult == NOT_DOWNLOADABLE)
        return (FS_SERVER_COMPARE_RESULT)2;
    return (FS_SERVER_COMPARE_RESULT)(iwdCompareResult == NEED_DOWNLOAD || ffCompareResult == NEED_DOWNLOAD);
}

void __cdecl FS_ShutdownServerFileReferences(int *numFiles, const char **fileNames)
{
    int i; // [esp+0h] [ebp-4h]

    for (i = 0; i < *numFiles; ++i)
    {
        if (fileNames[i])
        {
            FreeString(fileNames[i]);
            fileNames[i] = 0;
        }
    }
    *numFiles = 0;
}

void __cdecl FS_ShutdownServerReferencedIwds()
{
    FS_ShutdownServerFileReferences(&fs_numServerReferencedIwds, fs_serverReferencedIwdNames);
}

int __cdecl FS_ServerSetReferencedFiles(
    char *fileSums,
    char *fileNames,
    int maxFiles,
    int *fs_sums,
    const char **fs_names)
{
    const char *v5; // eax
    char *v6; // eax
    int c; // [esp+0h] [ebp-Ch]
    int d; // [esp+4h] [ebp-8h]
    int i; // [esp+8h] [ebp-4h]
    int ia; // [esp+8h] [ebp-4h]

    iassert( fileSums );
    iassert( fileNames );
    iassert( maxFiles );
    iassert( fs_sums );
    Cmd_TokenizeString(fileSums);
    c = Cmd_Argc();
    if (c > maxFiles)
        c = maxFiles;
    for (i = 0; i < c; ++i)
    {
        v5 = Cmd_Argv(i);
        fs_sums[i] = atoi(v5);
    }
    Cmd_EndTokenizedString();
    if (fileNames && *fileNames)
    {
        Cmd_TokenizeString(fileNames);
        d = Cmd_Argc();
        if (d > maxFiles)
            d = maxFiles;
        if (c != d)
            Com_Error(ERR_DROP, "file sum/name mismatch");
        for (ia = 0; ia < d; ++ia)
        {
            v6 = (char *)Cmd_Argv(ia);
            fs_names[ia] = CopyString(v6);
        }
        Cmd_EndTokenizedString();
    }
    else if (c)
    {
        Com_Error(ERR_DROP, "file sum/name mismatch");
    }
    return c;
}

void __cdecl FS_ServerSetReferencedIwds(char *iwdSums, char *iwdNames)
{
    FS_ShutdownServerReferencedIwds();
    fs_numServerReferencedIwds = FS_ServerSetReferencedFiles(
        iwdSums,
        iwdNames,
        1024,
        fs_serverReferencedIwds,
        fs_serverReferencedIwdNames);
}

void __cdecl FS_AddUserMapDirIWD(const char *mapName)
{
    if (!mapName || !*mapName)
        return;

    char gameFolder[128];
    Com_sprintf(gameFolder, sizeof(gameFolder), "usermaps/%s", mapName);
    for (searchpath_s *search = fs_searchpaths; search; search = search->next)
    {
        if (search->iwd && !I_stricmp(search->iwd->iwdGamename, gameFolder))
            return;
    }

    FS_AddIwdFilesForGameDirectory((char *)fs_homepath->current.string, gameFolder);
    for (searchpath_s *search = fs_searchpaths; search; search = search->next)
    {
        if (search->iwd && !I_stricmp(search->iwd->iwdGamename, gameFolder))
            return;
    }
    if (I_stricmp(fs_basepath->current.string, fs_homepath->current.string))
        FS_AddIwdFilesForGameDirectory((char *)fs_basepath->current.string, gameFolder);
}

void __cdecl FS_ShutdownServerReferencedFFs()
{
    FS_ShutdownServerFileReferences(&fs_numServerReferencedFFs, fs_serverReferencedFFNames);
}

void __cdecl FS_ServerSetReferencedFFs(char *FFSums, char *FFNames)
{
    FS_ShutdownServerReferencedFFs();
    fs_numServerReferencedFFs = FS_ServerSetReferencedFiles(
        FFSums,
        FFNames,
        static_cast<int>(sizeof(fs_serverReferencedFFNames) / sizeof(fs_serverReferencedFFNames[0])),
        fs_serverReferencedFFCheckSums,
        fs_serverReferencedFFNames);
}

void __cdecl FS_ShutdownServerIwdNames()
{
    FS_ShutdownServerFileReferences(&fs_numServerIwds, fs_serverIwdNames);
}

void __cdecl FS_PureServerSetLoadedIwds(char *iwdSums, char *iwdNames)
{
    const char *v2; // eax
    int v3; // eax
    const char *v4; // eax
    const char *v5; // eax
    int i; // [esp+0h] [ebp-2014h]
    int v7; // [esp+4h] [ebp-2010h]
    int v8; // [esp+8h] [ebp-200Ch]
    int src[1025]; // [esp+Ch] [ebp-2008h] BYREF
    int argIndex; // [esp+1010h] [ebp-1004h]
    const char *s0[1024]; // [esp+1014h] [ebp-1000h] BYREF

    iassert( iwdSums );
    iassert( iwdNames );
    Cmd_TokenizeString(iwdSums);
    v7 = Cmd_Argc();
    if (v7 > 1024)
        v7 = 1024;
    for (argIndex = 0; argIndex < v7; ++argIndex)
    {
        v2 = Cmd_Argv(argIndex);
        v3 = atoi(v2);
        src[argIndex] = v3;
    }
    Cmd_EndTokenizedString();
    Cmd_TokenizeString(iwdNames);
    v8 = Cmd_Argc();
    if (v8 > 1024)
        v8 = 1024;
    for (argIndex = 0; argIndex < v8; ++argIndex)
    {
        v4 = Cmd_Argv(argIndex);
        v5 = CopyString(v4);
        s0[argIndex] = v5;
    }
    Cmd_EndTokenizedString();
    if (v7 != v8)
        Com_Error(ERR_DROP, "iwd sum/name mismatch");
    if (v7 == fs_numServerIwds)
    {
        argIndex = 0;
    LABEL_19:
        if (argIndex >= v7)
        {
            for (argIndex = 0; argIndex < v8; ++argIndex)
                FreeString(s0[argIndex]);
            return;
        }
        for (i = 0; i < fs_numServerIwds; ++i)
        {
            if (src[argIndex] == fs_serverIwds[i] && !I_stricmp(s0[argIndex], fs_serverIwdNames[i]))
            {
                ++argIndex;
                goto LABEL_19;
            }
        }
    }
    SND_StopSounds(SND_STOP_STREAMED);
    FS_ShutdownServerIwdNames();
    fs_numServerIwds = v7;
    if (v7)
    {
        Com_DPrintf(10, "Connected to a pure server.\n");
        Com_Memcpy(fs_serverIwds, src, 4 * fs_numServerIwds);
        Com_Memcpy(fs_serverIwdNames, s0, sizeof(*fs_serverIwdNames) * fs_numServerIwds);
        fs_fakeChkSum = 0;
    }
}
